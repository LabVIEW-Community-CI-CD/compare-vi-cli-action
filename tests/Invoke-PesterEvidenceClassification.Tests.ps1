Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterEvidenceClassification' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Invoke-PesterEvidenceClassification.ps1'
  }

  It 'classifies retained passing evidence as ok' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-evidence-classification-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'results'
    $receiptPath = Join-Path $tempRoot 'pester-run-receipt.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      ([ordered]@{
        schemaVersion = '1.7.1'
        total = 3
        passed = 3
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 0.42
        resultsXmlStatus = 'complete'
      } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-execution-receipt@v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        contextStatus = 'ready'
        readinessStatus = 'ready'
        selectionStatus = 'ready'
        selectionExecutionPack = 'dispatcher'
        selectionExecutionPackSource = 'declared'
        dispatcherExitCode = 0
        executionJobResult = 'success'
        status = 'completed'
      } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

      & $script:toolPath -ResultsDir $resultsDir -ExecutionReceiptPath $receiptPath -RawArtifactDownload staged | Out-Host
      $LASTEXITCODE | Should -Be 0

      $classification = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
      $classification.classification | Should -Be 'ok'
      $classification.selectionExecutionPack | Should -Be 'dispatcher'
      $classification.rawArtifactDownload | Should -Be 'staged'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'classifies an incompatible execution receipt schema as unsupported-schema instead of throwing' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-evidence-classification-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'results'
    $receiptPath = Join-Path $tempRoot 'pester-run-receipt.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      ([ordered]@{
        schema = 'pester-execution-receipt@v2'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'completed'
      } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

      & $script:toolPath -ResultsDir $resultsDir -ExecutionReceiptPath $receiptPath -RawArtifactDownload staged | Out-Host
      $LASTEXITCODE | Should -Be 0

      $classification = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
      $classification.classification | Should -Be 'unsupported-schema'
      $classification.executionReceiptSchemaStatus | Should -Be 'unsupported-schema'
      $classification.reasons | Should -Contain 'execution-receipt-unsupported-schema'
      $classification.reasons | Should -Contain 'execution-receipt-schema=pester-execution-receipt@v2'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'classifies a legacy execution receipt without selectionExecutionPack fields without throwing' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-evidence-classification-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'results'
    $receiptPath = Join-Path $tempRoot 'pester-run-receipt.json'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      ([ordered]@{
        schemaVersion = '1.7.1'
        total = 4
        passed = 2
        failed = 1
        errors = 0
        skipped = 1
        resultsXmlStatus = 'truncated-root'
      } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-execution-receipt@v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        contextStatus = 'ready'
        readinessStatus = 'ready'
        selectionStatus = 'ready'
        dispatcherExitCode = -1
        executionJobResult = 'success'
        status = 'results-xml-truncated'
      } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

      & $script:toolPath -ResultsDir $resultsDir -ExecutionReceiptPath $receiptPath -RawArtifactDownload staged | Out-Host
      $LASTEXITCODE | Should -Be 0

      $classification = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
      $classification.classification | Should -Be 'results-xml-truncated'
      $classification.selectionExecutionPack | Should -Be ''
      $classification.selectionExecutionPackSource | Should -Be ''
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
