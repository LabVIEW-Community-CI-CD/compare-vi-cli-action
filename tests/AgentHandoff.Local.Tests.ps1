Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Local Agent Handoff' -Tag 'Unit' {
  It 'prints AGENT_HANDOFF.txt' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Test-Path -LiteralPath (Join-Path $repoRoot 'AGENT_HANDOFF.txt') | Should -BeTrue
    $script = Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1'
    Test-Path -LiteralPath $script | Should -BeTrue
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
    $null = & $script -ApplyToggles -ResultsRoot $resultsRoot
    $env:LV_SUPPRESS_UI | Should -Be '1'
    $env:WATCH_RESULTS_DIR | Should -Match 'tests/results/_watch'
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-summary.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-router.json') | Should -BeTrue
  }
}
