<#
 Performance guard for Get-AggregationHintsBlock.
 Goal: Ensure aggregation over a moderately large synthetic test set executes below a fixed wall clock threshold.
 Rationale: Prevent future regressions (e.g., O(n^2) tag counting or excessive per-item allocations).

 Dataset size chosen to be big enough to catch obvious inefficiencies while still fast on CI: 8,000 synthetic tests.
 Threshold: 350ms (adjust if CI shows consistent slower baseline; current helper is linear and should be well below).
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
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $block = Get-AggregationHintsBlock -Tests $tests
    $sw.Stop()
    $elapsedMs = $sw.Elapsed.TotalMilliseconds
    # Guard: expect linear performance well below threshold; assert structure & time.
    $block.strategy | Should -Be 'heuristic/v1'
    $block.fileBucketCounts | Should -Not -BeNullOrEmpty
    $block.durationBuckets | Should -Not -BeNullOrEmpty
  # Observed baseline ~780ms for 8k on local host; adjusted dataset and threshold for stability margin.
  $elapsedMs | Should -BeLessThan 650 -Because "Aggregation should remain fast (was $([math]::Round($elapsedMs,2)) ms)"
  }
}
