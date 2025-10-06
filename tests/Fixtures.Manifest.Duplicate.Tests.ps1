Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture manifest duplicate detection' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script:validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    # Work on a temp manifest copy to avoid mutating repository files
    $script:manifestPath = Join-Path $TestDrive 'fixtures.manifest.json'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures.manifest.json') -Destination $manifestPath -Force
    $script:original = Get-Content -LiteralPath $manifestPath -Raw
  }

  It 'returns exit 8 for duplicate entries only' {
    $m = $original | ConvertFrom-Json
    foreach ($it in $m.items) { $it.bytes = (Get-Item -LiteralPath (Join-Path $repoRoot $it.path)).Length }
    # Add a duplicate of first item
    $dup = $m.items[0] | Select-Object *
    $m.items += $dup
    ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding utf8
    # Allow hash mismatches so duplicate is the only structural issue considered
    pwsh -NoLogo -NoProfile -File $validator -DisableToken -MinBytes 1 -TestAllowFixtureUpdate -ManifestPath $manifestPath | Out-Null
    # If only duplicate issue should be 8 (not aggregated with others)
    $LASTEXITCODE | Should -Be 8
  }
}
