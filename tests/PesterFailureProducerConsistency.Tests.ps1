Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pester failure producer consistency' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:dispatcherPath = Join-Path $script:repoRoot 'Invoke-PesterTests.ps1'
  }

  It 'dispatcher emits canonical failure detail when a test fails' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-failure-producer-" + [Guid]::NewGuid().ToString('N'))
    $testsDir = Join-Path $tempRoot 'tests'
    $resultsDir = Join-Path $tempRoot 'results'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      @'
Describe "Producer consistency sample" {
  It "fails intentionally" {
    1 | Should -Be 2
  }
}
'@ | Set-Content -LiteralPath (Join-Path $testsDir 'ProducerConsistency.Sample.Tests.ps1') -Encoding UTF8

      $dispatcherError = $null
      try {
        & $script:dispatcherPath `
          -TestsPath $testsDir `
          -ResultsPath $resultsDir `
          -JsonSummaryPath 'pester-summary.json' `
          -ExecutionPack full `
          -IntegrationMode exclude `
          -IncludePatterns 'ProducerConsistency.Sample.Tests.ps1' `
          -EmitFailuresJsonAlways | Out-Null
      } catch {
        $dispatcherError = $_
      }

      $dispatcherError | Should -Not -BeNullOrEmpty
      $dispatcherError.Exception.Message | Should -Match 'Test execution completed with failures'

      $summary = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Raw | ConvertFrom-Json
      $failures = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Raw | ConvertFrom-Json

      ($summary.failed + $summary.errors) | Should -BeGreaterThan 0
      $summary.failureDetailsStatus | Should -Be 'available'
      $summary.failureDetailsCount | Should -BeGreaterThan 0
      $failures.schema | Should -Be 'pester-failures@v2'
      $failures.schemaVersion | Should -Be '1.1.0'
      $failures.detailStatus | Should -Be 'available'
      $failures.detailCount | Should -BeGreaterThan 0
      @($failures.results).Count | Should -BeGreaterThan 0
      $failures.results[0].result | Should -Be 'Failed'
      $failures.results[0].name | Should -Match 'fails intentionally'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
