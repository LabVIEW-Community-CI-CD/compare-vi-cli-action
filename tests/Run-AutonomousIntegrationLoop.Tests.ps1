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
  [Alias('LVCompareExePath')][string]`$LVComparePath,
  [string]`$OutputRoot,
  [ValidateSet('detect','spawn','skip')][string]`$Warmup,
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
& '$scriptPath' -Base '$base' -Head '$head' -MaxIterations 2 -IntervalSeconds 0 -LogVerbosity Quiet -LvCompareArgs '-foo 1 -bar' -UseTestStandHarness -TestStandHarnessPath '$harnessStub' -TestStandOutputRoot '$outputRoot' -TestStandWarmup detect -TestStandRenderReport -TestStandCloseLabVIEW -TestStandCloseLVCompare -TestStandTimeoutSeconds 45 -TestStandReplaceFlags -FinalStatusJsonPath '$outDir/final.json'
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
      $entries | ForEach-Object { $_.renderReport } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.closeLabVIEW } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.closeLVCompare } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { [int]$_.timeout } | Sort-Object -Unique | Should -Be @(45)
      $entries | ForEach-Object { $_.replaceFlags } | Sort-Object -Unique | Should -Be @($true)
      $entries | ForEach-Object { $_.flags } | ForEach-Object { $_ } | Sort-Object -Unique | Should -Be @('-bar','-foo','1')
    }
    finally {
      Remove-Item Env:HARNESS_LOG -ErrorAction SilentlyContinue
    }
  }
}
