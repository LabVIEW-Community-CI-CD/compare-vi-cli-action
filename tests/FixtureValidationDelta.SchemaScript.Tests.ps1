Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Delta schema validation script' -Tag 'Unit' {
  It 'returns 0 on valid delta JSON' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $schemaScript = Join-Path $repoRoot 'tools' 'Test-FixtureValidationDeltaSchema.ps1'
    $baseline = Join-Path $TestDrive 'baseline-fixture-validation.json'
    $current  = Join-Path $TestDrive 'current-fixture-validation.json'
    $tempManifest = Join-Path $TestDrive 'fixtures.manifest.json'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures.manifest.json') -Destination $tempManifest -Force

    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken -ManifestPath $tempManifest | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    $orig = Get-Content -LiteralPath $tempManifest -Raw
    try {
      $m = $orig | ConvertFrom-Json
      $dup = $m.items[0] | Select-Object *
      $m.items += $dup
      ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tempManifest -Encoding utf8
      $currRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken -ManifestPath $tempManifest | Out-String)
      $currIdx = $currRaw.IndexOf('{'); $currEnd = $currRaw.LastIndexOf('}')
      $currOut = $currRaw.Substring($currIdx, $currEnd-$currIdx+1)
      Set-Content -LiteralPath $current -Value $currOut -Encoding utf8
    }
    finally {
      $orig | Set-Content -LiteralPath $tempManifest -Encoding utf8 -NoNewline
    }

    $deltaPath = Join-Path $TestDrive 'delta.json'
    pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current > $deltaPath
    pwsh -NoLogo -NoProfile -File $schemaScript -DeltaJsonPath $deltaPath
    $LASTEXITCODE | Should -Be 0
  }
}
