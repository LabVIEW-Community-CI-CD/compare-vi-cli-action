Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture validation delta schema' -Tag 'Unit' {
  It 'emits JSON matching schema fixture-validation-delta-v1' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $baseline = Join-Path $TestDrive 'baseline-fixture-validation.json'
    $current  = Join-Path $TestDrive 'current-fixture-validation.json'
    # Work on a temp manifest copy
    $tempManifest = Join-Path $TestDrive 'fixtures.manifest.json'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures.manifest.json') -Destination $tempManifest -Force

    # Produce baseline snapshot (ignore token behavior to capture current state)
    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken -ManifestPath $tempManifest | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    # Produce modified current snapshot by duplicating a manifest entry (simulate structural change)
    $originalManifest = Get-Content -LiteralPath $tempManifest -Raw
    try {
      $m = $originalManifest | ConvertFrom-Json
      $dup = $m.items[0] | Select-Object *
      $m.items += $dup
      ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tempManifest -Encoding utf8
      $currRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken -ManifestPath $tempManifest | Out-String)
      $currIdx = $currRaw.IndexOf('{'); $currEnd = $currRaw.LastIndexOf('}')
      $currOut = $currRaw.Substring($currIdx, $currEnd-$currIdx+1)
      Set-Content -LiteralPath $current -Value $currOut -Encoding utf8
    }
    finally {
      $originalManifest | Set-Content -LiteralPath $tempManifest -Encoding utf8 -NoNewline
    }

    $deltaRaw = (pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current | Out-String)
    $delta = $deltaRaw | ConvertFrom-Json
    $delta.schema | Should -Be 'fixture-validation-delta-v1'
    $delta.changes | Should -Not -BeNullOrEmpty
    ($delta.changes | Where-Object { $_.category -eq 'duplicate' }).Count | Should -Be 1
    $delta.newStructuralIssues | Should -Not -BeNullOrEmpty
    $delta.deltaCounts.duplicate | Should -Be 1
  }
}

