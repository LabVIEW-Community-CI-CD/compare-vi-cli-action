Describe 'Pester Summary Stability Emission' {
  It 'emits stability block with placeholder values when -EmitStability specified' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null

    $content = "Describe 'FlakyScaffold' { It 'passes' { 1 | Should -Be 1 } }"
    Set-Content -LiteralPath (Join-Path $testsDir 'Flaky.Tests.ps1') -Value $content -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitStability | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json

  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'stability') | Should -BeTrue
      $json.stability.supportsRetries | Should -BeFalse
      $json.stability.retryAttempts | Should -Be 0
      $json.stability.initialFailed | Should -BeGreaterOrEqual 0
      $json.stability.finalFailed | Should -BeGreaterOrEqual 0
      $json.stability.recovered | Should -BeFalse
      $json.stability.flakySuspects.Count | Should -Be 0
      $json.stability.retriedTestFiles.Count | Should -Be 0
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
