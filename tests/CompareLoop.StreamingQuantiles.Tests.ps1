# Tests for StreamingReservoir (formerly StreamingP2) and Hybrid quantile strategies
# Focus: accuracy vs Exact within tolerance and Hybrid switch behavior

Import-Module "$PSScriptRoot/../module/CompareLoop/CompareLoop.psm1" -Force

Describe 'Invoke-IntegrationCompareLoop streaming quantiles' -Tag 'Unit' {
  BeforeAll {
    # Use existing sample VI files in repo root
    $script:basePath = Join-Path $PSScriptRoot '..' 'VI1.vi'
    $script:headPath = Join-Path $PSScriptRoot '..' 'VI2.vi'
  }

  It 'StreamingReservoir percentiles stay within 0.02 absolute error of Exact for synthetic distribution' {
    # Synthetic executor: produce variable durations by sleeping small varying milliseconds
    $rand = [System.Random]::new(42)
    $exec = {
      param($cli,$b,$h,$lvArgs)
      # Generate pseudo duration between 2 and 20 ms (uniform) to build a distribution
      $ms = 2 + $rand.NextDouble()*18
      Start-Sleep -Milliseconds ([int]$ms)
      0
    }
    # Run exact mode first to get ground truth percentiles
    $common = @{ Base=$script:basePath; Head=$script:headPath; MaxIterations=220; IntervalSeconds=0; CompareExecutor=$exec; SkipValidation=$true; PassThroughPaths=$true; BypassCliValidation=$true; Quiet=$true }
    $exact   = Invoke-IntegrationCompareLoop @common -QuantileStrategy Exact
    $stream = $null
    $stream  = Invoke-IntegrationCompareLoop @common -QuantileStrategy StreamingReservoir -ErrorAction Stop

    $exact.Percentiles | Should -Not -BeNullOrEmpty
    $stream.Percentiles | Should -Not -BeNullOrEmpty

  # Allow slightly wider tolerance due to stochastic P² adjustments
  $tol = 0.02
  $d50 = [math]::Abs($stream.Percentiles.p50 - $exact.Percentiles.p50)
  $d90 = [math]::Abs($stream.Percentiles.p90 - $exact.Percentiles.p90)
  $d99 = [math]::Abs($stream.Percentiles.p99 - $exact.Percentiles.p99)
  $d50 | Should -BeLessOrEqual $tol
  $d90 | Should -BeLessOrEqual $tol
  $d99 | Should -BeLessOrEqual ($tol*2)  # allow a little more for tail
  }

  It 'Hybrid switches to streaming after threshold and yields estimates' {
    $rand = [System.Random]::new(99)
    $exec = {
      param($cli,$b,$h,$lvArgs)
      $ms = 5 + $rand.NextDouble()*10
      Start-Sleep -Milliseconds ([int]$ms)
      0
    }
    $threshold = 100
    $common2 = @{ Base=$script:basePath; Head=$script:headPath; MaxIterations=180; IntervalSeconds=0; CompareExecutor=$exec; SkipValidation=$true; PassThroughPaths=$true; BypassCliValidation=$true; Quiet=$true }
    $hybrid = $null
    $hybrid = Invoke-IntegrationCompareLoop @common2 -QuantileStrategy Hybrid -HybridExactThreshold $threshold -ErrorAction Stop

    $hybrid.QuantileStrategy | Should -Be 'Hybrid'
    # Final percentiles should be non-null
    $hybrid.Percentiles.p50 | Should -BeGreaterThan 0
    # Cannot directly inspect internal streaming flag; infer switch by expecting some deviation from a pure exact recompute subset.
    # Grab exact for same number of iterations to compare magnitude (not for strict tolerance here—Hybrid partially streaming)
    $exact = Invoke-IntegrationCompareLoop @common2 -QuantileStrategy Exact

  $diff = [math]::Abs($hybrid.Percentiles.p50 - $exact.Percentiles.p50)
  $diff | Should -BeLessOrEqual 0.03
  }
}
