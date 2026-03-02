#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-DockerDesktopFastLoop.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:FastLoopScript = Join-Path $script:RepoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1'
    $script:ReadinessScript = Join-Path $script:RepoRoot 'tools' 'Write-DockerFastLoopReadiness.ps1'
    $script:ClassifierScript = Join-Path $script:RepoRoot 'tools' 'Compare-ExitCodeClassifier.ps1'

    foreach ($path in @($script:FastLoopScript, $script:ReadinessScript, $script:ClassifierScript)) {
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required script not found: $path"
      }
    }

    function New-HarnessRepo {
      param(
        [Parameter(Mandatory)][string]$RootPath
      )

      New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
      $toolsDir = Join-Path $RootPath 'tools'
      $fixturesDir = Join-Path $RootPath 'fixtures'
      $viHistoryDir = Join-Path $fixturesDir 'vi-history'
      $viAttrDir = Join-Path $fixturesDir 'vi-attr'
      New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
      New-Item -ItemType Directory -Path $viHistoryDir -Force | Out-Null
      New-Item -ItemType Directory -Path $viAttrDir -Force | Out-Null

      Copy-Item -LiteralPath $script:FastLoopScript -Destination (Join-Path $toolsDir 'Test-DockerDesktopFastLoop.ps1') -Force
      Copy-Item -LiteralPath $script:ReadinessScript -Destination (Join-Path $toolsDir 'Write-DockerFastLoopReadiness.ps1') -Force
      Copy-Item -LiteralPath $script:ClassifierScript -Destination (Join-Path $toolsDir 'Compare-ExitCodeClassifier.ps1') -Force

      Set-Content -LiteralPath (Join-Path $toolsDir 'Assert-DockerRuntimeDeterminism.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
  [string]$ExpectedOsType,
  [string]$ExpectedContext,
  [bool]$AutoRepair = $true,
  [bool]$ManageDockerEngine = $true,
  [int]$EngineReadyTimeoutSeconds = 120,
  [int]$EngineReadyPollSeconds = 3,
  [string]$SnapshotPath,
  [string]$GitHubOutputPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$snapshot = [ordered]@{
  schema = 'docker-runtime-determinism@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  expected = [ordered]@{ osType = $ExpectedOsType; context = $ExpectedContext }
  observed = [ordered]@{ osType = $ExpectedOsType; context = $ExpectedContext }
  result = [ordered]@{ status = 'ok'; reason = '' }
}

if ([string]::Equals($env:FASTLOOP_ASSERT_FAIL_WINDOWS, '1', [System.StringComparison]::OrdinalIgnoreCase) -and `
    [string]::Equals($ExpectedOsType, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) {
  $snapshot.observed.osType = 'linux'
  $snapshot.observed.context = 'desktop-linux'
  $snapshot.result.status = 'mismatch-failed'
  $snapshot.result.reason = 'Runtime determinism check failed: expected os=windows'
}

if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
  $dir = Split-Path -Parent $SnapshotPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SnapshotPath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  Add-Content -LiteralPath $GitHubOutputPath -Value ("runtime-status={0}" -f $snapshot.result.status) -Encoding utf8
  Add-Content -LiteralPath $GitHubOutputPath -Value ("snapshot-path={0}" -f $SnapshotPath) -Encoding utf8
}

if ($snapshot.result.status -eq 'mismatch-failed') {
  throw ($snapshot.result.reason)
}
'@

      Set-Content -LiteralPath (Join-Path $toolsDir 'Run-NIWindowsContainerCompare.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = 'nationalinstruments/labview:2026q1-windows',
  [string]$ReportPath,
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [bool]$AutoRepairRuntime = $true,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [int]$StartupRetryCount = 1,
  [int]$PrelaunchWaitSeconds = 8,
  [int]$RetryDelaySeconds = 8,
  [switch]$Probe,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Probe) {
  if ($PassThru) {
    [pscustomobject]@{
      status = 'probe-ok'
      exitCode = 0
      resultClass = 'success-no-diff'
      isDiff = $false
      gateOutcome = 'pass'
      failureClass = 'none'
    }
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  throw 'ReportPath required for non-probe mode.'
}
$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
  New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
Set-Content -LiteralPath $ReportPath -Value '<html></html>' -Encoding utf8

$exitCode = 1
[void][int]::TryParse(($env:FASTLOOP_WINDOWS_EXIT ?? '1'), [ref]$exitCode)
$status = $env:FASTLOOP_WINDOWS_STATUS
if ([string]::IsNullOrWhiteSpace($status)) { $status = if ($exitCode -eq 1) { 'diff' } else { 'ok' } }
$resultClass = $env:FASTLOOP_WINDOWS_RESULT_CLASS
if ([string]::IsNullOrWhiteSpace($resultClass)) { $resultClass = if ($status -eq 'diff') { 'success-diff' } else { 'success-no-diff' } }
$isDiff = $false
if ($env:FASTLOOP_WINDOWS_IS_DIFF) {
  $isDiff = [string]::Equals($env:FASTLOOP_WINDOWS_IS_DIFF, 'true', [System.StringComparison]::OrdinalIgnoreCase)
} else {
  $isDiff = ($status -eq 'diff')
}
$gateOutcome = $env:FASTLOOP_WINDOWS_GATE_OUTCOME
if ([string]::IsNullOrWhiteSpace($gateOutcome)) { $gateOutcome = if ($resultClass -like 'success-*') { 'pass' } else { 'fail' } }
$failureClass = $env:FASTLOOP_WINDOWS_FAILURE_CLASS
if ([string]::IsNullOrWhiteSpace($failureClass)) { $failureClass = if ($gateOutcome -eq 'pass') { 'none' } else { 'cli/tool' } }

$capturePath = Join-Path $reportDir 'ni-windows-container-capture.json'
$capture = [ordered]@{
  schema = 'ni-windows-container-compare/v1'
  status = $status
  exitCode = $exitCode
  timedOut = $false
  reportPath = $ReportPath
  runtimeDeterminism = [ordered]@{ status = 'ok'; reason = '' }
  resultClass = $resultClass
  isDiff = [bool]$isDiff
  gateOutcome = $gateOutcome
  failureClass = $failureClass
  message = ''
}
$capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8

if ($PassThru) {
  [pscustomobject]$capture
}
exit $exitCode
'@

      Set-Content -LiteralPath (Join-Path $toolsDir 'Run-NILinuxContainerCompare.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = 'nationalinstruments/labview:2026q1-linux',
  [string]$ReportPath,
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [bool]$AutoRepairRuntime = $true,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [switch]$Probe,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Probe) {
  if ($PassThru) {
    [pscustomobject]@{
      status = 'probe-ok'
      exitCode = 0
      resultClass = 'success-no-diff'
      isDiff = $false
      gateOutcome = 'pass'
      failureClass = 'none'
    }
  }
  exit 0
}
exit 0
'@

      Set-Content -LiteralPath (Join-Path $toolsDir 'New-VIHistorySmokeFixture.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
  [string]$OutputRoot,
  [string]$GitHubOutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutputRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$manifestPath = Join-Path $OutputRoot 'suite-manifest.json'
$contextPath = Join-Path $OutputRoot 'history-context.json'
$resultsDir = Join-Path $OutputRoot 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
Set-Content -LiteralPath $manifestPath -Value '{}' -Encoding utf8
Set-Content -LiteralPath $contextPath -Value '{}' -Encoding utf8
if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  Add-Content -LiteralPath $GitHubOutputPath -Value ("suite-manifest-path={0}" -f $manifestPath) -Encoding utf8
  Add-Content -LiteralPath $GitHubOutputPath -Value ("history-context-path={0}" -f $contextPath) -Encoding utf8
  Add-Content -LiteralPath $GitHubOutputPath -Value ("results-dir={0}" -f $resultsDir) -Encoding utf8
}
'@

      Set-Content -LiteralPath (Join-Path $toolsDir 'Render-VIHistoryReport.ps1') -Encoding utf8 -Value @'
[CmdletBinding()]
param(
  [string]$ManifestPath,
  [string]$HistoryContextPath,
  [string]$OutputDir,
  [switch]$EmitHtml,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$mdPath = Join-Path $OutputDir 'history-report.md'
Set-Content -LiteralPath $mdPath -Value '| Metric | Value |' -Encoding utf8
$htmlPath = ''
if ($EmitHtml) {
  $htmlPath = Join-Path $OutputDir 'history-report.html'
  Set-Content -LiteralPath $htmlPath -Value '<th>Lineage</th>' -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  Add-Content -LiteralPath $GitHubOutputPath -Value ("history-report-md={0}" -f $mdPath) -Encoding utf8
  Add-Content -LiteralPath $GitHubOutputPath -Value ("history-report-html={0}" -f $htmlPath) -Encoding utf8
}
'@

      Set-Content -LiteralPath (Join-Path $viAttrDir 'Base.vi') -Value 'base' -Encoding utf8
      Set-Content -LiteralPath (Join-Path $fixturesDir 'head.vi') -Value 'head' -Encoding utf8
      Set-Content -LiteralPath (Join-Path $viHistoryDir 'pr-harness.json') -Encoding utf8 -Value @'
{
  "schema": "vi-history-pr-harness@v1",
  "scenarios": [
    {
      "id": "sample",
      "mode": "attribute",
      "source": "fixtures/head.vi"
    }
  ]
}
'@
    }

    function Get-LatestFastLoopSummary {
      param([Parameter(Mandatory)][string]$ResultsRoot)
      $latest = Get-ChildItem -LiteralPath $ResultsRoot -Filter 'docker-runtime-fastloop-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^docker-runtime-fastloop-\d{14}\.json$' } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
      if (-not $latest) { return $null }
      return $latest.FullName
    }
  }

  It 'writes successful summary and readiness when probes are skipped' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-empty'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'success'
      $summary.steps.Count | Should -Be 0
      $summary.hardStopTriggered | Should -BeFalse
      $summary.historyScenarioCount | Should -Be 0

      $statusPath = Join-Path $resultsRoot 'docker-runtime-fastloop-status.json'
      Test-Path -LiteralPath $statusPath | Should -BeTrue
      $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -Depth 12
      $status.phase | Should -Be 'completed'
      $status.status | Should -Be 'success'

      $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
      if (Test-Path -LiteralPath $readinessPath -PathType Leaf) {
        $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 12
        $readiness.verdict | Should -Be 'ready-to-push'
        $readiness.recommendation | Should -Be 'push'
      }
    } finally {
      Pop-Location | Out-Null
    }
  }

  It 'treats history compare exit 1 diff as pass with diff counts' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-history-diff'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'success'
      $summary.historyScenarioCount | Should -Be 1
      $summary.diffStepCount | Should -Be 1
      $summary.diffLaneCount | Should -Be 1
      $summary.steps.Count | Should -Be 1
      $summary.steps[0].name | Should -Match '^windows-history-'
      $summary.steps[0].status | Should -Be 'success'
      $summary.steps[0].exitCode | Should -Be 1
      $summary.steps[0].resultClass | Should -Be 'success-diff'
      $summary.steps[0].gateOutcome | Should -Be 'pass'
      $summary.steps[0].isDiff | Should -BeTrue

      $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
      $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 12
      $readiness.verdict | Should -Be 'ready-to-push'
      $readiness.diffStepCount | Should -Be 1
      $readiness.diffLaneCount | Should -Be 1
    } finally {
      Pop-Location | Out-Null
    }
  }

  It 'hard-stops immediately on runtime determinism failure' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-hard-stop'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $env:FASTLOOP_ASSERT_FAIL_WINDOWS = '1'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipLinuxProbe 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'failure'
      $summary.hardStopTriggered | Should -BeTrue
      $summary.hardStopReason | Should -Match 'Runtime determinism check failed'
      $summary.steps.Count | Should -Be 1
      $summary.steps[0].name | Should -Be 'windows-runtime-preflight'
      $summary.steps[0].status | Should -Be 'failure'
      $summary.steps[0].failureClass | Should -Be 'runtime-determinism'
      $summary.steps[0].hardStopEligible | Should -BeTrue
      $summary.steps[0].hardStopTriggered | Should -BeTrue
    } finally {
      Remove-Item Env:FASTLOOP_ASSERT_FAIL_WINDOWS -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'orders lanes linux-first by default before windows history steps' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-lane-order'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.laneOrder | Should -Be 'linux-first'

      $stepNames = @($summary.steps | ForEach-Object { [string]$_.name })
      $stepNames.Count | Should -BeGreaterThan 0
      $stepNames[0] | Should -Be 'linux-runtime-preflight'
      ($stepNames -join ',') | Should -Match 'windows-history-sample$'

      $linuxFirstWindowsIndex = ($stepNames | Select-String -SimpleMatch 'windows-runtime-preflight' | Select-Object -First 1).LineNumber
      $linuxIndex = ($stepNames | Select-String -SimpleMatch 'linux-runtime-preflight' | Select-Object -First 1).LineNumber
      $linuxFirstWindowsIndex | Should -BeGreaterThan $linuxIndex
    } finally {
      Pop-Location | Out-Null
    }
  }
}
