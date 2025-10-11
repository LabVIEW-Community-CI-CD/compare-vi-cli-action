<#
  Smoke tests exercised by the integration runbook's Tests phase.
  Keep these assertions deterministic so the runbook can emit a stable sample.
#>

Describe 'Runbook Unit Smoke' -Tag 'Unit','Runbook' {
  It 'verifies PowerShell math is sane' {
    (1 + 1) | Should -Be 2
  }

  It 'exposes repository root location for diagnostics' {
    $root = Resolve-Path (Join-Path $PSScriptRoot '..')
    $root.ProviderPath | Should -Match 'compare-vi-cli-action'
  }
}
