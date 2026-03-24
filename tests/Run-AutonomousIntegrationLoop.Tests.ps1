# Requires -Version 5.1
# Pester tests validating autonomous loop script behaviors (final status JSON & DiffExitCode) using
# environment-driven simulation (LOOP_SIMULATE) to avoid cross-process scriptblock passing.

Describe 'Run-AutonomousIntegrationLoop FinalStatusJsonPath emission' -Tag 'Unit' {
  BeforeAll { . "$PSScriptRoot/TestHelpers.Schema.ps1" }
  It 'emits final status JSON with expected shape in simulate mode' {
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Resolve-Path (Join-Path $here '..')
    $scriptPath = Join-Path $repoRoot 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
    $outDir = Join-Path $TestDrive 'loop'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $finalStatusPath = Join-Path $outDir 'final-status.json'
    $base = Join-Path $outDir 'VI1.vi'
    $head = Join-Path $outDir 'VI2.vi'
    New-Item -ItemType File -Path $base -Force | Out-Null
    New-Item -ItemType File -Path $head -Force | Out-Null

    $runner = Join-Path $outDir 'runner-finalstatus.ps1'
  $runnerContent = @"
& '$scriptPath' -Base '$base' -Head '$head' -MaxIterations 3 -IntervalSeconds 0 -FinalStatusJsonPath '$finalStatusPath' -DiffSummaryFormat None -LogVerbosity Quiet -FailOnDiff:`$false -CustomExecutor { param(`$CliPath,`$Base,`$Head,`$ExecArgs) Start-Sleep -Milliseconds 3; return 0 }
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $runner -Encoding UTF8 -Value $runnerContent

    pwsh -NoLogo -NoProfile -File $runner | Out-Null
    $exit = $LASTEXITCODE
    $exit | Should -Be 0
    Test-Path -LiteralPath $finalStatusPath | Should -BeTrue
    $json = (Get-Content -LiteralPath $finalStatusPath -Raw) | ConvertFrom-Json
  $json.schema | Should -Be 'loop-final-status-v1'
  Assert-JsonShape -Path $finalStatusPath -Spec 'FinalStatus' | Should -BeTrue
    $json.iterations | Should -Be 3
    $json.errors | Should -Be 0
    $json.succeeded | Should -BeTrue
    $json.basePath | Should -Match 'VI1\.vi'
    $json.headPath | Should -Match 'VI2\.vi'
  }
}

Describe 'Run-AutonomousIntegrationLoop DiffExitCode behavior' -Tag 'Unit' {
  BeforeAll { . "$PSScriptRoot/TestHelpers.Schema.ps1" }
  It 'returns custom diff exit code when diffs detected and no errors' {
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Resolve-Path (Join-Path $here '..')
    $scriptPath = Join-Path $repoRoot 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
    $outDir = Join-Path $TestDrive 'loop-diff'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $finalStatusPath = Join-Path $outDir 'final-status.json'
    $base = Join-Path $outDir 'A.vi'
    $head = Join-Path $outDir 'B.vi'
    New-Item -ItemType File -Path $base -Force | Out-Null
    New-Item -ItemType File -Path $head -Force | Out-Null
    $customDiffExit = 42
    $runner = Join-Path $outDir 'runner-diffexit.ps1'
  $runnerContent = @"
& '$scriptPath' -Base '$base' -Head '$head' -MaxIterations 2 -IntervalSeconds 0 -FinalStatusJsonPath '$finalStatusPath' -DiffSummaryFormat None -LogVerbosity Quiet -FailOnDiff:`$false -DiffExitCode $customDiffExit -CustomExecutor { param(`$CliPath,`$Base,`$Head,`$ExecArgs) Start-Sleep -Milliseconds 3; return 1 }
exit `$LASTEXITCODE
"@
    Set-Content -LiteralPath $runner -Encoding UTF8 -Value $runnerContent
    pwsh -NoLogo -NoProfile -File $runner | Out-Null
    $exit = $LASTEXITCODE
    $exit | Should -Be $customDiffExit
    $json = (Get-Content -LiteralPath $finalStatusPath -Raw) | ConvertFrom-Json
    $json.diffs | Should -BeGreaterThan 0
    $json.errors | Should -Be 0
    $json.succeeded | Should -BeTrue
  }
}

Describe 'Run-AutonomousIntegrationLoop TestStand harness mode' -Tag 'Unit' {
  It 'invokes the TestStand harness for each iteration with expected parameters' {
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Resolve-Path (Join-Path $here '..')
    $scriptPath = Join-Path $repoRoot 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
    $outDir = Join-Path $TestDrive 'loop-harness'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $base = Join-Path $outDir 'BaseHarness.vi'
    $head = Join-Path $outDir 'HeadHarness.vi'
    New-Item -ItemType File -Path $base -Force | Out-Null
    New-Item -ItemType File -Path $head -Force | Out-Null

    $harnessStub = Join-Path $outDir 'TestStand-CompareHarness.ps1'
    $logPath = Join-Path $outDir 'harness-log.ndjson'
    $outputRoot = Join-Path $outDir 'outputs'
$stubContent = @"
param(
  [string]`$BaseVi,
  [string]`$HeadVi,
  [Alias('LabVIEWPath')][string]`$LabVIEWExePath,
  [string]`$LabVIEW64ExePath,
  [string]`$LabVIEW32ExePath,
  [Alias('LVCompareExePath')][string]`$LVComparePath,
  [string]`$AgentId,
  [string]`$AgentClass,
  [string]`$ExecutionCellLeasePath,
  [string]`$ExecutionCellId,
  [string]`$ExecutionCellLeaseId,
  [string]`$HarnessInstanceId,
  [string]`$OutputRoot,
  [ValidateSet('detect','spawn','skip')][string]`$Warmup,
  [ValidateSet('single-compare','dual-plane-parity')][string]`$SuiteClass = 'single-compare',
  [string[]]`$Flags,
  [switch]`$RenderReport,
  [switch]`$CloseLabVIEW,
  [switch]`$CloseLVCompare,
  [int]`$TimeoutSeconds,
  [switch]`$DisableTimeout,
  [switch]`$ReplaceFlags
)
`$log = `$env:HARNESS_LOG
if (-not `$log) { `$log = Join-Path (Split-Path `$OutputRoot -Parent) 'harness-log.ndjson' }
`$logDir = Split-Path -Parent `$log
if (`$logDir -and -not (Test-Path `$logDir)) { New-Item -ItemType Directory -Path `$logDir -Force | Out-Null }
`$payload = [ordered]@{
  base = `$BaseVi
  head = `$HeadVi
  output = `$OutputRoot
  warmup = `$Warmup
  suiteClass = `$SuiteClass
  labviewExe = `$LabVIEWExePath
  labview64Exe = `$LabVIEW64ExePath
  labview32Exe = `$LabVIEW32ExePath
  agentId = `$AgentId
  agentClass = `$AgentClass
  executionCellLeasePath = `$ExecutionCellLeasePath
  executionCellId = `$ExecutionCellId
  executionCellLeaseId = `$ExecutionCellLeaseId
  harnessInstanceId = `$HarnessInstanceId
  flags = @(`$Flags)
  renderReport = `$RenderReport.IsPresent
  closeLabVIEW = `$CloseLabVIEW.IsPresent
  closeLVCompare = `$CloseLVCompare.IsPresent
  timeout = `$TimeoutSeconds
  disableTimeout = `$DisableTimeout.IsPresent
  replaceFlags = `$ReplaceFlags.IsPresent
}
(`$payload | ConvertTo-Json -Compress) | Add-Content -Path `$log
if (`$env:HARNESS_EXIT_CODE) { exit [int]`$env:HARNESS_EXIT_CODE }
exit 0
"@
    Set-Content -LiteralPath $harnessStub -Encoding UTF8 -Value $stubContent

    $env:HARNESS_LOG = $logPath
    try {
      $runner = Join-Path $outDir 'runner-harness.ps1'
      $runnerContent = @"
& '$scriptPath' -Base '$base' -Head '$head' -MaxIterations 2 -IntervalSeconds 0 -LogVerbosity Quiet -LvCompareArgs '-foo 1 -bar' -UseTestStandHarness -TestStandHarnessPath '$harnessStub' -TestStandOutputRoot '$outputRoot' -TestStandWarmup detect -TestStandSuiteClass dual-plane-parity -TestStandLabVIEW64Path 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe' -TestStandLabVIEW32Path 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' -TestStandAgentId 'hooke' -TestStandAgentClass 'subagent' -TestStandExecutionCellLeasePath 'E:\comparevi-lanes\cells\hooke-01\execution-cell.json' -TestStandExecutionCellId 'exec-cell-hooke-loop-01' -TestStandExecutionCellLeaseId 'lease-hooke-loop-01' -TestStandHarnessInstanceId 'ts-loop-hooke-01' -TestStandRenderReport -TestStandCloseLabVIEW -TestStandCloseLVCompare -TestStandTimeoutSeconds 45 -TestStandReplaceFlags -FinalStatusJsonPath '$outDir/final.json'
exit `$LASTEXITCODE
"@
      Set-Content -LiteralPath $runner -Encoding UTF8 -Value $runnerContent

      pwsh -NoLogo -NoProfile -File $runner | Out-Null
      $LASTEXITCODE | Should -Be 0

      Test-Path -LiteralPath $logPath | Should -BeTrue
      $entries = Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json }
      $entries.Count | Should -Be 2
      $entries[0].output | Should -Match 'iteration-0001$'
      $entries[1].output | Should -Match 'iteration-0002$'
      $entries | ForEach-Object { $_.warmup } | Sort-Object -Unique | Should -Be @('detect')
      $entries | ForEach-Object { $_.suiteClass } | Sort-Object -Unique | Should -Be @('dual-plane-parity')
      $entries | ForEach-Object { $_.labview64Exe } | Sort-Object -Unique | Should -Be @('C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe')
      $entries | ForEach-Object { $_.labview32Exe } | Sort-Object -Unique | Should -Be @('C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe')
      $entries | ForEach-Object { $_.agentId } | Sort-Object -Unique | Should -Be @('hooke')
      $entries | ForEach-Object { $_.agentClass } | Sort-Object -Unique | Should -Be @('subagent')
      $entries | ForEach-Object { $_.executionCellLeasePath } | Sort-Object -Unique | Should -Be @('E:\comparevi-lanes\cells\hooke-01\execution-cell.json')
      $entries | ForEach-Object { $_.executionCellId } | Sort-Object -Unique | Should -Be @('exec-cell-hooke-loop-01')
      $entries | ForEach-Object { $_.executionCellLeaseId } | Sort-Object -Unique | Should -Be @('lease-hooke-loop-01')
      $entries | ForEach-Object { $_.harnessInstanceId } | Sort-Object -Unique | Should -Be @('ts-loop-hooke-01')
      $entries | ForEach-Object { $_.renderReport } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.closeLabVIEW } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.closeLVCompare } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { [int]$_.timeout } | Sort-Object -Unique | Should -Be @(45)
      $entries | ForEach-Object { $_.replaceFlags } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.flags } | ForEach-Object { $_ } | Sort-Object -Unique | Should -Be @('-bar','-foo','1')

      $finalStatus = Get-Content -LiteralPath (Join-Path $outDir 'final.json') -Raw | ConvertFrom-Json
      $finalStatus.harness.path | Should -Be $harnessStub
      $finalStatus.harness.output | Should -Be $outputRoot
      $finalStatus.harness.suiteClass | Should -Be 'dual-plane-parity'
      $finalStatus.harness.runtimeSurface | Should -Be 'windows-native-teststand'
      $finalStatus.harness.processModelClass | Should -Be 'parallel-process-model'
      $finalStatus.harness.windowsOnly | Should -BeTrue
      $finalStatus.harness.requestedSimultaneous | Should -BeTrue
      $finalStatus.harness.executionCellLeasePath | Should -Be 'E:\comparevi-lanes\cells\hooke-01\execution-cell.json'
      $finalStatus.harness.executionCellId | Should -Be 'exec-cell-hooke-loop-01'
      $finalStatus.harness.executionCellLeaseId | Should -Be 'lease-hooke-loop-01'
      $finalStatus.harness.harnessInstanceId | Should -Be 'ts-loop-hooke-01'
    }
    finally {
      Remove-Item Env:HARNESS_LOG -ErrorAction SilentlyContinue
    }
  }
}
