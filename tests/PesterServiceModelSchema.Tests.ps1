Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'PesterServiceModelSchema' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:repoRoot 'tools/PesterServiceModelSchema.ps1')
  }

  It 'accepts the supported execution receipt schema contract' {
    $receiptPath = Join-Path $TestDrive 'pester-run-receipt.json'
    ([ordered]@{
      schema = 'pester-execution-receipt@v1'
      generatedAtUtc = [DateTime]::UtcNow.ToString('o')
      status = 'completed'
    } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $receiptPath -Encoding UTF8

    $state = Test-PesterServiceModelSchemaContract `
      -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $receiptPath -ContractName 'execution-receipt') `
      -ExpectedSchema 'pester-execution-receipt@v1'

    $state.valid | Should -BeTrue
    $state.classification | Should -Be 'ok'
    $state.reason | Should -Be 'execution-receipt-ok'
  }

  It 'rejects an incompatible summary schemaVersion major explicitly' {
    $summaryPath = Join-Path $TestDrive 'pester-summary.json'
    ([ordered]@{
      schemaVersion = '2.0.0'
      total = 1
      passed = 1
      failed = 0
      errors = 0
      skipped = 0
    } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $summaryPath -Encoding UTF8

    $state = Test-PesterServiceModelSchemaContract `
      -DocumentState (Read-PesterServiceModelJsonDocument -PathValue $summaryPath -ContractName 'pester-summary') `
      -ExpectedSchemaVersionMajor 1 `
      -RequireSchemaVersion

    $state.valid | Should -BeFalse
    $state.classification | Should -Be 'unsupported-schema'
    $state.reason | Should -Be 'pester-summary-unsupported-schema-version'
  }
}
