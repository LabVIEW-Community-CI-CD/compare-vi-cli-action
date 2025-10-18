<#
  Verifies aggregation-focused runs do not leave stray artifacts outside the designated results root
  by using dispatcher artifact tracking and inspecting the pester-artifacts-trail.json deltas.
#>

Describe 'Aggregation cleanup (artifact tracking)' -Tag 'Unit' {
  It 'limits created/modified files to the results directory' {
    # Resolve repo root and dispatcher
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir) { throw 'Unable to resolve script directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    # Ephemeral test + results directory
    $tempDir  = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $testsDir = Join-Path $tempDir 'tests'
    $resDir   = Join-Path $tempDir 'results'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $resDir -Force | Out-Null

    # Minimal aggregation-only test (no LVCompare; no external artifacts)
    $miniAgg = @(
      "Describe 'MiniAgg' {",
      '  BeforeAll {',
      "    . (Join-Path (Get-Location).Path 'scripts' 'AggregationHints.Internal.ps1')",
      '  }',
      "  It 'aggregates quickly' {",
      '    $tests = @()',
      '    1..100 | ForEach-Object { $tests += [pscustomobject]@{ Result="Passed"; Path="f$_"; Duration = [TimeSpan]::FromMilliseconds(1) } }',
      '    $null = Get-AggregationHintsBlock -Tests $tests',
      '    $true | Should -BeTrue',
      '  }',
      '}'
    ) -join [Environment]::NewLine
    $miniPath = Join-Path $testsDir 'MiniAgg.Tests.ps1'
    Set-Content -LiteralPath $miniPath -Value $miniAgg -Encoding UTF8

    Push-Location $root
    try {
      $env:DISABLE_STEP_SUMMARY = '1'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -TrackArtifacts -ArtifactGlobs $resDir | Out-Null
      $trail = Join-Path $resDir 'pester-artifacts-trail.json'
      Test-Path $trail | Should -BeTrue -Because 'artifact trail must be emitted when -TrackArtifacts is used'
      $j = Get-Content -LiteralPath $trail -Raw | ConvertFrom-Json
      # No modifications or deletions expected for a new, isolated results root
      ($j.modified | Measure-Object).Count | Should -Be 0
      ($j.deleted  | Measure-Object).Count | Should -Be 0
      # All created paths should be under our results directory
      $prefix = (Resolve-Path -LiteralPath $resDir).Path
      $outside = @($j.created | Where-Object { $_.path -notlike "$prefix*" })
      ($outside | Measure-Object).Count | Should -Be 0 -Because 'created files must be restricted to the run results root'
      # Session index should exist and point to summary JSON
      $sessionIdx = Join-Path $resDir 'session-index.json'
      Test-Path $sessionIdx | Should -BeTrue
      $idx = Get-Content -LiteralPath $sessionIdx -Raw | ConvertFrom-Json
      ($idx.files.PSObject.Properties.Name -contains 'pesterSummaryJson') | Should -BeTrue
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
