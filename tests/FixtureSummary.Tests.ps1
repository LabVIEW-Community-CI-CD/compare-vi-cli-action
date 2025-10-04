Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture summary script' -Tag 'Unit' {
  It 'emits verbose details when SUMMARY_VERBOSE=true' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $summary = Join-Path $repoRoot 'tools' 'Write-FixtureValidationSummary.ps1'
    $baseline = Join-Path $repoRoot 'baseline-fixture-validation.json'
    $current  = Join-Path $repoRoot 'current-fixture-validation.json'

    # Baseline
    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    # Current with duplicate
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
    $orig | Set-Content -LiteralPath $manifestPath -Encoding utf8

    pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current > delta.json
    $env:SUMMARY_VERBOSE = 'true'
    # Pass empty SummaryPath to force stdout output instead of using inherited GITHUB_STEP_SUMMARY
    $out = (pwsh -NoLogo -NoProfile -File $summary -ValidationJson $current -DeltaJson delta.json -SummaryPath '' | Out-String)
    $out | Should -Match '### New Structural Issues Detail'
    $out | Should -Match 'duplicate'
    $out | Should -Match '### All Changes'
  }
}
