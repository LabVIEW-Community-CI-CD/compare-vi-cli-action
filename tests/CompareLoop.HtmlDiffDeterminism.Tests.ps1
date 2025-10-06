# Deterministic HTML diff fragment regression test
# Tag: Unit
# Purpose: Ensure HTML diff summary is byte-for-byte stable and ordering is deterministic

Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot/../module/CompareLoop/CompareLoop.psm1" -Force

Describe 'Invoke-IntegrationCompareLoop HTML diff summary determinism' -Tag 'Unit' {
  BeforeAll {
    $script:base = Join-Path $TestDrive 'VI1.vi'
    $script:head = Join-Path $TestDrive 'VI2.vi'
    Set-Content -Path $script:base -Value 'BASE_CONTENT'
    Set-Content -Path $script:head -Value 'HEAD_CONTENT'
  }

  It 'produces identical HTML fragment across multiple invocations with same inputs' {
    # Run the same scenario twice and verify byte-for-byte identity
    $executor = { param($cli,$b,$h,$lvArgs) return 1 }  # Always diff
    
    $result1 = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 3 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -Quiet

    $result2 = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 3 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -Quiet

    $result1.DiffSummary | Should -Not -BeNullOrEmpty
    $result2.DiffSummary | Should -Not -BeNullOrEmpty
    $result1.DiffSummary | Should -BeExactly $result2.DiffSummary
  }

  It 'maintains deterministic list item order: Base, Head, Diff Iterations, Total Iterations' {
    $executor = { param($cli,$b,$h,$lvArgs) return 1 }
    
    $result = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -Quiet

    $html = $result.DiffSummary
    $html | Should -Not -BeNullOrEmpty
    
    # Verify structure and ordering using regex
    $html | Should -Match '<h3>VI Compare Diff Summary</h3>'
    $html | Should -Match '<ul>'
    
    # Extract list items using regex (HTML uses <b> tags, not <strong>)
    $matches = [regex]::Matches($html, '<li><b>([^<]+)</b>')
    
    $matches.Count | Should -BeGreaterOrEqual 4
    $matches[0].Groups[1].Value | Should -Be 'Base:'
    $matches[1].Groups[1].Value | Should -Be 'Head:'
    $matches[2].Groups[1].Value | Should -Be 'Diff Iterations:'
    $matches[3].Groups[1].Value | Should -Be 'Total Iterations:'
  }

  It 'properly HTML-encodes special characters in file paths' {
    # Use synthetic raw paths (not touching filesystem) with characters requiring HTML encoding.
    $baseRaw = 'C:\FAKE\path & one <base> "file".vi'
    $headRaw = 'D:\VIRTUAL\another & two <head> "file".vi'

    $executor = { param($cli,$b,$h,$lvArgs) return 1 }

    $result = Invoke-IntegrationCompareLoop -Base $baseRaw -Head $headRaw `
      -MaxIterations 2 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -Quiet

    $html = $result.DiffSummary
    $html | Should -Not -BeNullOrEmpty

    # Assert encoded entities present
    $html | Should -Match '&amp;'
    $html | Should -Match '&lt;'
    $html | Should -Match '&gt;'
    $html | Should -Match '&quot;'

    # Assert raw unencoded sequences (with special chars) are not present
    $html | Should -Not -Match 'path & one <base>'
    $html | Should -Not -Match 'two <head>'
  }

  It 'does not emit HTML fragment when no diffs detected' {
    # All iterations return 0 (no diff)
    $executor = { param($cli,$b,$h,$lvArgs) return 0 }
    
    $result = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 5 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -Quiet

    $result.DiffCount | Should -Be 0
    $result.DiffSummary | Should -BeNullOrEmpty
  }

  It 'writes deterministic HTML file when path specified' {
    $summaryPath1 = Join-Path $TestDrive 'summary1.html'
    $summaryPath2 = Join-Path $TestDrive 'summary2.html'
    
    $executor = { param($cli,$b,$h,$lvArgs) return 1 }
    
    $result1 = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 4 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -DiffSummaryPath $summaryPath1 -Quiet

    $result2 = Invoke-IntegrationCompareLoop -Base $script:base -Head $script:head `
      -MaxIterations 4 -IntervalSeconds 0 -CompareExecutor $executor `
      -SkipValidation -PassThroughPaths -BypassCliValidation `
      -DiffSummaryFormat Html -DiffSummaryPath $summaryPath2 -Quiet

    Test-Path -LiteralPath $summaryPath1 | Should -BeTrue
    Test-Path -LiteralPath $summaryPath2 | Should -BeTrue
    
    $file1 = Get-Content -LiteralPath $summaryPath1 -Raw
    $file2 = Get-Content -LiteralPath $summaryPath2 -Raw
    
    $file1 | Should -BeExactly $file2
  }
}
