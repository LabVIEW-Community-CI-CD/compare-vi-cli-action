# Tests for reconciliation behavior of StreamingReservoir strategy
Import-Module "$PSScriptRoot/../module/CompareLoop/CompareLoop.psm1" -Force

Describe 'Invoke-IntegrationCompareLoop streaming reconciliation' -Tag 'Unit' {
  BeforeAll {
    $script:basePath = Join-Path $PSScriptRoot '..' 'VI1.vi'
    $script:headPath = Join-Path $PSScriptRoot '..' 'VI2.vi'
  }

  It 'maintains reservoir at capacity and reports window size' {
    $rand = [System.Random]::new(5)
  $exec = { param($cli,$b,$h,$lvArgs) $ms = 3 + $rand.NextDouble()*7; Start-Sleep -Milliseconds ([int]$ms); 0 }
    $cap = 40
    $r = Invoke-IntegrationCompareLoop -Base $script:basePath -Head $script:headPath -MaxIterations 120 -IntervalSeconds 0 -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet -QuantileStrategy StreamingReservoir -StreamCapacity $cap -ReconcileEvery 60
    $r.QuantileStrategy | Should -Be 'StreamingReservoir'
    $r.StreamingWindowCount | Should -Be $cap
    $r.Percentiles.p50 | Should -BeGreaterThan 0
  }

  It 'reconciliation does not degrade percentile accuracy vs exact beyond tolerance' {
    $rand1 = [System.Random]::new(17)
    $rand2 = [System.Random]::new(17)
  $exec1 = { param($cli,$b,$h,$lvArgs) $ms = 2 + $rand1.NextDouble()*10; Start-Sleep -Milliseconds ([int]$ms); 0 }
  $exec2 = { param($cli,$b,$h,$lvArgs) $ms = 2 + $rand2.NextDouble()*10; Start-Sleep -Milliseconds ([int]$ms); 0 }
    $common = @{ Base=$script:basePath; Head=$script:headPath; MaxIterations=250; IntervalSeconds=0; SkipValidation=$true; PassThroughPaths=$true; BypassCliValidation=$true; Quiet=$true }
    $exact = Invoke-IntegrationCompareLoop @common -QuantileStrategy Exact -CompareExecutor $exec1
    $recon = Invoke-IntegrationCompareLoop @common -QuantileStrategy StreamingReservoir -StreamCapacity 60 -ReconcileEvery 100 -CompareExecutor $exec2
    $tol = 0.03
    [math]::Abs($recon.Percentiles.p50 - $exact.Percentiles.p50) | Should -BeLessOrEqual $tol
    [math]::Abs($recon.Percentiles.p90 - $exact.Percentiles.p90) | Should -BeLessOrEqual $tol
    [math]::Abs($recon.Percentiles.p99 - $exact.Percentiles.p99) | Should -BeLessOrEqual ($tol*1.5)
  }
}
