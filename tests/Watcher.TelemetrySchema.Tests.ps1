Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Watcher Telemetry - Handoff Snapshot' {
  It 'emits a watcher-telemetry.json with required fields' {
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null

    pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -ResultsRoot $resultsRoot | Out-Null

    $path = Join-Path $resultsRoot '_agent/handoff/watcher-telemetry.json'
    Test-Path -LiteralPath $path | Should -BeTrue

    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop
    $json | Should -Not -BeNullOrEmpty
    $json.schema | Should -Be 'agent-handoff/watcher-telemetry-v1'
    $json.state | Should -Not -BeNullOrEmpty
    $json.alive | Should -BeOfType ([bool])
    $json.verifiedProcess | Should -BeOfType ([bool])
    $json.heartbeatFresh | Should -BeOfType ([bool])
    $json.needsTrim | Should -BeOfType ([bool])
  }
}

