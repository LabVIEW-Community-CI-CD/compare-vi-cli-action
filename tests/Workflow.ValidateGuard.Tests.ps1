Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Validate workflow guard (delta integration)' -Tag 'Unit' {
  It 'contains fixture delta cache restore and diff steps' {
    $wf = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '.github' 'workflows' 'validate.yml') -Raw
    ($wf -match 'FAIL_ON_NEW_STRUCTURAL') | Should -BeTrue
    ($wf -match 'summary-verbose') | Should -BeTrue
    ($wf -match 'SUMMARY_VERBOSE') | Should -BeTrue
    ($wf -match 'Restore previous fixture validation snapshot') | Should -BeTrue
    ($wf -match 'Compute delta vs previous snapshot') | Should -BeTrue
    ($wf -match 'Upload fixture validation delta JSON') | Should -BeTrue
    ($wf -match 'Save current snapshot to cache') | Should -BeTrue
    ($wf -match 'Lite schema validate') | Should -BeTrue
    ($wf -match 'Append fixture summary') | Should -BeTrue
    ($wf -match 'Upload fixture summary artifact') | Should -BeTrue
  }
}
