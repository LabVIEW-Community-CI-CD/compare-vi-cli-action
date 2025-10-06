Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Fixture validation delta script' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path
    $script:validator = Join-Path $repoRoot 'tools' 'Validate-Fixtures.ps1'
    $script:diffScript = Join-Path $repoRoot 'tools' 'Diff-FixtureValidationJson.ps1'
    # Use a temp manifest to avoid mutating repository files
    $script:manifestPath = Join-Path $TestDrive 'fixtures.manifest.json'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'fixtures.manifest.json') -Destination $script:manifestPath -Force
    $script:baselineJson = Join-Path $TestDrive 'baseline-fixture-validation.json'
    $script:currentJson  = Join-Path $TestDrive 'current-fixture-validation.json'
    $script:originalManifest = Get-Content -LiteralPath $manifestPath -Raw

    function Write-Manifest($jsonRaw) {
      $jsonRaw | Set-Content -LiteralPath $script:manifestPath -Encoding utf8 -NoNewline
    }

  function Convert-JsonOutputSegment([string]$raw) {
      if (-not $raw) { throw 'Empty JSON output captured' }
      $start = $raw.IndexOf('{')
      $end = $raw.LastIndexOf('}')
      if ($start -lt 0 -or $end -lt 0 -or $end -le $start) { throw 'Could not locate JSON object braces' }
      return $raw.Substring($start, ($end - $start + 1))
    }

    # Produce baseline (no structural issues) -> record exact bytes to avoid size mismatches
    $m = $originalManifest | ConvertFrom-Json
    foreach ($it in $m.items) { $it.bytes = (Get-Item -LiteralPath (Join-Path $repoRoot $it.path)).Length }
    Write-Manifest ($m | ConvertTo-Json -Depth 5)
  $baseRaw = (pwsh -NoLogo -NoProfile -File $script:validator -Json -DisableToken -TestAllowFixtureUpdate -ManifestPath $script:manifestPath | Out-String)
  $baseOut = Convert-JsonOutputSegment $baseRaw
  Set-Content -LiteralPath $baselineJson -Value $baseOut -Encoding utf8
    $parsedBase = $null
    for ($r=0; $r -lt 2 -and -not $parsedBase; $r++) {
      try { $parsedBase = Get-Content -LiteralPath $baselineJson -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Start-Sleep -Milliseconds 60 }
    }
    if (-not $parsedBase.ok) { throw 'Baseline validation unexpectedly not ok (expected clean baseline)' }

    # Produce current with duplicate structural issue
    $m2 = $originalManifest | ConvertFrom-Json
    foreach ($it in $m2.items) { $it.bytes = (Get-Item -LiteralPath (Join-Path $repoRoot $it.path)).Length }
    $dup = $m2.items[0] | Select-Object *
    $m2.items += $dup
    Write-Manifest ($m2 | ConvertTo-Json -Depth 5)
  $currRaw = (pwsh -NoLogo -NoProfile -File $script:validator -Json -DisableToken -TestAllowFixtureUpdate -ManifestPath $script:manifestPath | Out-String)
  $currOut = Convert-JsonOutputSegment $currRaw
  Set-Content -LiteralPath $currentJson -Value $currOut -Encoding utf8
    $parsedCurr = $null
    for ($r=0; $r -lt 2 -and -not $parsedCurr; $r++) {
      try { $parsedCurr = Get-Content -LiteralPath $currentJson -Raw | ConvertFrom-Json -ErrorAction Stop } catch { Start-Sleep -Milliseconds 60 }
    }
    if ($parsedCurr.summaryCounts.duplicate -lt 1) { throw 'Expected duplicate issue not found in current snapshot' }

    # Restore original manifest after snapshots (validator always reads real file, diff script uses snapshots)
    Write-Manifest $originalManifest
  }

  It 'produces a delta JSON and detects new structural issue' {
    # Sanity check snapshots
    (Get-Content -LiteralPath $baselineJson -Raw) | Should -Match '"summaryCounts"'
    (Get-Content -LiteralPath $currentJson -Raw)  | Should -Match '"duplicate"'
  $cmd = "& '$($script:diffScript)' -Baseline '$($baselineJson)' -Current '$($currentJson)'"
  $deltaRaw = pwsh -NoLogo -NoProfile -Command $cmd 2>&1 | Out-String
  Write-Host "[debug-deltaRaw] $deltaRaw"
  $deltaRaw.Trim().StartsWith('{') | Should -BeTrue
    $delta = $deltaRaw | ConvertFrom-Json
    ($delta.newStructuralIssues | Where-Object { $_.category -eq 'duplicate' }).Count | Should -Be 1
    $delta.deltaCounts.duplicate | Should -Be 1
  }

  It 'exits with code 3 when FailOnNewStructuralIssue set' {
  # Use -File invocation so that 'exit 3' propagates correctly
  pwsh -NoLogo -NoProfile -File $script:diffScript -Baseline $baselineJson -Current $currentJson -FailOnNewStructuralIssue 2>&1 | Tee-Object -Variable deltaErr | Out-Null
  if ($LASTEXITCODE -ne 3) { Write-Host "[debug-failOnNewStructuralIssue-output] $deltaErr" }
  $LASTEXITCODE | Should -Be 3
  }
}
