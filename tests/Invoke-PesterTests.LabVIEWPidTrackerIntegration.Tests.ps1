Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterTests LabVIEW PID tracker integration' -Tag 'Unit' {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '_helpers' 'DispatcherTestHelper.psm1') -Force

    $workspace = Join-Path $TestDrive 'pid-tracker-integration'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null

    $dispatcherSource = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-PesterTests.ps1'
    Copy-Item -Path $dispatcherSource -Destination (Join-Path $workspace 'Invoke-PesterTests.ps1') -Force

    $toolsDir = Join-Path $workspace 'tools'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $trackerModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools' 'LabVIEWPidTracker.psm1'
    Copy-Item -Path $trackerModule -Destination (Join-Path $toolsDir 'LabVIEWPidTracker.psm1') -Force

    $testsDir = Join-Path $workspace 'tests'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    @'
Describe "Tracker Smoke" {
  It "passes" { 1 | Should -Be 1 }
}
'@ | Set-Content -LiteralPath (Join-Path $testsDir 'TrackerSmoke.Tests.ps1') -Encoding utf8

    $script:dispatcherPath = Join-Path $workspace 'Invoke-PesterTests.ps1'
    $script:resultsRoot = Join-Path $workspace 'results'

    Push-Location $workspace
    try {
      $script:dispatchResult = Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath -ResultsPath 'results' -TestsPath 'tests' -TimeoutSeconds 40
    } finally {
      Pop-Location
    }

    $script:trackerPath = Join-Path $script:resultsRoot '_agent' 'labview-pid.json'
    $script:manifestPath = Join-Path $script:resultsRoot 'pester-artifacts.json'
  }

  It 'completes dispatcher run successfully' {
    $script:dispatchResult | Should -Not -BeNullOrEmpty
    $script:dispatchResult.ExitCode | Should -Be 0
    $script:dispatchResult.TimedOut | Should -BeFalse
  }

  It 'emits LabVIEW PID tracker file with finalize observation' {
    Test-Path -LiteralPath $script:trackerPath | Should -BeTrue
    $json = Get-Content -LiteralPath $script:trackerPath -Raw | ConvertFrom-Json -Depth 6
    $json.schema | Should -Be 'labview-pid-tracker/v1'
    ($json.observations | Measure-Object).Count | Should -BeGreaterThan 0
    $last = $json.observations | Select-Object -Last 1
    $last.action | Should -Be 'finalize'
  }

  It 'adds LabVIEW PID tracker entry to artifact manifest' {
    Test-Path -LiteralPath $script:manifestPath | Should -BeTrue
    $manifest = Get-Content -LiteralPath $script:manifestPath -Raw | ConvertFrom-Json -Depth 6
    $entries = @($manifest.artifacts | Where-Object { $_.file -eq '_agent/labview-pid.json' })
    $entries | Should -Not -BeNullOrEmpty
    $entries[0].type | Should -Be 'jsonLabVIEWPid'
  }
}
