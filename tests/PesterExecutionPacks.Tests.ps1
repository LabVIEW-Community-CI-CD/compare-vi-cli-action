Describe 'Pester execution pack resolution' -Tag 'Unit' {
  BeforeAll {
    . (Join-Path (Join-Path $PSScriptRoot '..') 'tools/PesterExecutionPacks.ps1')
  }

  It 'resolves a named execution pack with canonical identity and base patterns' {
    $resolved = Resolve-PesterExecutionPack -ExecutionPack comparevi

    $resolved.executionPack | Should -Be 'comparevi'
    $resolved.executionPackSource | Should -Be 'declared'
    @($resolved.baseIncludePatterns) | Should -Contain 'CompareVI*.ps1'
    @($resolved.effectiveIncludePatterns) | Should -Contain 'CompareVI*.ps1'
    @($resolved.refineIncludePatterns) | Should -Be @()
  }

  It 'treats omitted pack selection as the full pack and only keeps refinements as refinements' {
    $resolved = Resolve-PesterExecutionPack -ExecutionPack '' -RefineIncludePatterns @('tests/Alpha.Unit.Tests.ps1', 'Alpha.Unit.Tests.ps1')

    $resolved.executionPack | Should -Be 'full'
    $resolved.executionPackSource | Should -Be 'default'
    @($resolved.baseIncludePatterns) | Should -Be @()
    @($resolved.refineIncludePatterns) | Should -Be @('tests/Alpha.Unit.Tests.ps1', 'Alpha.Unit.Tests.ps1')
    @($resolved.effectiveIncludePatterns) | Should -Be @('tests/Alpha.Unit.Tests.ps1', 'Alpha.Unit.Tests.ps1')
  }

  It 'accepts legacy aliases but returns canonical pack names' {
    $resolved = Resolve-PesterExecutionPack -ExecutionPack summary

    $resolved.executionPack | Should -Be 'psummary'
    @($resolved.baseIncludePatterns) | Should -Contain 'PesterSummary*.ps1'
  }
}
