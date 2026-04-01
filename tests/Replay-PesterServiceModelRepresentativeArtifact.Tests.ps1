Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Representative retained-artifact replay' -Tag 'Execution' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Replay-PesterServiceModelArtifacts.Local.ps1'
    $script:fixtureRoot = Join-Path $script:repoRoot 'tests/fixtures/pester-service-model/legacy-results-xml-truncated'
  }

  It 'replays a schema-lite truncated-XML run without throwing and preserves the real evidence classification' {
    $workspaceDir = Join-Path $TestDrive 'workspace-results'
    $rawArtifactDir = Join-Path $script:fixtureRoot 'raw'
    $receiptPath = Join-Path $script:fixtureRoot 'pester-run-receipt.json'

    & $script:toolPath -RawArtifactDir $rawArtifactDir -ExecutionReceiptPath $receiptPath -WorkspaceResultsDir $workspaceDir | Out-Host
    $LASTEXITCODE | Should -Be 0

    $classification = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-evidence-classification.json') -Raw | ConvertFrom-Json
    $classification.classification | Should -Be 'results-xml-truncated'
    $classification.selectionExecutionPack | Should -Be ''
    $classification.summarySchemaStatus | Should -Be 'ok'

    $operatorOutcome = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-operator-outcome.json') -Raw | ConvertFrom-Json
    $operatorOutcome.gateStatus | Should -Be 'fail'
    $operatorOutcome.nextActionId | Should -Be 'inspect-results-xml-truncation'

    $summary = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-summary.json') -Raw | ConvertFrom-Json
    $summary.schemaVersion | Should -Be '1.7.1'
    $summary.executionPostprocessStatus | Should -Be 'results-xml-truncated'
    $summary.resultsXmlStatus | Should -Be 'truncated-root'

    $replayReceipt = Get-Content -LiteralPath (Join-Path $workspaceDir 'pester-local-replay-receipt.json') -Raw | ConvertFrom-Json
    $replayReceipt.classification | Should -Be 'results-xml-truncated'
    $replayReceipt.operatorOutcomePresent | Should -BeTrue
    $replayReceipt.operatorOutcomeGateStatus | Should -Be 'fail'
    $replayReceipt.stagedExecutionReceiptSchemaStatus | Should -Be 'ok'
  }
}
