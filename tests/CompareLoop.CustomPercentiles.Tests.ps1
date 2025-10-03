Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force
$helperModule = Join-Path $PSScriptRoot 'helpers' 'CompareLoop.TestHelpers.psm1'
Import-Module $helperModule -Force

Describe 'Invoke-IntegrationCompareLoop custom percentiles' -Tag 'Unit' {
  BeforeAll {
    $script:base = Join-Path $PSScriptRoot '..' 'VI1.vi'
    $script:head = Join-Path $PSScriptRoot '..' 'VI2.vi'
    # Ensure placeholder files exist in case prior cleanup removed them
    if (-not (Test-Path -LiteralPath $script:base)) { 'a' | Out-File -FilePath $script:base -Encoding utf8 }
    if (-not (Test-Path -LiteralPath $script:head)) { 'b' | Out-File -FilePath $script:head -Encoding utf8 }
  }

  It 'accepts a custom percentile list and exposes dynamic properties' {
  $exec = New-LoopExecutor -DelayMilliseconds 5
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 10 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '50,75,90,97.5,99.9'
    $r.Percentiles | Should -Not -BeNullOrEmpty
    $r.Percentiles.p50 | Should -BeGreaterThan 0
    $r.Percentiles.p75 | Should -BeGreaterThan 0
    $r.Percentiles.p90 | Should -BeGreaterThan 0
    $r.Percentiles.'p97_5' | Should -BeGreaterThan 0
    $r.Percentiles.'p99_9' | Should -BeGreaterThan 0
  }

  It 'defaults to standard percentiles when list omitted' {
  $exec = New-LoopExecutor -DelayMilliseconds 8
  $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 6 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
  # Validate default keys exist and are numeric (>=0)
  $r.Percentiles.p50 | Should -Not -BeNullOrEmpty
  $r.Percentiles.p90 | Should -Not -BeNullOrEmpty
  $r.Percentiles.p99 | Should -Not -BeNullOrEmpty
  ($r.Percentiles.p90 -ge $r.Percentiles.p50) | Should -BeTrue
  }

  It 'rejects invalid percentiles with clear error' {
    { Invoke-IntegrationCompareLoop -Base X -Head Y -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '0,50,101' } | Should -Throw '*out of range*'
  }

  It 'rejects non-numeric tokens' {
    { Invoke-IntegrationCompareLoop -Base X -Head Y -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '50,abc,90' } | Should -Throw '*Invalid percentile value*'
  }
}