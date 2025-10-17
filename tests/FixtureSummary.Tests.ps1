Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture summary script' -Tag 'Unit' {
  It 'emits verbose details when SUMMARY_VERBOSE=true' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $diff = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    $summary = Join-Path $repoRoot 'tools' 'Write-FixtureValidationSummary.ps1'
    $baseline = Join-Path $TestDrive 'baseline-fixture-validation.json'
    $current  = Join-Path $TestDrive 'current-fixture-validation.json'

    # Baseline
    $baseRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
    $baseIdx = $baseRaw.IndexOf('{'); $baseEnd = $baseRaw.LastIndexOf('}')
    $baseOut = $baseRaw.Substring($baseIdx, $baseEnd-$baseIdx+1)
    Set-Content -LiteralPath $baseline -Value $baseOut -Encoding utf8

    # Current with duplicate
    $manifestPath = Join-Path $repoRoot 'fixtures.manifest.json'
    $orig = Get-Content -LiteralPath $manifestPath -Raw
    try {
      $m = $orig | ConvertFrom-Json
      $dup = $m.items[0] | Select-Object *
      $m.items += $dup
      ($m | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $manifestPath -Encoding utf8
      $currRaw = (pwsh -NoLogo -NoProfile -File $validator -Json -DisableToken | Out-String)
      $currIdx = $currRaw.IndexOf('{'); $currEnd = $currRaw.LastIndexOf('}')
      $currOut = $currRaw.Substring($currIdx, $currEnd-$currIdx+1)
      Set-Content -LiteralPath $current -Value $currOut -Encoding utf8
    }
    finally {
      $orig | Set-Content -LiteralPath $manifestPath -Encoding utf8 -NoNewline
    }

    $deltaPath = Join-Path $TestDrive 'delta.json'
    pwsh -NoLogo -NoProfile -File $diff -Baseline $baseline -Current $current > $deltaPath
    $env:SUMMARY_VERBOSE = 'true'
    # Pass empty SummaryPath to force stdout output instead of using inherited GITHUB_STEP_SUMMARY
    $out = (pwsh -NoLogo -NoProfile -File $summary -ValidationJson $current -DeltaJson $deltaPath -SummaryPath '' | Out-String)
    $out | Should -Match '### New Structural Issues Detail'
    $out | Should -Match 'duplicate'
    $out | Should -Match '### All Changes'
  }

  It 'handles missing delta arrays gracefully' {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $summary = Join-Path $repoRoot 'tools' 'Write-FixtureValidationSummary.ps1'

    $validationPath = Join-Path $TestDrive 'validation.json'
    $validation = @{
      ok = $true
      summaryCounts = @{
        missing = 0
        untracked = 0
        tooSmall = 0
        sizeMismatch = 0
        hashMismatch = 0
        manifestError = 0
        duplicate = 0
        schema = 0
      }
    } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $validationPath -Value $validation -Encoding utf8

    $deltaPath = Join-Path $TestDrive 'delta.json'
    # Intentionally omit `newStructuralIssues` and `changes` so the summary materializes them as empty arrays,
    # and leave out `willFail` to confirm it defaults to $false when not present in the delta payload.
    $delta = @{
      schema = 'fixture-validation-delta-v1'
      baselinePath = 'baseline.json'
      currentPath = 'current.json'
      generatedAt = '2025-10-17T00:00:00Z'
      baselineOk = $true
      currentOk = $true
      deltaCounts = @{}
    } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $deltaPath -Value $delta -Encoding utf8

    Remove-Item Env:SUMMARY_VERBOSE -ErrorAction SilentlyContinue
    $out = (pwsh -NoLogo -NoProfile -File $summary -ValidationJson $validationPath -DeltaJson $deltaPath -SummaryPath '' | Out-String)
    $out | Should -Match '\*\*New Structural Issues:\*\* 0'
    $out | Should -Match '\*\*Will Fail:\*\* False'
  }
}
