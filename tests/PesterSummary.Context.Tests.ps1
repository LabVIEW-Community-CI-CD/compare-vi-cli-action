Describe 'Pester Summary Context Emission' {
  It 'emits environment/run/selection when -EmitContext specified' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    # Mini test suite
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null
    Set-Content -LiteralPath (Join-Path $testsDir 'Mini.Tests.ps1') -Value "Describe 'Mini' { It 'passes' { 1 | Should -Be 1 } }" -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitContext | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'environment') | Should -BeTrue
      ($json.PSObject.Properties.Name -contains 'run') | Should -BeTrue
      ($json.PSObject.Properties.Name -contains 'selection') | Should -BeTrue

      $json.environment.osPlatform | Should -Not -BeNullOrEmpty
      $json.environment.psVersion | Should -Match '^[0-9]'
      $json.run.wallClockSeconds | Should -BeGreaterThan 0
      $json.selection.totalDiscoveredFileCount | Should -BeGreaterThan 0
      $json.selection.selectedTestFileCount | Should -BeGreaterThan 0
      $json.selection.maxTestFilesApplied | Should -BeFalse
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
