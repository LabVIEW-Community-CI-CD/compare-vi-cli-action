Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Replay-PesterServiceModelArtifacts.Local' -Tag 'Execution' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Replay-PesterServiceModelArtifacts.Local.ps1'
  }

  It 'rebuilds postprocess, summary, totals, session index, and evidence from retained artifacts' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-replay-local-" + [Guid]::NewGuid().ToString('N'))
    $rawArtifactDir = Join-Path $tempRoot 'raw-artifact'
    $workspaceDir = Join-Path $tempRoot 'workspace-results'
    $receiptPath = Join-Path $tempRoot 'pester-run-receipt.json'
    New-Item -ItemType Directory -Path $rawArtifactDir -Force | Out-Null

    try {
      @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<test-results name="sample" total="2" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0"></test-results>'
      ) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $rawArtifactDir 'pester-results.xml') -Encoding UTF8
      @(
        '{"schema":"comparevi/runtime-event/v1","tsUtc":"2026-03-31T00:00:00Z","source":"pester-dispatcher","phase":"lifecycle","level":"info","message":"Dispatcher session initialized."}',
        '{"schema":"comparevi/runtime-event/v1","tsUtc":"2026-03-31T00:03:00Z","source":"pester-dispatcher","phase":"dispatch","level":"info","message":"Pack execution complete."}'
      ) | Set-Content -LiteralPath (Join-Path $rawArtifactDir 'dispatcher-events.ndjson') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-failures@v2'
        schemaVersion = '1.1.0'
        detailStatus = 'not-applicable'
        detailCount = 0
        summary = [ordered]@{ total = 2; failed = 0; errors = 0; skipped = 0 }
        results = @()
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $rawArtifactDir 'pester-failures.json') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-execution-receipt@v1'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        contextStatus = 'ready'
        readinessStatus = 'ready'
        selectionStatus = 'ready'
        selectionExecutionPack = 'dispatcher'
        selectionExecutionPackSource = 'declared'
        dispatcherExitCode = 0
        executionJobResult = 'success'
        status = 'completed'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

      & $script:toolPath -RawArtifactDir $rawArtifactDir -ExecutionReceiptPath $receiptPath -WorkspaceResultsDir $workspaceDir | Out-Host
      $LASTEXITCODE | Should -Be 0

      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-execution-postprocess.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-summary.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-totals.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-execution-telemetry.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'session-index.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-evidence-classification.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-operator-outcome.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-evidence-provenance.json') -PathType Leaf | Should -BeTrue
      Test-Path -LiteralPath (Join-Path $workspaceDir 'pester-local-replay-receipt.json') -PathType Leaf | Should -BeTrue

      $classification = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
      $classification.classification | Should -Be 'ok'
      $operatorOutcome = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-operator-outcome.json') -Raw | ConvertFrom-Json
      $operatorOutcome.gateStatus | Should -Be 'pass'
      $operatorOutcome.classification | Should -Be 'ok'
      $provenance = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-evidence-provenance.json') -Raw | ConvertFrom-Json
      $provenance.provenanceKind | Should -Be 'local-replay'
      ($provenance.sourceInputs | Where-Object role -eq 'source-raw-artifacts').fileCount | Should -Be 3

      $replayReceipt = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-local-replay-receipt.json') -Raw | ConvertFrom-Json
      $replayReceipt.classification | Should -Be 'ok'
      $replayReceipt.operatorOutcomePresent | Should -BeTrue
      $replayReceipt.operatorOutcomeGateStatus | Should -Be 'pass'
      $replayReceipt.provenancePresent | Should -BeTrue
      $replayReceipt.provenanceKind | Should -Be 'local-replay'
      $replayReceipt.telemetryPresent | Should -BeTrue
      $replayReceipt.telemetryStatus | Should -Be 'telemetry-available'
      $replayReceipt.telemetryEventCount | Should -Be 2
      $replayReceipt.telemetryLastKnownPhase | Should -Be 'dispatch'
      $replayReceipt.workspaceResultsDir | Should -Be ([System.IO.Path]::GetFullPath($workspaceDir))
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'fails closed with unsupported-schema when the retained execution receipt is incompatible' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-replay-local-" + [Guid]::NewGuid().ToString('N'))
    $rawArtifactDir = Join-Path $tempRoot 'raw-artifact'
    $workspaceDir = Join-Path $tempRoot 'workspace-results'
    $receiptPath = Join-Path $tempRoot 'pester-run-receipt.json'
    New-Item -ItemType Directory -Path $rawArtifactDir -Force | Out-Null

    try {
      @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<test-results name="sample" total="1" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0"></test-results>'
      ) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $rawArtifactDir 'pester-results.xml') -Encoding UTF8

      ([ordered]@{
        schema = 'pester-execution-receipt@v2'
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'completed'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

      & $script:toolPath -RawArtifactDir $rawArtifactDir -ExecutionReceiptPath $receiptPath -WorkspaceResultsDir $workspaceDir -SkipSessionIndex | Out-Host
      $LASTEXITCODE | Should -Be 0

      $classification = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
      $classification.classification | Should -Be 'unsupported-schema'
      $operatorOutcome = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-operator-outcome.json') -Raw | ConvertFrom-Json
      $operatorOutcome.gateStatus | Should -Be 'fail'
      $operatorOutcome.nextActionId | Should -Be 'reconcile-schema-contract'

      $replayReceipt = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-local-replay-receipt.json') -Raw | ConvertFrom-Json
      $replayReceipt.classification | Should -Be 'unsupported-schema'
      $replayReceipt.operatorOutcomePresent | Should -BeTrue
      $replayReceipt.operatorOutcomeGateStatus | Should -Be 'fail'
      $replayReceipt.provenancePresent | Should -BeTrue
      $replayReceipt.provenanceKind | Should -Be 'local-replay'
      $replayReceipt.stagedExecutionReceiptSchemaStatus | Should -Be 'unsupported-schema'
      $replayReceipt.stagedExecutionReceiptSchemaReason | Should -Be 'execution-receipt-unsupported-schema'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
