Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Smoke workflow JSON validator guard' -Tag 'Unit' {
  It 'contains JSON validator step and artifact upload' {
    $wf = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '.github' 'workflows' 'smoke.yml') -Raw
    $wf | Should -Match 'Validate canonical fixtures \(JSON\)'
    $wf | Should -Match 'fixture-validation.json'
    $wf | Should -Match 'fixture-validation-json'
  }

  It 'contains early fail policy step' {
    $wf = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '.github' 'workflows' 'smoke.yml') -Raw
    $wf | Should -Match 'Enforce fixture policy'
    $wf | Should -Match 'disallowed fixture issues'
  }
}
