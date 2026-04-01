Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterEvidenceProvenance' -Tag 'Evidence' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Invoke-PesterEvidenceProvenance.ps1'
  }

  It 'records source raw inputs, receipt identity, derived evidence outputs, and run context for evidence' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-evidence-provenance-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'results'
    $contractDir = Join-Path $tempRoot 'execution-contract'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $contractDir -Force | Out-Null

    $originalRepo = $env:GITHUB_REPOSITORY
    $originalWorkflow = $env:GITHUB_WORKFLOW
    $originalEvent = $env:GITHUB_EVENT_NAME
    $originalRunId = $env:GITHUB_RUN_ID
    $originalRunAttempt = $env:GITHUB_RUN_ATTEMPT
    $originalRef = $env:GITHUB_REF
    $originalRefName = $env:GITHUB_REF_NAME
    $originalSha = $env:GITHUB_SHA
    $originalServerUrl = $env:GITHUB_SERVER_URL

    try {
      $env:GITHUB_REPOSITORY = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      $env:GITHUB_WORKFLOW = 'Pester evidence'
      $env:GITHUB_EVENT_NAME = 'workflow_call'
      $env:GITHUB_RUN_ID = '777'
      $env:GITHUB_RUN_ATTEMPT = '3'
      $env:GITHUB_REF = 'refs/heads/integration/pester-service-model'
      $env:GITHUB_REF_NAME = 'integration/pester-service-model'
      $env:GITHUB_SHA = '0123456789abcdef0123456789abcdef01234567'
      $env:GITHUB_SERVER_URL = 'https://github.com'

      '<?xml version="1.0" encoding="utf-8"?><test-results total="2" failures="0" errors="0"></test-results>' |
        Set-Content -LiteralPath (Join-Path $resultsDir 'pester-results.xml') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-summary/v1'
        schemaVersion = '1.7.1'
        total = 2
        passed = 2
        failed = 0
        errors = 0
        duration_s = 1
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-execution-postprocess@v1'
        schemaVersion = '1.0.0'
        status = 'complete'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-postprocess.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-execution-telemetry@v1'
        schemaVersion = '1.0.0'
        telemetryStatus = 'telemetry-available'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-telemetry.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-evidence-classification@v1'
        classification = 'ok'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-operator-outcome@v1'
        gateStatus = 'pass'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-operator-outcome.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-totals/v1'
        total = 2
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-totals.json') -Encoding UTF8
      ([ordered]@{
        schema = 'session-index/v1'
        entries = @()
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Encoding UTF8
      ([ordered]@{
        schema = 'pester-execution-receipt@v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'completed'
        dispatcherExitCode = 0
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $contractDir 'pester-run-receipt.json') -Encoding UTF8

      & $script:toolPath `
        -ResultsDir $resultsDir `
        -ExecutionReceiptPath (Join-Path $contractDir 'pester-run-receipt.json') `
        -RawArtifactName 'pester-run-raw' `
        -RawArtifactDownload 'success' | Out-Host
      $LASTEXITCODE | Should -Be 0

      $provenance = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-provenance.json') -Raw | ConvertFrom-Json -ErrorAction Stop
      $provenance.schema | Should -Be 'pester-derived-provenance@v1'
      $provenance.provenanceKind | Should -Be 'evidence'
      $provenance.subject.rawArtifactName | Should -Be 'pester-run-raw'
      $provenance.runContext.runId | Should -Be '777'
      ($provenance.sourceInputs | Where-Object role -eq 'summary').present | Should -BeTrue
      ($provenance.sourceInputs | Where-Object role -eq 'execution-receipt').schema | Should -Be 'pester-execution-receipt@v1'
      ($provenance.derivedOutputs | Where-Object role -eq 'classification').schema | Should -Be 'pester-evidence-classification@v1'
      ($provenance.derivedOutputs | Where-Object role -eq 'operator-outcome').schema | Should -Be 'pester-operator-outcome@v1'
    } finally {
      $env:GITHUB_REPOSITORY = $originalRepo
      $env:GITHUB_WORKFLOW = $originalWorkflow
      $env:GITHUB_EVENT_NAME = $originalEvent
      $env:GITHUB_RUN_ID = $originalRunId
      $env:GITHUB_RUN_ATTEMPT = $originalRunAttempt
      $env:GITHUB_REF = $originalRef
      $env:GITHUB_REF_NAME = $originalRefName
      $env:GITHUB_SHA = $originalSha
      $env:GITHUB_SERVER_URL = $originalServerUrl
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
