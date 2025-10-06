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
