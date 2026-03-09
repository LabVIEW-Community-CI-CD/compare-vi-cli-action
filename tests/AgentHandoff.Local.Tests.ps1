Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Local Agent Handoff' -Tag 'Unit' {
  It 'prints AGENT_HANDOFF.txt' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $handoffPath = Join-Path $repoRoot 'AGENT_HANDOFF.txt'
    Test-Path -LiteralPath $handoffPath | Should -BeTrue
    $handoffLines = Get-Content -LiteralPath $handoffPath
    $handoffText = $handoffLines -join "`n"
    $handoffLines.Count | Should -BeLessThan 80
    $handoffText | Should -Match '^# Agent Handoff'
    $handoffText | Should -Match '## First Actions'
    $handoffText | Should -Match '## Live State Surfaces'
    $handoffText | Should -Not -Match '^## 20\d{2}-\d{2}-\d{2}'
    $script = Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1'
    Test-Path -LiteralPath $script | Should -BeTrue
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
    $null = & $script -ApplyToggles -ResultsRoot $resultsRoot
    $env:LV_SUPPRESS_UI | Should -Be '1'
    $env:WATCH_RESULTS_DIR | Should -Match 'tests/results/_watch'
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/entrypoint-status.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-summary.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-router.json') | Should -BeTrue
  }
}
