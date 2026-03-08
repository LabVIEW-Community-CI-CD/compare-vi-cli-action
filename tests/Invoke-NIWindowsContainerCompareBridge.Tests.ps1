Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-NIWindowsContainerCompareBridge.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:BridgeScript = Join-Path $repoRoot 'tools' 'Invoke-NIWindowsContainerCompareBridge.ps1'
    if (-not (Test-Path -LiteralPath $script:BridgeScript -PathType Leaf)) {
      throw "Invoke-NIWindowsContainerCompareBridge.ps1 not found at $script:BridgeScript"
    }

    $script:RunnerStub = @'
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image,
  [string]$ReportPath,
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = [Environment]::GetEnvironmentVariable('BRIDGE_STUB_LOG', 'Process')
if (-not [string]::IsNullOrWhiteSpace($logPath)) {
  $record = [ordered]@{
    baseVi = $BaseVi
    headVi = $HeadVi
    image = $Image
    reportPath = $ReportPath
    reportType = $ReportType
    timeoutSeconds = $TimeoutSeconds
    flags = @($Flags)
    labviewPath = $LabVIEWPath
  }
  $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding utf8
}

$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
  New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}

$stdoutPath = Join-Path $reportDir 'ni-windows-container-stdout.txt'
$stderrPath = Join-Path $reportDir 'ni-windows-container-stderr.txt'
$capturePath = Join-Path $reportDir 'ni-windows-container-capture.json'

'stub stdout' | Set-Content -LiteralPath $stdoutPath -Encoding utf8
'stub stderr' | Set-Content -LiteralPath $stderrPath -Encoding utf8

$exitCode = 1
if ($env:BRIDGE_STUB_EXIT) {
  $parsed = 0
  if ([int]::TryParse($env:BRIDGE_STUB_EXIT, [ref]$parsed)) {
    $exitCode = $parsed
  }
}

switch ($ReportType) {
  'xml' { '<report diff="false" />' | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
  'text' { 'stub report' | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
  default { '<html><body>stub report</body></html>' | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
}

$capture = [ordered]@{
  schema = 'ni-windows-container-compare/v1'
  status = if ($exitCode -eq 1) { 'diff' } elseif ($exitCode -eq 0) { 'ok' } else { 'error' }
  classification = if ($exitCode -eq 1) { 'diff' } elseif ($exitCode -eq 0) { 'ok' } else { 'run-error' }
  exitCode = $exitCode
  timedOut = $false
  image = $Image
  reportPath = $ReportPath
  labviewPath = $LabVIEWPath
  command = 'docker run stub'
  message = 'stub'
  resultClass = if ($exitCode -eq 1) { 'success-diff' } elseif ($exitCode -eq 0) { 'success-no-diff' } else { 'failure-tool' }
  isDiff = ($exitCode -eq 1)
  gateOutcome = if ($exitCode -in @(0, 1)) { 'pass' } else { 'fail' }
  failureClass = if ($exitCode -in @(0, 1)) { 'none' } else { 'cli/tool' }
  reportAnalysis = [ordered]@{
    reportPathExtracted = $ReportPath
    diffImageCount = if ($exitCode -eq 1) { 2 } else { 0 }
    hasDiffEvidence = ($exitCode -eq 1)
  }
  containerArtifacts = [ordered]@{
    exportDir = $reportDir
    copiedPaths = @($ReportPath)
    copyStatus = 'success'
  }
}
$capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8

if ($PassThru) {
  [pscustomobject]$capture
}

exit $exitCode
'@
  }

  BeforeEach {
    foreach ($name in @(
      'COMPAREVI_NI_WINDOWS_IMAGE',
      'COMPAREVI_NI_WINDOWS_LABVIEW_PATH',
      'COMPAREVI_NI_WINDOWS_CLI_PATH',
      'COMPAREVI_NI_WINDOWS_COMPARE_POLICY',
      'BRIDGE_STUB_EXIT',
      'BRIDGE_STUB_LOG'
    )) {
      Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
  }

  It 'writes lvcompare-compatible artifacts from a diff capture' {
    $workRoot = Join-Path $TestDrive 'bridge-basic'
    $toolsDir = Join-Path $workRoot 'tools'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -LiteralPath $script:BridgeScript -Destination (Join-Path $toolsDir 'Invoke-NIWindowsContainerCompareBridge.ps1') -Force
    Set-Content -LiteralPath (Join-Path $toolsDir 'Run-NIWindowsContainerCompare.ps1') -Value $script:RunnerStub -Encoding utf8

    $outputDir = Join-Path $workRoot 'out'
    $env:BRIDGE_STUB_EXIT = '1'

    $runOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Invoke-NIWindowsContainerCompareBridge.ps1') `
      -BaseVi 'base.vi' `
      -HeadVi 'head.vi' `
      -OutputDir $outputDir `
      -Flags '-noattr' 2>&1
    $LASTEXITCODE | Should -Be 1 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $capturePath = Join-Path $outputDir 'lvcompare-capture.json'
    $stdoutPath = Join-Path $outputDir 'lvcompare-stdout.txt'
    $stderrPath = Join-Path $outputDir 'lvcompare-stderr.txt'
    $exitPath = Join-Path $outputDir 'lvcompare-exitcode.txt'

    $capturePath | Should -Exist
    $stdoutPath | Should -Exist
    $stderrPath | Should -Exist
    $exitPath | Should -Exist

    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 10
    $capture.schema | Should -Be 'lvcompare-capture-v1'
    $capture.diff | Should -BeTrue
    $capture.cliPath | Should -Be 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $capture.environment.comparePolicy | Should -Be 'cli-only'
    $capture.environment.container.image | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $capture.environment.container.labviewVersion | Should -Be '2026'
    $capture.environment.cli.reportPath | Should -Match 'compare-report\.html$'
    ($capture.args | Measure-Object).Count | Should -Be 1
    ((Get-Content -LiteralPath $stdoutPath -Raw).Trim()) | Should -Be 'stub stdout'
    ((Get-Content -LiteralPath $stderrPath -Raw).Trim()) | Should -Be 'stub stderr'
    ((Get-Content -LiteralPath $exitPath -Raw).Trim()) | Should -Be '1'
  }

  It 'honors explicit container overrides and xml output mapping' {
    $workRoot = Join-Path $TestDrive 'bridge-xml'
    $toolsDir = Join-Path $workRoot 'tools'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Copy-Item -LiteralPath $script:BridgeScript -Destination (Join-Path $toolsDir 'Invoke-NIWindowsContainerCompareBridge.ps1') -Force
    Set-Content -LiteralPath (Join-Path $toolsDir 'Run-NIWindowsContainerCompare.ps1') -Value $script:RunnerStub -Encoding utf8

    $outputDir = Join-Path $workRoot 'out'
    $logPath = Join-Path $workRoot 'runner-log.json'
    $env:BRIDGE_STUB_EXIT = '0'
    $env:BRIDGE_STUB_LOG = $logPath
    $env:COMPAREVI_NI_WINDOWS_IMAGE = 'example.com/ni/windows:test'
    $env:COMPAREVI_NI_WINDOWS_LABVIEW_PATH = 'C:\Program Files\National Instruments\LabVIEW 2027\LabVIEW.exe'
    $env:COMPAREVI_NI_WINDOWS_CLI_PATH = 'C:\CLI\LabVIEWCLI.exe'
    $env:COMPAREVI_NI_WINDOWS_COMPARE_POLICY = 'cli-first'

    $runOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Invoke-NIWindowsContainerCompareBridge.ps1') `
      -BaseVi 'base.vi' `
      -HeadVi 'head.vi' `
      -OutputDir $outputDir `
      -ReportFormat xml `
      -TimeoutSeconds 123 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $capturePath = Join-Path $outputDir 'lvcompare-capture.json'
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 10
    $capture.diff | Should -BeFalse
    $capture.cliPath | Should -Be 'C:\CLI\LabVIEWCLI.exe'
    $capture.environment.comparePolicy | Should -Be 'cli-first'
    $capture.environment.container.image | Should -Be 'example.com/ni/windows:test'
    $capture.environment.container.labviewVersion | Should -Be '2027'
    $capture.environment.cli.reportPath | Should -Match 'compare-report\.xml$'

    $runnerLog = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json -Depth 8
    $runnerLog.image | Should -Be 'example.com/ni/windows:test'
    $runnerLog.reportType | Should -Be 'xml'
    $runnerLog.reportPath | Should -Match 'compare-report\.xml$'
    $runnerLog.timeoutSeconds | Should -Be 123
    $runnerLog.labviewPath | Should -Be 'C:\Program Files\National Instruments\LabVIEW 2027\LabVIEW.exe'
  }
}
