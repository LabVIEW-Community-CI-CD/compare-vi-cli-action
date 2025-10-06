Set-StrictMode -Version Latest

Describe 'Run-AutonomousIntegrationLoop LoopEvent NDJSON schema' -Tag 'Unit' {
  BeforeAll {
    $root = Split-Path -Parent $PSCommandPath | Split-Path -Parent
    $scriptPath = Join-Path $root 'scripts' 'Run-AutonomousIntegrationLoop.ps1'
    Test-Path $scriptPath | Should -BeTrue
    . "$PSScriptRoot/TestHelpers.Schema.ps1"
    $script:tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("eventsch_" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:tmpDir | Out-Null
  }

  AfterAll {
    if (Test-Path $script:tmpDir) { Remove-Item -Recurse -Force $script:tmpDir }
  }

  It 'emits LoopEvent lines conforming to schema (no rotation)' {
    $jsonLog = Join-Path $script:tmpDir 'loop.events.json'
    $final   = Join-Path $script:tmpDir 'final-status.json'
    $base = Join-Path $script:tmpDir 'VI1.vi'; New-Item -ItemType File -Path $base -Force | Out-Null
    $head = Join-Path $script:tmpDir 'VI2.vi'; New-Item -ItemType File -Path $head -Force | Out-Null

    & $scriptPath -Base $base -Head $head -MaxIterations 8 -IntervalSeconds 0 -JsonLogPath $jsonLog -JsonLogMaxBytes 500000 -FinalStatusJsonPath $final -DiffSummaryFormat None -FailOnDiff:$false -LogVerbosity Quiet -CustomExecutor { param($CliPath,$Base,$Head,$ExecArgs) return 0 }
    $LASTEXITCODE | Should -Be 0

    Test-Path $jsonLog | Should -BeTrue
    # Validate every line
    Assert-NdjsonShapes -Path $jsonLog -Spec 'LoopEvent' | Should -BeTrue

    # Ensure at least one meta and one result/final status emitted
    $objs = Get-Content -LiteralPath $jsonLog | ForEach-Object { $_ | ConvertFrom-Json }
    ($objs | Where-Object { $_.type -eq 'meta' }).Count | Should -BeGreaterThan 0
    ($objs | Where-Object { $_.type -eq 'result' }).Count | Should -BeGreaterThan 0
    ($objs | Where-Object { $_.type -eq 'final' -or $_.type -eq 'finalStatusEmitted' }).Count | Should -BeGreaterThan 0
  }
}
