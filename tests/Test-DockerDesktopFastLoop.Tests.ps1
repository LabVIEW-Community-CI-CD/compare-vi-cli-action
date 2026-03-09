#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Test-DockerDesktopFastLoop.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:FastLoopScript = Join-Path $script:RepoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1'
    $script:ReadinessScript = Join-Path $script:RepoRoot 'tools' 'Write-DockerFastLoopReadiness.ps1'
    $script:DiagnosticsModule = Join-Path $script:RepoRoot 'tools' 'DockerFastLoopDiagnostics.psm1'
    $script:HostPlaneModule = Join-Path $script:RepoRoot 'tools' 'LabVIEW2026HostPlaneDiagnostics.psm1'
    $script:VendorToolsModule = Join-Path $script:RepoRoot 'tools' 'VendorTools.psm1'
    $script:ClassifierScript = Join-Path $script:RepoRoot 'tools' 'Compare-ExitCodeClassifier.ps1'

    foreach ($path in @($script:FastLoopScript, $script:ReadinessScript, $script:DiagnosticsModule, $script:HostPlaneModule, $script:VendorToolsModule, $script:ClassifierScript)) {
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
      Copy-Item -LiteralPath $script:DiagnosticsModule -Destination (Join-Path $toolsDir 'DockerFastLoopDiagnostics.psm1') -Force
      Copy-Item -LiteralPath $script:HostPlaneModule -Destination (Join-Path $toolsDir 'LabVIEW2026HostPlaneDiagnostics.psm1') -Force
      Copy-Item -LiteralPath $script:VendorToolsModule -Destination (Join-Path $toolsDir 'VendorTools.psm1') -Force
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
  repairActions = @()
  result = [ordered]@{
    status = 'ok'
    reason = ''
    failureClass = 'none'
    probeParseReason = 'parsed'
  }
}

if (-not [string]::IsNullOrWhiteSpace($env:FASTLOOP_ASSERT_TRACE_PATH)) {
  $traceLine = "os=$ExpectedOsType;context=$ExpectedContext;autoRepair=$AutoRepair;manageEngine=$ManageDockerEngine;timeout=$EngineReadyTimeoutSeconds"
  $traceDir = Split-Path -Parent $env:FASTLOOP_ASSERT_TRACE_PATH
  if ($traceDir -and -not (Test-Path -LiteralPath $traceDir -PathType Container)) {
    New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
  }
  Add-Content -LiteralPath $env:FASTLOOP_ASSERT_TRACE_PATH -Value $traceLine -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($env:FASTLOOP_ASSERT_SLEEP_SECONDS)) {
  $sleepSeconds = 0
  if ([int]::TryParse($env:FASTLOOP_ASSERT_SLEEP_SECONDS, [ref]$sleepSeconds) -and $sleepSeconds -gt 0) {
    Start-Sleep -Seconds $sleepSeconds
  }
}

if ([string]::Equals($env:FASTLOOP_ASSERT_FAIL_WINDOWS, '1', [System.StringComparison]::OrdinalIgnoreCase) -and `
    [string]::Equals($ExpectedOsType, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) {
  $snapshot.observed.osType = 'linux'
  $snapshot.observed.context = 'desktop-linux'
  $snapshot.result.status = 'mismatch-failed'
  $snapshot.result.reason = 'Runtime determinism check failed: expected os=windows'
  $snapshot.result.failureClass = 'daemon-unavailable'
  $snapshot.result.probeParseReason = 'daemon-unavailable'
  $snapshot.repairActions = @('docker service recovery: restart-service')
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
  [bool]$ManageDockerEngine = $true,
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
if (-not [string]::IsNullOrWhiteSpace($env:FASTLOOP_WINDOWS_TRACE_PATH)) {
  $traceDir = Split-Path -Parent $env:FASTLOOP_WINDOWS_TRACE_PATH
  if ($traceDir -and -not (Test-Path -LiteralPath $traceDir -PathType Container)) {
    New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
  }
  $traceLine = "probe={0};labviewPath={1};baseVi={2};headVi={3};reportPath={4}" -f $Probe.IsPresent, $LabVIEWPath, $BaseVi, $HeadVi, $ReportPath
  Add-Content -LiteralPath $env:FASTLOOP_WINDOWS_TRACE_PATH -Value $traceLine -Encoding utf8
}
if (-not [string]::IsNullOrWhiteSpace($env:FASTLOOP_WINDOWS_SLEEP_SECONDS)) {
  $sleepSeconds = 0
  if ([int]::TryParse($env:FASTLOOP_WINDOWS_SLEEP_SECONDS, [ref]$sleepSeconds) -and $sleepSeconds -gt 0) {
    Start-Sleep -Seconds $sleepSeconds
  }
}
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
  [bool]$ManageDockerEngine = $true,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [switch]$Probe,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($env:FASTLOOP_LINUX_TRACE_PATH)) {
  $traceDir = Split-Path -Parent $env:FASTLOOP_LINUX_TRACE_PATH
  if ($traceDir -and -not (Test-Path -LiteralPath $traceDir -PathType Container)) {
    New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
  }
  $traceLine = "probe={0};labviewPath={1};baseVi={2};headVi={3};reportPath={4}" -f $Probe.IsPresent, $LabVIEWPath, $BaseVi, $HeadVi, $ReportPath
  Add-Content -LiteralPath $env:FASTLOOP_LINUX_TRACE_PATH -Value $traceLine -Encoding utf8
}
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
      "source": "fixtures/head.vi",
      "requireDiff": true
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
        -HistoryScenarioSet history-core *>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
      ($output -join "`n") | Should -Match '\[windows-docker-fast-loop\]\[diagnostics\] scenarioSet=history-core differentiatedSteps=1 evidenceSteps=0 reports=0'
      ($output -join "`n") | Should -Match 'lane=windows sequence=direct mode=attribute'
      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.loopLabel | Should -Be 'windows-docker-fast-loop'
      $summary.status | Should -Be 'success'
      $summary.historyScenarioCount | Should -Be 1
      $summary.diffStepCount | Should -Be 1
      $summary.diffLaneCount | Should -Be 1
      $summary.steps.Count | Should -Be 1
      $summary.steps[0].name | Should -Match '^windows-history-'
      $summary.steps[0].historyMode | Should -Be 'attribute'
      $summary.steps[0].historySequence | Should -Be 'direct'
      $summary.steps[0].status | Should -Be 'success'
      $summary.steps[0].exitCode | Should -BeIn @(0, 1)
      $summary.steps[0].resultClass | Should -Be 'success-diff'
      $summary.steps[0].gateOutcome | Should -Be 'pass'
      $summary.steps[0].isDiff | Should -BeTrue

      $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
      $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 12
      $readiness.loopLabel | Should -Be 'windows-docker-fast-loop'
      $readiness.verdict | Should -Be 'ready-to-push'
      $readiness.diffStepCount | Should -Be 1
      $readiness.diffLaneCount | Should -Be 1
    } finally {
      Pop-Location | Out-Null
    }
  }

  It 'captures host-plane diagnostics in summary and readiness artifacts' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-host-plane-report'
    New-HarnessRepo -RootPath $repoRoot

    $native64 = Join-Path $repoRoot 'native64\LabVIEW.exe'
    $native32 = Join-Path $repoRoot 'native32\LabVIEW.exe'
    $sharedCli = Join-Path $repoRoot 'shared\LabVIEWCLI.exe'
    $lvCompare = Join-Path $repoRoot 'shared\LVCompare.exe'
    foreach ($path in @($native64, $native32, $sharedCli, $lvCompare)) {
      $dir = Split-Path -Parent $path
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      Set-Content -LiteralPath $path -Encoding ascii -Value ''
    }

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $env:COMPAREVI_NATIVE_LABVIEW_2026_64_PATH = $native64
      $env:COMPAREVI_NATIVE_LABVIEW_2026_32_PATH = $native32
      $env:COMPAREVI_NATIVE_LABVIEWCLI_2026_64_PATH = $sharedCli
      $env:COMPAREVI_NATIVE_LABVIEWCLI_2026_32_PATH = $sharedCli
      $env:COMPAREVI_NATIVE_LVCOMPARE_PATH = $lvCompare

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe *>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
      ($output -join "`n") | Should -Match '\[host-plane-split\]\[runner\] hostIsRunner=True'

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 16
      $summary.hostPlaneReportPath | Should -Not -BeNullOrEmpty
      Test-Path -LiteralPath $summary.hostPlaneReportPath -PathType Leaf | Should -BeTrue
      $summary.hostPlane.runner.hostIsRunner | Should -BeTrue
      $summary.hostPlane.runner.runnerName | Should -Not -BeNullOrEmpty
      $summary.hostExecutionPolicy.mutuallyExclusivePairs.pairs.Count | Should -Be 1
      $summary.hostExecutionPolicy.candidateParallelPairs.pairs.Count | Should -Be 2

      $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
      $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 16
      $readiness.source.hostPlaneReportPath | Should -Be $summary.hostPlaneReportPath
      $readiness.hostPlane.runner.hostIsRunner | Should -BeTrue
      $readiness.hostExecutionPolicy.candidateParallelPairs.pairs.Count | Should -Be 2
      $readiness.hostPlanes.x64.status | Should -Be 'ready'
      $readiness.hostPlanes.x32.status | Should -Be 'ready'
    } finally {
      Remove-Item Env:COMPAREVI_NATIVE_LABVIEW_2026_64_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_NATIVE_LABVIEW_2026_32_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_NATIVE_LABVIEWCLI_2026_64_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_NATIVE_LABVIEWCLI_2026_32_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_NATIVE_LVCOMPARE_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'fails history-core when no scenario is marked requireDiff=true' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-history-require-diff'
    New-HarnessRepo -RootPath $repoRoot
    $harnessPath = Join-Path $repoRoot 'fixtures/vi-history/pr-harness.json'
    Set-Content -LiteralPath $harnessPath -Encoding utf8 -Value @'
{
  "schema": "vi-history-pr-harness@v1",
  "scenarios": [
    {
      "id": "sample",
      "mode": "attribute",
      "source": "fixtures/head.vi",
      "requireDiff": false
    }
  ]
}
'@

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      ($output -join "`n") | Should -Match 'requireDiff=true'
    } finally {
      Pop-Location | Out-Null
    }
  }

  It 'fails sequential scenario when sequential steps are not marked requireDiff=true' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-sequential-require-diff'
    New-HarnessRepo -RootPath $repoRoot

    $harnessPath = Join-Path $repoRoot 'fixtures/vi-history/pr-harness.json'
    Set-Content -LiteralPath $harnessPath -Encoding utf8 -Value @'
{
  "schema": "vi-history-pr-harness@v1",
  "scenarios": [
    {
      "id": "sequential",
      "mode": "sequential",
      "requireDiff": true
    }
  ]
}
'@
    $sequentialPath = Join-Path $repoRoot 'fixtures/vi-history/sequential.json'
    Set-Content -LiteralPath $sequentialPath -Encoding utf8 -Value @'
{
  "schema": "vi-history-sequence@v1",
  "steps": [
    {
      "id": "s1",
      "source": "fixtures/head.vi",
      "requireDiff": false
    }
  ]
}
'@

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      ($output -join "`n") | Should -Match 'resolved to empty after requireDiff=true filtering'
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
      $summary.laneLifecycle.windows.status | Should -Be 'failure'
      $summary.laneLifecycle.windows.hardStopTriggered | Should -BeTrue
      $summary.laneLifecycle.windows.stopClass | Should -Be 'hard-stop'
      $summary.laneLifecycle.windows.startStep | Should -Be 'windows-runtime-preflight'
      $summary.laneLifecycle.windows.endStep | Should -Be 'windows-runtime-preflight'
      $summary.laneLifecycle.linux.status | Should -Be 'skipped'
      $summary.runtimeManager.schema | Should -Be 'docker-fast-loop/runtime-manager@v1'
      $summary.runtimeManager.daemonUnavailableCount | Should -Be 1
      $summary.runtimeManager.transitionCount | Should -BeGreaterThan 0
    } finally {
      Remove-Item Env:FASTLOOP_ASSERT_FAIL_WINDOWS -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'marks opposite lane blocked when hard-stop occurs before it starts in dual-lane mode' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-hard-stop-blocked-lane'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $env:FASTLOOP_ASSERT_FAIL_WINDOWS = '1'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneOrder windows-first `
        -HistoryScenarioSet none 2>&1
      $LASTEXITCODE | Should -Not -Be 0

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.hardStopTriggered | Should -BeTrue
      $summary.laneScope | Should -Be 'both'
      $summary.laneLifecycle.windows.status | Should -Be 'failure'
      $summary.laneLifecycle.windows.stopClass | Should -Be 'hard-stop'
      $summary.laneLifecycle.linux.status | Should -Be 'blocked'
      $summary.laneLifecycle.linux.stopClass | Should -Be 'blocked'
      $summary.laneLifecycle.linux.executedSteps | Should -Be 0
      $summary.laneLifecycle.linux.totalPlannedSteps | Should -BeGreaterThan 0
      $summary.laneLifecycle.linux.stopReason | Should -Match 'Runtime determinism check failed'
    } finally {
      Remove-Item Env:FASTLOOP_ASSERT_FAIL_WINDOWS -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }


  It 'reports startup-connectivity hard-stop reason without runtime-determinism wording' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-startup-connectivity-reason'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $env:FASTLOOP_WINDOWS_EXIT = '125'
      $env:FASTLOOP_WINDOWS_STATUS = 'error'
      $env:FASTLOOP_WINDOWS_RESULT_CLASS = 'failure-tool'
      $env:FASTLOOP_WINDOWS_GATE_OUTCOME = 'fail'
      $env:FASTLOOP_WINDOWS_FAILURE_CLASS = 'startup-connectivity'

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Not -Be 0

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'failure'
      $summary.hardStopTriggered | Should -BeTrue
      $summary.hardStopReason | Should -Match 'Startup/connectivity failure detected'
      $summary.hardStopReason | Should -Not -Match 'Runtime determinism check failed'
      $summary.steps.Count | Should -BeGreaterThan 0
      $summary.steps[-1].failureClass | Should -Be 'startup-connectivity'
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_EXIT -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_STATUS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_RESULT_CLASS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_GATE_OUTCOME -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_FAILURE_CLASS -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'runs single-lane windows mode without runtime auto-repair or managed engine switching' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-single-lane-windows'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'assert-trace.log'
      $env:FASTLOOP_ASSERT_TRACE_PATH = $tracePath
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneScope windows `
        -HistoryScenarioSet none 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'success'
      $summary.laneScope | Should -Be 'windows'
      $summary.singleLaneMode | Should -BeTrue
      $summary.runtimeAutoRepair | Should -BeFalse
      $summary.manageDockerEngine | Should -BeFalse
      $summary.steps.Count | Should -BeGreaterThan 0
      foreach ($step in @($summary.steps)) {
        ([string]$step.name) | Should -Match '^windows-'
      }
      $summary.laneLifecycle.windows.status | Should -Be 'success'
      $summary.laneLifecycle.windows.stopClass | Should -Be 'completed'
      $summary.laneLifecycle.windows.started | Should -BeTrue
      $summary.laneLifecycle.windows.completed | Should -BeTrue
      $summary.laneLifecycle.linux.status | Should -Be 'skipped'
      $summary.laneLifecycle.linux.started | Should -BeFalse

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      foreach ($line in $traceLines) {
        $line | Should -Match 'autoRepair=False'
        $line | Should -Match 'manageEngine=False'
      }
    } finally {
      Remove-Item Env:FASTLOOP_ASSERT_TRACE_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'prefers NI_WINDOWS_LABVIEW_PATH over host-style LABVIEW_PATH for windows history compare' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-labview-path-forwarding'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'windows-trace.log'
      $expectedPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $hostPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
      $env:FASTLOOP_WINDOWS_TRACE_PATH = $tracePath
      $env:NI_WINDOWS_LABVIEW_PATH = $expectedPath
      $env:LABVIEW_PATH = $hostPath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      $traceLines[-1] | Should -Match 'probe=False;labviewPath='
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($expectedPath))) | Should -BeTrue
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($hostPath))) | Should -BeFalse
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_TRACE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:NI_WINDOWS_LABVIEW_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'falls back to the default windows container LabVIEW path when docker-specific overrides are absent' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-host-labview-ignored'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'windows-trace.log'
      $expectedPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $hostPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
      $env:FASTLOOP_WINDOWS_TRACE_PATH = $tracePath
      $env:LABVIEW_PATH = $hostPath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($expectedPath))) | Should -BeTrue
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($hostPath))) | Should -BeFalse
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_TRACE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'ignores shared compare path envs and still uses the default windows container LabVIEW path' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-shared-windows-labview-ignored'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'windows-trace.log'
      $expectedPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      $sharedPath = 'C:\Program Files\National Instruments\LabVIEW 2027\LabVIEW.exe'
      $loopPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
      $env:FASTLOOP_WINDOWS_TRACE_PATH = $tracePath
      $env:COMPARE_LABVIEW_PATH = $sharedPath
      $env:LOOP_LABVIEW_PATH = $loopPath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($expectedPath))) | Should -BeTrue
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($sharedPath))) | Should -BeFalse
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($loopPath))) | Should -BeFalse
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_TRACE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPARE_LABVIEW_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:LOOP_LABVIEW_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'prefers NI_LINUX_LABVIEW_PATH over shared compare path envs for linux probe' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-linux-labview-path-forwarding'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'linux-trace.log'
      $expectedPath = '/usr/local/natinst/LabVIEW-2026-64/labview'
      $sharedPath = '/usr/local/natinst/LabVIEW-2025-64/labview'
      $env:FASTLOOP_LINUX_TRACE_PATH = $tracePath
      $env:NI_LINUX_LABVIEW_PATH = $expectedPath
      $env:COMPARE_LABVIEW_PATH = $sharedPath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneScope linux `
        -HistoryScenarioSet none 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      $traceLines[-1] | Should -Match 'probe=True;labviewPath='
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($expectedPath))) | Should -BeTrue
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($sharedPath))) | Should -BeFalse
    } finally {
      Remove-Item Env:FASTLOOP_LINUX_TRACE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:NI_LINUX_LABVIEW_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPARE_LABVIEW_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'ignores shared compare path envs and falls back to the default linux container LabVIEW path' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-shared-linux-labview-ignored'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'linux-trace.log'
      $expectedPath = '/usr/local/natinst/LabVIEW-2026-64/labview'
      $sharedPath = '/usr/local/natinst/LabVIEW-2027-64/labview'
      $loopPath = '/usr/local/natinst/LabVIEW-2025-64/labview'
      $env:FASTLOOP_LINUX_TRACE_PATH = $tracePath
      $env:COMPARE_LABVIEW_PATH = $sharedPath
      $env:LOOP_LABVIEW_PATH = $loopPath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneScope linux `
        -HistoryScenarioSet none 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $traceLines.Count | Should -BeGreaterThan 0
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($expectedPath))) | Should -BeTrue
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($sharedPath))) | Should -BeFalse
      ($traceLines[-1] -match ("labviewPath={0}(;|$)" -f [regex]::Escape($loopPath))) | Should -BeFalse
    } finally {
      Remove-Item Env:FASTLOOP_LINUX_TRACE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPARE_LABVIEW_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:LOOP_LABVIEW_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'binds distinct windows history report paths for each smoke scenario step' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-history-report-binding'
    New-HarnessRepo -RootPath $repoRoot

    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures' 'head-attribute.vi') -Value 'head-attribute' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures' 'head-step-1.vi') -Value 'head-step-1' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures' 'head-step-2.vi') -Value 'head-step-2' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures' 'vi-history' 'pr-harness.json') -Encoding utf8 -Value @'
{
  "schema": "vi-history-pr-harness@v1",
  "scenarios": [
    {
      "id": "attribute",
      "mode": "attribute",
      "source": "fixtures/head-attribute.vi",
      "requireDiff": true
    },
    {
      "id": "sequential",
      "mode": "sequential",
      "requireDiff": true
    }
  ]
}
'@
    Set-Content -LiteralPath (Join-Path $repoRoot 'fixtures' 'vi-history' 'sequential.json') -Encoding utf8 -Value @'
{
  "schema": "vi-history-sequence@v1",
  "steps": [
    {
      "id": "step-1",
      "source": "fixtures/head-step-1.vi",
      "requireDiff": true
    },
    {
      "id": "step-2",
      "source": "fixtures/head-step-2.vi",
      "requireDiff": true
    }
  ]
}
'@

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $tracePath = Join-Path $resultsRoot 'windows-trace.log'
      $env:FASTLOOP_WINDOWS_TRACE_PATH = $tracePath

      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneScope windows `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet smoke 2>&1
      $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $historySteps = @($summary.steps | Where-Object { [string]$_.name -like 'windows-history*' })
      $historySteps.Count | Should -Be 3
      (@($historySteps | ForEach-Object { [string]$_.capturePath } | Select-Object -Unique)).Count | Should -Be 3
      @($historySteps | ForEach-Object { [string]$_.capturePath }) | Should -Contain (Join-Path $resultsRoot 'history-scenarios\attribute\ni-windows-container-capture.json')
      @($historySteps | ForEach-Object { [string]$_.capturePath }) | Should -Contain (Join-Path $resultsRoot 'history-scenarios\sequential\step-1\ni-windows-container-capture.json')
      @($historySteps | ForEach-Object { [string]$_.capturePath }) | Should -Contain (Join-Path $resultsRoot 'history-scenarios\sequential\step-2\ni-windows-container-capture.json')

      Test-Path -LiteralPath $tracePath -PathType Leaf | Should -BeTrue
      $traceLines = @(Get-Content -LiteralPath $tracePath | Where-Object { $_ -like 'probe=False*' })
      $traceLines.Count | Should -Be 3
      (@($traceLines | ForEach-Object {
        if ($_ -match 'reportPath=([^;]+)$') { $Matches[1] }
      } | Select-Object -Unique)).Count | Should -Be 3
      $traceLines[0] | Should -Match 'headVi=.*head-attribute\.vi'
      $traceLines[1] | Should -Match 'baseVi=.*fixtures\\vi-attr\\Base\.vi'
      $traceLines[1] | Should -Match 'headVi=.*head-step-1\.vi'
      $traceLines[2] | Should -Match 'baseVi=.*head-step-1\.vi'
      $traceLines[2] | Should -Match 'headVi=.*head-step-2\.vi'
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_TRACE_PATH -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'fails early when single-lane mode enables managed engine switching' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-single-lane-manage-engine'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -LaneScope windows `
        -ManageDockerEngine:$true `
        -SkipWindowsProbe `
        -SkipLinuxProbe 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      ($output -join "`n") | Should -Match 'does not allow -ManageDockerEngine'
    } finally {
      Pop-Location | Out-Null
    }
  }

  It 'normalizes conflicting timeout classification to non-zero exit telemetry' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-timeout-classification'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $env:FASTLOOP_WINDOWS_EXIT = '0'
      $env:FASTLOOP_WINDOWS_STATUS = 'timeout'
      $env:FASTLOOP_WINDOWS_RESULT_CLASS = 'failure-timeout'
      $env:FASTLOOP_WINDOWS_GATE_OUTCOME = 'fail'
      $env:FASTLOOP_WINDOWS_FAILURE_CLASS = 'timeout'
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
        -ResultsRoot $resultsRoot `
        -StepTimeoutSeconds 1 `
        -SkipWindowsProbe `
        -SkipLinuxProbe `
        -HistoryScenarioSet history-core 2>&1
      $LASTEXITCODE | Should -Not -Be 0

      $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
      $summaryPath | Should -Not -BeNullOrEmpty
      $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
      $summary.status | Should -Be 'failure'
      $summary.stepTimeoutSeconds | Should -Be 1
      $summary.timeoutFailureCount | Should -BeGreaterThan 0
      $summary.hardStopTriggered | Should -BeTrue
      $summary.hardStopReason | Should -Match 'Timeout failure detected'
      $summary.steps.Count | Should -BeGreaterThan 0
      $summary.steps[0].failureClass | Should -Be 'timeout'
      $summary.steps[0].resultClass | Should -Be 'failure-timeout'
      $summary.steps[0].exitCode | Should -Be 124
      $summary.steps[0].gateOutcome | Should -Be 'fail'
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_EXIT -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_STATUS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_RESULT_CLASS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_GATE_OUTCOME -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_FAILURE_CLASS -ErrorAction SilentlyContinue
      Pop-Location | Out-Null
    }
  }

  It 'normalizes conflicting runtime and tool classified failures to deterministic exits' {
    $repoRoot = Join-Path $TestDrive 'fast-loop-failure-exit-normalization'
    New-HarnessRepo -RootPath $repoRoot

    Push-Location $repoRoot
    try {
      $resultsRoot = Join-Path $repoRoot 'tests/results/local-parity'
      $cases = @(
        @{
          Name = 'runtime'
          ResultClass = 'failure-runtime'
          FailureClass = 'runtime-determinism'
          ExpectedExit = 2
        },
        @{
          Name = 'tool'
          ResultClass = 'failure-tool'
          FailureClass = 'cli/tool'
          ExpectedExit = 1
        }
      )

      foreach ($case in $cases) {
        $env:FASTLOOP_WINDOWS_EXIT = '0'
        $env:FASTLOOP_WINDOWS_STATUS = 'error'
        $env:FASTLOOP_WINDOWS_RESULT_CLASS = $case.ResultClass
        $env:FASTLOOP_WINDOWS_GATE_OUTCOME = 'fail'
        $env:FASTLOOP_WINDOWS_FAILURE_CLASS = $case.FailureClass

        $output = & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Test-DockerDesktopFastLoop.ps1') `
          -ResultsRoot $resultsRoot `
          -SkipWindowsProbe `
          -SkipLinuxProbe `
          -HistoryScenarioSet history-core 2>&1
        $LASTEXITCODE | Should -Not -Be 0 -Because ($output -join "`n")

        $summaryPath = Get-LatestFastLoopSummary -ResultsRoot $resultsRoot
        $summaryPath | Should -Not -BeNullOrEmpty
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
        $summary.steps.Count | Should -BeGreaterThan 0
        $step = $summary.steps[0]
        $step.resultClass | Should -Be $case.ResultClass -Because $case.Name
        $step.failureClass | Should -Be $case.FailureClass -Because $case.Name
        $step.gateOutcome | Should -Be 'fail' -Because $case.Name
        $step.exitCode | Should -Be $case.ExpectedExit -Because $case.Name
      }
    } finally {
      Remove-Item Env:FASTLOOP_WINDOWS_EXIT -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_STATUS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_RESULT_CLASS -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_GATE_OUTCOME -ErrorAction SilentlyContinue
      Remove-Item Env:FASTLOOP_WINDOWS_FAILURE_CLASS -ErrorAction SilentlyContinue
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
