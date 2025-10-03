Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
$helperModule = Join-Path $PSScriptRoot 'helpers' 'CompareLoop.TestHelpers.psm1'
Import-Module $helperModule -Force

Describe 'Invoke-IntegrationCompareLoop New-Exec closure behavior' -Tag 'Unit' {
  It 'captures delay value without $delayMs runtime error' {
  # Arrange: use shared helper factory for closure-based executor
  # Use $TestDrive to isolate artifacts
  # Migrated from Base/Head to VI1/VI2
  $base = Join-Path $TestDrive 'VI1.vi'
  $head = Join-Path $TestDrive 'VI2.vi'
  'a' | Out-File -FilePath $base -Encoding utf8
  'b' | Out-File -FilePath $head -Encoding utf8

    # Act
  $exec = New-LoopExecutor -DelayMilliseconds 5
  $r = Invoke-IntegrationCompareLoop -Base $base -Head $head -MaxIterations 3 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet

    # Assert: no runtime error, iterations recorded, and average seconds >= 0
    $r.Succeeded | Should -BeTrue
    $r.Iterations | Should -BeGreaterOrEqual 3
    $r.AverageSeconds | Should -BeGreaterOrEqual 0
  }
}
