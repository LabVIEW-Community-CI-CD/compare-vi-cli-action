Describe 'Pester Summary Timing Detail Emission' {
  It 'emits timing block with extended metrics when -EmitTimingDetail specified' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null

    # Create a few tests with small sleeps to generate varied durations
    $testContent = @(
      "Describe 'Timing' {",
      "  It 'fast' { 1 | Should -Be 1 }",
      "  It 'medium' { Start-Sleep -Milliseconds 30; 1 | Should -Be 1 }",
      "  It 'slow' { Start-Sleep -Milliseconds 60; 1 | Should -Be 1 }",
      "}"
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $testsDir 'Timing.Tests.ps1') -Value $testContent -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitTimingDetail | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'timing') | Should -BeTrue
      $json.timing.count | Should -BeGreaterOrEqual 3
      $json.timing.totalMs | Should -BeGreaterThan 0
      $json.timing.minMs | Should -BeLessOrEqual $json.timing.maxMs
      $json.timing.meanMs | Should -BeGreaterThan 0
      $json.timing.p90Ms | Should -BeGreaterOrEqual $json.timing.p50Ms
      $json.timing.p99Ms | Should -BeGreaterOrEqual $json.timing.p95Ms
      $json.timing.stdDevMs | Should -BeGreaterOrEqual 0
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
