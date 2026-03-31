Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterExecutionFinalize' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $toolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionFinalize.ps1'
  }

  It 'writes summary, trail, compare-report index, manifest, and session index from the finalize context' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-finalize-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'artifacts'
    $repoResultsDir = Join-Path $tempRoot 'tests/results'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $repoResultsDir -Force | Out-Null

    try {
      @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<test-results name="sample" total="3" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0"></test-results>'
      ) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-results.xml') -Encoding UTF8
      '[]' | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Encoding UTF8
      '{"schema":"pester-leak-report@v1","leakDetected":false}' | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-leak-report.json') -Encoding UTF8
      '{"schema":"pester-result-shapes/v1","schemaVersion":"1.1.0","generatedAt":"2026-03-31T00:00:00Z","totalEntries":3,"overall":{"hasPath":3,"hasTags":2},"byType":[]}' | Set-Content -LiteralPath (Join-Path $resultsDir 'result-shapes.json') -Encoding UTF8
      'shape text' | Set-Content -LiteralPath (Join-Path $resultsDir 'result-shapes.txt') -Encoding UTF8
      '<html><body>compare report</body></html>' | Set-Content -LiteralPath (Join-Path $repoResultsDir 'integration-compare-report.html') -Encoding UTF8

      $contextPath = Join-Path $resultsDir 'pester-execution-finalize-context.json'
      $context = [ordered]@{
        schema                   = 'pester-execution-finalize-context@v1'
        generatedAtUtc           = [DateTime]::UtcNow.ToString('o')
        repoRoot                 = $tempRoot
        resultsDir               = $resultsDir
        jsonSummaryPath          = 'pester-summary.json'
        summaryText              = "=== Pester Test Summary ===`nTotal Tests: 3`nPassed: 3`nFailed: 0`nErrors: 0`nSkipped: 0`nDuration: 1.23s"
        summaryPayload           = [ordered]@{
          total                    = 3
          passed                   = 3
          failed                   = 0
          errors                   = 0
          skipped                  = 0
          duration_s               = 1.23
          timestamp                = '2026-03-31T00:00:00Z'
          schemaVersion            = '1.7.1'
          meanTest_ms              = 10
          p95Test_ms               = 20
          maxTest_ms               = 30
          aggregatorBuildMs        = 4.5
          executionPostprocessStatus = 'complete'
          resultsXmlStatus         = 'complete'
        }
        artifactTrail            = [ordered]@{
          schema      = 'pester-artifact-trail/v1'
          generatedAt = [DateTime]::UtcNow.ToString('o')
          created     = @()
          deleted     = @()
          modified    = @()
          procsBefore = @()
          procsAfter  = @()
        }
        includeIntegration       = $false
        integrationMode          = 'exclude'
        integrationSource        = 'explicit'
        summarySchemaVersion     = '1.7.1'
        manifestVersion          = '1.0.0'
        failuresSchemaVersion    = '1.0.0'
        leakReportSchemaVersion  = '1.0.0'
        diagnosticsSchemaVersion = '1.1.0'
      }
      $context | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $contextPath -Encoding UTF8

      & $toolPath -ContextPath $contextPath | Out-Host
      $LASTEXITCODE | Should -Be 0

      $summaryPath = Join-Path $resultsDir 'pester-summary.txt'
      $summaryJsonPath = Join-Path $resultsDir 'pester-summary.json'
      $trailPath = Join-Path $resultsDir 'pester-artifacts-trail.json'
      $indexPath = Join-Path $resultsDir 'results-index.html'
      $manifestPath = Join-Path $resultsDir 'pester-artifacts.json'
      $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
      $compareReportPath = Join-Path $resultsDir 'compare-report.html'

      Test-Path -LiteralPath $summaryPath | Should -BeTrue
      Test-Path -LiteralPath $summaryJsonPath | Should -BeTrue
      Test-Path -LiteralPath $trailPath | Should -BeTrue
      Test-Path -LiteralPath $compareReportPath | Should -BeTrue
      Test-Path -LiteralPath $indexPath | Should -BeTrue
      Test-Path -LiteralPath $manifestPath | Should -BeTrue
      Test-Path -LiteralPath $sessionIndexPath | Should -BeTrue

      (Get-Content -LiteralPath $summaryPath -Raw) | Should -Match 'Diagnostics Summary'

      $summaryJson = Get-Content -LiteralPath $summaryJsonPath -Raw | ConvertFrom-Json
      $summaryJson.total | Should -Be 3
      $summaryJson.executionPostprocessStatus | Should -Be 'complete'

      $sessionIndex = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json
      $sessionIndex.summary.total | Should -Be 3
      $sessionIndex.files.pesterSummaryJson | Should -Be 'pester-summary.json'
      $sessionIndex.files.compareReportHtml | Should -Be 'compare-report.html'
      $sessionIndex.files.resultsIndexHtml | Should -Be 'results-index.html'

      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
      $artifactFiles = @($manifest.artifacts | ForEach-Object { $_.file })
      $artifactFiles | Should -Contain 'pester-summary.json'
      $artifactFiles | Should -Contain 'pester-artifacts-trail.json'
      $artifactFiles | Should -Contain 'session-index.json'
      $artifactFiles | Should -Contain 'compare-report.html'
      $artifactFiles | Should -Contain 'results-index.html'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
