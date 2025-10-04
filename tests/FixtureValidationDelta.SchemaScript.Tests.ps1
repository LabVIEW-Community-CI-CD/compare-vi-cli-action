Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Delta schema validation script' -Tag 'Unit' {
  It 'returns 0 on valid delta JSON' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $schemaScript = Join-Path $repoRoot 'tools' 'Test-FixtureValidationDeltaSchema.ps1'
    $baseline = Join-Path $repoRoot 'baseline-fixture-validation.json'
    $current  = Join-Path $repoRoot 'current-fixture-validation.json'

    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    $manifestPath = Join-Path $repoRoot 'fixtures.manifest.json'
    $orig = Get-Content -LiteralPath $manifestPath -Raw
    $m = $orig | ConvertFrom-Json
    $dup = $m.items[0] | Select-Object *
    $m.items += $dup
    ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $currRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $currIdx = $currRaw.IndexOf('{'); $currEnd = $currRaw.LastIndexOf('}')
    $currOut = $currRaw.Substring($currIdx, $currEnd-$currIdx+1)
    Set-Content -LiteralPath $current -Value $currOut -Encoding utf8
    $orig | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline

    pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current > delta.json
    pwsh -NoLogo -NoProfile -File $schemaScript -DeltaJsonPath delta.json
    $LASTEXITCODE | Should -Be 0
  }
}
