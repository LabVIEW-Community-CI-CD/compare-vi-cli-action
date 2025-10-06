Describe 'Pester Summary Outcome Classification' {
  It 'emits outcome block with Success classification when all tests pass' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null
    Set-Content -LiteralPath (Join-Path $testsDir 'OutcomePass.Tests.ps1') -Value "Describe 'OutcomePass' { It 'passes' { 1 | Should -Be 1 } }" -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitOutcome | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'outcome') | Should -BeTrue
      $json.outcome.overallStatus | Should -Be 'Success'
      $json.outcome.severityRank | Should -Be 0
      $json.outcome.exitCodeModel | Should -Be 0
      $json.outcome.counts.failed | Should -Be 0
      $json.outcome.flags | Should -Be @()
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
  It 'emits outcome block with Failed classification when a test fails' {
    $scriptDir = $PSScriptRoot; if (-not $scriptDir -and $PSCommandPath) { $scriptDir = Split-Path -Parent $PSCommandPath }
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if (-not $scriptDir) { throw 'Unable to resolve test directory.' }
    $root = Split-Path -Parent $scriptDir
    $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    $testsDir = Join-Path $tempDir 'tests'
    New-Item -ItemType Directory -Path $testsDir | Out-Null
    $failTest = "Describe 'OutcomeFail' { It 'fails' { 1 | Should -Be 2 } }"
    Set-Content -LiteralPath (Join-Path $testsDir 'OutcomeFail.Tests.ps1') -Value $failTest -Encoding UTF8

    Push-Location $root
    try {
      $resDir = Join-Path $tempDir 'results'
      & pwsh -NoLogo -NoProfile -File $dispatcher -TestsPath $testsDir -ResultsPath $resDir -EmitOutcome | Out-Null
      $summaryPath = Join-Path $resDir 'pester-summary.json'
      Test-Path $summaryPath | Should -BeTrue
      $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  $json.schemaVersion | Should -Match '^1\.'
      ($json.PSObject.Properties.Name -contains 'outcome') | Should -BeTrue
      $json.outcome.overallStatus | Should -Be 'Failed'
      $json.outcome.severityRank | Should -Be 2
      $json.outcome.exitCodeModel | Should -Be 1
      $json.outcome.flags | Should -Contain 'TestFailures'
      $json.outcome.counts.failed | Should -Be 1
    } finally {
      Pop-Location
      Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
  }
}
