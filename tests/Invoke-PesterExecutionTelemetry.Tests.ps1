Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterExecutionTelemetry' {
  BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $toolPath = Join-Path $repoRoot 'tools/Invoke-PesterExecutionTelemetry.ps1'
  }

  It 'materializes a durable telemetry report from dispatcher events and handshake markers' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-telemetry-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'artifacts'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      @(
        '{"schema":"comparevi/runtime-event/v1","tsUtc":"2026-03-31T00:00:00Z","source":"pester-dispatcher","phase":"lifecycle","level":"info","message":"Dispatcher session initialized."}',
        '{"schema":"comparevi/runtime-event/v1","tsUtc":"2026-03-31T00:05:00Z","source":"pester-dispatcher","phase":"dispatch","level":"info","message":"Running pack."}',
        '{"schema":"comparevi/runtime-event/v1","tsUtc":"2026-03-31T00:10:00Z","source":"pester-dispatcher","phase":"postprocess","level":"notice","message":"Summary repair complete."}'
      ) | Set-Content -LiteralPath (Join-Path $resultsDir 'dispatcher-events.ndjson') -Encoding UTF8

      ([ordered]@{
        schema = 'session-index/v1'
        executionPack = 'dispatcher'
        executionPackSource = 'selection-receipt'
        integrationMode = 'exclude'
        integrationSource = 'explicit'
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Encoding UTF8

      ([ordered]@{
        schemaVersion = '1.7.1'
        total = 3
        passed = 3
        failed = 0
      } | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Encoding UTF8

      $handshakeDir = Join-Path $resultsDir 'workflow'
      New-Item -ItemType Directory -Path $handshakeDir -Force | Out-Null
      ([ordered]@{
        name = 'finalize'
        status = 'ok'
        atUtc = '2026-03-31T00:11:00Z'
      } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $handshakeDir 'handshake-finalize.json') -Encoding UTF8

      & $toolPath -ResultsDir $resultsDir | Out-Host
      $LASTEXITCODE | Should -Be 0

      $reportPath = Join-Path $resultsDir 'pester-execution-telemetry.json'
      Test-Path -LiteralPath $reportPath | Should -BeTrue

      $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
      $report.schema | Should -Be 'pester-execution-telemetry@v1'
      $report.telemetryStatus | Should -Be 'telemetry-available'
      $report.executionPack | Should -Be 'dispatcher'
      $report.integrationMode | Should -Be 'exclude'
      $report.eventCount | Should -Be 3
      $report.lastKnownPhase | Should -Be 'finalize'
      $report.lastKnownPhaseSource | Should -Be 'handshake'
      $report.handshake.count | Should -Be 1
      $report.handshake.lastStatus | Should -Be 'ok'
      (@($report.phases | ForEach-Object { $_.phase })) | Should -Contain 'dispatch'
      $report.lastEvent.phase | Should -Be 'postprocess'
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }

  It 'writes a missing telemetry report when dispatcher events are absent' {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-telemetry-empty-" + [Guid]::NewGuid().ToString('N'))
    $resultsDir = Join-Path $tempRoot 'artifacts'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

    try {
      & $toolPath -ResultsDir $resultsDir | Out-Host
      $LASTEXITCODE | Should -Be 0

      $report = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-execution-telemetry.json') -Raw | ConvertFrom-Json -Depth 20
      $report.telemetryStatus | Should -Be 'telemetry-missing'
      $report.eventCount | Should -Be 0
      $report.lastKnownPhase | Should -BeNullOrEmpty
    } finally {
      if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
}
