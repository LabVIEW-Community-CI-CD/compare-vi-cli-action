Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path
Import-Module (Join-Path $repoRoot 'module' 'CompareLoop' 'CompareLoop.psd1') -Force

Describe 'Invoke-IntegrationCompareLoop percentile edge handling' -Tag 'Unit' {
  BeforeAll {
  # Migrated from Base/Head to VI1/VI2
  $script:base = Join-Path $TestDrive 'VI1.vi'
  $script:head = Join-Path $TestDrive 'VI2.vi'
    'a' | Out-File -FilePath $script:base -Encoding utf8
    'b' | Out-File -FilePath $script:head -Encoding utf8
  function Test-Exec { param($cli,$b,$h,$argList) 0 }
  }

  It 'rejects out-of-range values (0 and 100)' {
    { Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '0,50,99' } | Should -Throw '*out of range*'
    { Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '50,100' } | Should -Throw '*out of range*'
  }

  It 'collapses duplicate percentile values' {
    $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 3 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '50,50,90,90,99'
    $names = $r.Percentiles | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    @($names | Where-Object { $_ -eq 'p50' }).Count | Should -Be 1
    @($names | Where-Object { $_ -eq 'p90' }).Count | Should -Be 1
  }

  It 'enforces maximum list length' {
    $values = (1..51) -join ','
    { Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 1 -IntervalSeconds 0 -CompareExecutor { 0 } -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles $values } | Should -Throw '*Too many percentile values*'
  }

  It 'accepts fractional values and underscores label' {
    # Use executor with small sleep to ensure non-zero duration samples so percentile logic engages
  $exec = { param($cli,$b,$h,$lvArgs) Start-Sleep -Milliseconds 5; return 0 }
    $r = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head -MaxIterations 4 -IntervalSeconds 0 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet -CustomPercentiles '50,97.5'
    $r.Percentiles.'p97_5' | Should -Not -BeNullOrEmpty
  }
}
