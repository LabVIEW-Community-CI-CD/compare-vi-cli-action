<#
 Performance guard for Get-AggregationHintsBlock.
 Goal: Ensure aggregation over a moderately large synthetic test set executes below a fixed wall clock threshold.
 Rationale: Prevent future regressions (e.g., O(n^2) tag counting or excessive per-item allocations).

 Dataset size chosen to be big enough to catch obvious inefficiencies while still fast on CI: 6,000 synthetic tests.
 Threshold: 2000ms (adjusted for CI environment; local baseline ~700-1600ms; guards against quadratic regressions).
 If this proves flaky on slower hosts, raise threshold conservatively (document rationale in CHANGELOG if bumped).
#>

Describe 'AggregationHints Performance' -Tag 'Unit' {
  BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'AggregationHints.Internal.ps1')
  }

  It 'builds aggregation hints under threshold for 6k synthetic tests' {
    $count = 6000
    # Create synthetic tests with rotating tags to exercise dominant tag logic and all duration buckets.
    $tags = 'UI','DB','Slow','Net','Cache','Auth'
    $tests = for ($i=0; $i -lt $count; $i++) {
      $tag = $tags[$i % $tags.Length]
      $dur = switch ($i % 3) { 0 { 0.15 } 1 { 2.3 } 2 { 6.7 } }
      [pscustomobject]@{ Path = "file$($i % 37).Tests.ps1"; Tags = @($tag); Duration = $dur }
    }
    # Warm JIT/GC so we measure steady state.
    $null = Get-AggregationHintsBlock -Tests $tests[0..499]

    $iterations = 5
    $best = [double]::PositiveInfinity
    $bestBlock = $null
    for ($run = 0; $run -lt $iterations; $run++) {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      [GC]::Collect()

      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $current = Get-AggregationHintsBlock -Tests $tests
      $sw.Stop()
      $elapsedMs = $sw.Elapsed.TotalMilliseconds
      if ($elapsedMs -lt $best) {
        $best = $elapsedMs
        $bestBlock = $current
      }
    }

    # Guard: expect linear performance well below threshold; assert structure & time.
    $bestBlock.strategy | Should -Be 'heuristic/v1'
    $bestBlock.fileBucketCounts | Should -Not -BeNullOrEmpty
    $bestBlock.durationBuckets | Should -Not -BeNullOrEmpty
  # Observed baseline ~780ms for 8k on local host; adjusted dataset and threshold for CI stability (6k @ ~2000ms ceiling).
  $best | Should -BeLessThan 2000 -Because "Aggregation should remain fast (best run was $([math]::Round($best,2)) ms across $iterations iterations)"
  }
}
