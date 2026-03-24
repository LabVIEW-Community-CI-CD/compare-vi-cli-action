# Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Local-Runbook topology summary' -Tag 'Unit' {
  It 'auto-stages a runbook report for loop runs and prints loop execution topology' {
    $repoRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $repoRoot 'tools'
    $scriptsDir = Join-Path $repoRoot 'scripts'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..' 'tools' 'Local-Runbook.ps1') -Destination (Join-Path $toolsDir 'Local-Runbook.ps1') -Force

    $stub = @"
param(
  [switch]`$All,
  [string[]]`$Phases,
  [string]`$JsonReport,
  [switch]`$FailOnDiff,
  [switch]`$PassThru
)
if ([string]::IsNullOrWhiteSpace(`$JsonReport)) {
  throw 'Expected JsonReport path'
}
`$payload = [ordered]@{
  schema = 'integration-runbook-v1'
  generated = '2026-03-24T13:00:00Z'
  overallStatus = 'Passed'
  phases = @(
    [ordered]@{
      name = 'Loop'
      status = 'Passed'
      details = [ordered]@{
        executionTopology = [ordered]@{
          runtimeSurface = 'windows-native-teststand'
          processModelClass = 'parallel-process-model'
          executionCellLeaseId = 'lease-hooke-loop-01'
          harnessInstanceLeaseId = 'harness-lease-hooke-loop-01'
          harnessInstanceId = 'ts-hooke-loop-01'
        }
      }
    }
  )
}
(`$payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath `$JsonReport -Encoding UTF8
exit 0
"@
    Set-Content -LiteralPath (Join-Path $scriptsDir 'Invoke-IntegrationRunbook.ps1') -Value $stub -Encoding UTF8

    Push-Location $repoRoot
    try {
      $output = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Local-Runbook.ps1') -Profile loop 2>&1 | Out-String
      $LASTEXITCODE | Should -Be 0
    } finally {
      Pop-Location
    }

    $output | Should -Match 'Loop Execution Topology:'
    $output | Should -Match 'runtimeSurface: windows-native-teststand'
    $output | Should -Match 'processModelClass: parallel-process-model'
    $output | Should -Match 'executionCellLeaseId: lease-hooke-loop-01'
    $output | Should -Match 'harnessInstanceLeaseId: harness-lease-hooke-loop-01'
    $output | Should -Match 'harnessInstanceId: ts-hooke-loop-01'
  }
}
