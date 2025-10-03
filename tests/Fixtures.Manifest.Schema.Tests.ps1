Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture manifest schema surface (lightweight)' -Tag 'Unit' {
  It 'has required top-level fields' {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'fixtures.manifest.json') -Raw | ConvertFrom-Json
    $manifest.schema | Should -Be 'fixture-manifest-v1'
  # Normalize items (PowerShell JSON parser yields Object[] for arrays; guard single-object case)
  if ($manifest.items -is [System.Array]) { $items = $manifest.items } else { $items = @($manifest.items) }
  ($items | Measure-Object).Count | Should -BeGreaterThan 0
  (@($items | Where-Object { -not $_.path }) | Measure-Object).Count | Should -Be 0
  (@($items | Where-Object { $_.sha256 -notmatch '^[A-Fa-f0-9]{64}$' }) | Measure-Object).Count | Should -Be 0
  }
}
