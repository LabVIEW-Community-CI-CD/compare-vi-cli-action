Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Local Agent Handoff' -Tag 'Unit' {
  It 'prints AGENT_HANDOFF.txt' {
    Test-Path -LiteralPath (Join-Path (Resolve-Path '..') 'AGENT_HANDOFF.txt') | Should -BeTrue
    $script = Join-Path (Resolve-Path '..') 'tools' 'Print-AgentHandoff.ps1'
    Test-Path -LiteralPath $script | Should -BeTrue
    $out = & $script -ApplyToggles
    $out | Should -Match 'Local Agent Handoff'
    $env:LV_SUPPRESS_UI | Should -Be '1'
    $env:WATCH_RESULTS_DIR | Should -Match 'tests/results/_watch'
  }
}

