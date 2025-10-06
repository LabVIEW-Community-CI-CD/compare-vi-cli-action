Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture manifest schema surface (lightweight)' -Tag 'Unit' {
  It 'has required top-level fields' {
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'fixtures.manifest.json') -Raw | ConvertFrom-Json
    $manifest.schema | Should -Be 'fixture-manifest-v1'
    @($manifest.items).Count | Should -BeGreaterThan 0
    @($manifest.items | Where-Object { -not $_.path }).Count | Should -Be 0
    @($manifest.items | Where-Object { $_.sha256 -notmatch '^[A-Fa-f0-9]{64}$' }).Count | Should -Be 0
  }
}
