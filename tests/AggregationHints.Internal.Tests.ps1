Describe 'AggregationHints Internal Builder' -Tag 'Unit' {
  BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts' 'AggregationHints.Internal.ps1')
  }

  It 'produces fallback suggestions when no tests provided' {
    $block = Get-AggregationHintsBlock -Tests @()
    $block.strategy | Should -Be 'heuristic/v1'
    $block.dominantTags.Count | Should -Be 0
    $block.suggestions | Should -Contain 'tag-more-tests'
  }

  It 'aggregates tags, file buckets and durations' {
    $tests = @(
      [pscustomobject]@{ Path='file1'; Tags=@('Slow','UI'); Duration=0.2 },
      [pscustomobject]@{ Path='file1'; Tags=@('Slow'); Duration=2.1 },
      [pscustomobject]@{ Path='file2'; Tags=@('DB'); Duration=6.5 }
    )
    $block = Get-AggregationHintsBlock -Tests $tests
    $block.dominantTags | Should -Contain 'Slow'
    $block.fileBucketCounts.small | Should -Be 2  # file1 has 2 tests, file2 has 1
    ($block.durationBuckets.subSecond + $block.durationBuckets.oneToFive + $block.durationBuckets.overFive) | Should -Be 3
    $block.durationBuckets.subSecond | Should -Be 1
    $block.durationBuckets.oneToFive | Should -Be 1
    $block.durationBuckets.overFive | Should -Be 1
    $block.suggestions | Should -Not -BeNullOrEmpty
  }
}

# Dispatcher integration is covered by outer run when -EmitAggregationHints used; avoid recursive invocation here.