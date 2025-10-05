Describe 'Pester Summary Discovery Detail Emission' {
  It 'emits discovery block with samples when -EmitDiscoveryDetail and discovery failures occur' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null

    # Intentionally malformed test file to trigger discovery failure
    $bad = @(
      "Describe 'Broken' {",
      "  It 'will not parse' {",  # Missing closing braces
      ""
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath (Join-Path $testsDir 'Broken.Tests.ps1') -Value $bad -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitDiscoveryDetail | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'discovery') | Should -BeTrue
      $json.discovery.failureCount | Should -BeGreaterOrEqual 1
      $json.discovery.patterns.Count | Should -BeGreaterOrEqual 1
      $json.discovery.sampleLimit | Should -BeGreaterThan 0
      $json.discovery.samples.Count | Should -BeGreaterOrEqual 1
      $json.discovery.samples[0].snippet | Should -Match 'Discovery in'
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
