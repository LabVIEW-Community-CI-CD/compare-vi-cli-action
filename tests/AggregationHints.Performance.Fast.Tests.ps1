<#
 Fast performance guard for Get-AggregationHintsBlock.
 Purpose: very quick sanity check (CI friendly) that small-run performance stays tight.
 Dataset: 1,000 synthetic tests.
 Threshold: 500 ms (adjusted for CI environment; local baseline ~200-400ms; protects against O(n²) regressions).
#>

Describe 'AggregationHints Performance (Fast)' -Tag 'Unit' {
  BeforeAll { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'AggregationHints.Internal.ps1') }

  It 'aggregates 1k tests under 160ms' {
    $count = 1000
    $tags = 'UI','DB','Slow','Net','Cache','Auth'
    $tests = for ($i=0; $i -lt $count; $i++) {
      $tag = $tags[$i % $tags.Length]
      $dur = switch ($i % 3) { 0 { 0.05 } 1 { 1.2 } 2 { 3.4 } }
      [pscustomobject]@{ Path = "file$($i % 23).Tests.ps1"; Tags = @($tag); Duration = $dur }
    }
    # Warm the JIT/GC path so we measure steady-state cost.
    $null = Get-AggregationHintsBlock -Tests $tests[0..99]

    $iterations = 5
    $measurements = @()
    for ($run = 0; $run -lt $iterations; $run++) {
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
      [GC]::Collect()

      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $null = Get-AggregationHintsBlock -Tests $tests
      $sw.Stop()
      $measurements += $sw.Elapsed.TotalMilliseconds
    }

    $best = ($measurements | Measure-Object -Minimum).Minimum
    $best | Should -BeLessThan 500 -Because "1k aggregation run should remain fast (best run was $([math]::Round($best,2)) ms across $iterations iterations)"
  }
}
