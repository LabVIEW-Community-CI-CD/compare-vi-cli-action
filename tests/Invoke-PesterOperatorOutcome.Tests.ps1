Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterOperatorOutcome' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Invoke-PesterOperatorOutcome.ps1'
  }

  It 'writes a passing operator outcome when classification is ok' {
    $resultsDir = Join-Path $TestDrive 'ok'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    ([ordered]@{
      schema = 'pester-evidence-classification@v1'
      classification = 'ok'
      reasons = @()
      contextStatus = 'ready'
      readinessStatus = 'ready'
      selectionStatus = 'ready'
      rawArtifactDownload = 'staged'
      dispatcherExitCode = 0
      selectionExecutionPack = 'dispatcher'
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Encoding UTF8
    ([ordered]@{
      schemaVersion = '1.7.1'
      total = 3
      passed = 3
      failed = 0
      errors = 0
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

    & $script:toolPath -ResultsDir $resultsDir | Out-Null

    $outcome = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-operator-outcome.json') -Raw | ConvertFrom-Json
    $outcome.gateStatus | Should -Be 'pass'
    $outcome.classification | Should -Be 'ok'
    $outcome.nextActionId | Should -Be 'no-action'
  }

  It 'writes fail-closed operator guidance for unsupported schema' {
    $resultsDir = Join-Path $TestDrive 'unsupported-schema'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    ([ordered]@{
      schema = 'pester-evidence-classification@v1'
      classification = 'unsupported-schema'
      reasons = @('execution-receipt-unsupported-schema')
      contextStatus = 'ready'
      readinessStatus = 'ready'
      selectionStatus = 'ready'
      rawArtifactDownload = 'staged'
      dispatcherExitCode = -1
      selectionExecutionPack = 'dispatcher'
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-evidence-classification.json') -Encoding UTF8
    ([ordered]@{
      schemaVersion = '1.7.1'
      total = 0
      passed = 0
      failed = 0
      errors = 0
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

    & $script:toolPath -ResultsDir $resultsDir -ContinueOnError false | Out-Null

    $outcome = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-operator-outcome.json') -Raw | ConvertFrom-Json
    $outcome.gateStatus | Should -Be 'fail'
    $outcome.classification | Should -Be 'unsupported-schema'
    $outcome.nextActionId | Should -Be 'reconcile-schema-contract'
    $outcome.reasons | Should -Contain 'execution-receipt-unsupported-schema'
  }
}
