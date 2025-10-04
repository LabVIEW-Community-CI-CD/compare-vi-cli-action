Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture validation delta schema' -Tag 'Unit' {
  It 'emits JSON matching schema fixture-validation-delta-v1' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $baseline = Join-Path $repoRoot 'baseline-fixture-validation.json'
    $current  = Join-Path $repoRoot 'current-fixture-validation.json'

    # Produce baseline snapshot (force small minBytes, ignore token behavior)
    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    # Produce modified current snapshot by duplicating a manifest entry (simulate structural change)
    $manifestPath = Join-Path $repoRoot 'fixtures.manifest.json'
    $originalManifest = Get-Content -LiteralPath $manifestPath -Raw
    $m = $originalManifest | ConvertFrom-Json
    $dup = $m.items[0] | Select-Object *
    $m.items += $dup
    ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $currRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $currIdx = $currRaw.IndexOf('{'); $currEnd = $currRaw.LastIndexOf('}')
    $currOut = $currRaw.Substring($currIdx, $currEnd-$currIdx+1)
    Set-Content -LiteralPath $current -Value $currOut -Encoding utf8
    # Restore manifest
    $originalManifest | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

    $deltaRaw = (pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current | Out-String)
    $delta = $deltaRaw | ConvertFrom-Json
    $delta.schema | Should -Be 'fixture-validation-delta-v1'
    $delta.changes | Should -Not -BeNullOrEmpty
    ($delta.changes | Where-Object { $_.category -eq 'duplicate' }).Count | Should -Be 1
    $delta.newStructuralIssues | Should -Not -BeNullOrEmpty
    $delta.deltaCounts.duplicate | Should -Be 1
  }
}
