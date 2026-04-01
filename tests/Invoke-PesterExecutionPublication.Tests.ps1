Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterExecutionPublication' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $toolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionPublication.ps1'
  }

  It 'publishes summary, session, metadata, and diagnostics from finalized artifacts' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-publication-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'artifacts'
    $summaryPath = Join-Path $tempRoot 'step-summary.md'
    $contextPath = Join-Path $resultsDir 'pester-execution-finalize-context.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      $env:GITHUB_STEP_SUMMARY = $summaryPath

      ([ordered]@{
        total = 2
        passed = 2
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 1.25
        schemaVersion = '1.7.1'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

      ([ordered]@{
        schema = 'session-index/v1'
        schemaVersion = '1.0.0'
        status = 'ok'
        summary = [ordered]@{
          total = 2
          passed = 2
          failed = 0
          errors = 0
          skipped = 0
          duration_s = 1.25
        }
        stepSummary = @(
          '### Selected Tests',
          '',
          '- Sample.Tests.ps1',
          '',
          '### Configuration',
          '',
          '- IncludeIntegration: False',
          '- Integration Mode: exclude',
          '- Integration Source: explicit',
          '- Discovery: manual-scan'
        ) -join "`n"
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-result-shapes/v1'
        schemaVersion = '1.1.0'
        generatedAt = [DateTime]::UtcNow.ToString('o')
        totalEntries = 2
        overall = [ordered]@{ hasPath = 2; hasTags = 1 }
        byType = @()
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $resultsDir 'result-shapes.json') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-execution-finalize-context@v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        repoRoot = $repoRoot
        resultsDir = $resultsDir
        publication = [ordered]@{
          disableStepSummary = $false
          selectedTests = @('Sample.Tests.ps1')
          discovery = 'manual-scan'
          rerunCommand = 'gh workflow run "Validate" -R repo/name'
        }
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $contextPath -Encoding UTF8

      & $toolPath -ContextPath $contextPath | Out-Host
      $LASTEXITCODE | Should -Be 0

      Test-Path -LiteralPath $summaryPath | Should -BeTrue
      $content = Get-Content -LiteralPath $summaryPath -Raw
      $content | Should -Match '## Pester Test Summary'
      $content | Should -Match '### Session'
      $content | Should -Match '### Selected Tests'
      $content | Should -Match '### Diagnostics Summary'

      $report = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-publication.json') -Raw | ConvertFrom-Json
      $report.summaryWritten | Should -BeTrue
      $report.sessionSummaryWritten | Should -BeTrue
      $report.metadataWritten | Should -BeTrue
    } finally {
      Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
