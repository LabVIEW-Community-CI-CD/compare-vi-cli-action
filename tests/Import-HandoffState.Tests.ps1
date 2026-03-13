Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Import-HandoffState' -Tag 'Unit' {
  It 'surfaces the handoff entrypoint index when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $fixturePath = Join-Path $repoRoot 'tools' 'priority' '__fixtures__' 'handoff' 'entrypoint-status.json'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $handoffDir 'entrypoint-status.json') -Force

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Entrypoint index'
    $output | Should -Match 'status\s+: pass'
    $output | Should -Match 'command\.bootstrap'
    $output | Should -Match 'artifact\.entrypointStatus'
    $global:HandoffEntrypointStatus.schema | Should -Be 'agent-handoff/entrypoint-status-v1'

    Remove-Variable -Name HandoffEntrypointStatus -Scope Global -ErrorAction SilentlyContinue
  }

  It 'surfaces the Docker review-loop summary when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $fixturePath = Join-Path $repoRoot 'tools' 'priority' '__fixtures__' 'handoff' 'docker-review-loop-summary.json'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
    Copy-Item -LiteralPath $fixturePath -Destination (Join-Path $handoffDir 'docker-review-loop-summary.json') -Force

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Docker review loop summary'
    $output | Should -Match 'status\s+: passed'
    $output | Should -Match 'head\s+: 433e8aa70326007be74c27ccf54c1ae91559b6f3'
    $global:DockerReviewLoopHandoffSummary.schema | Should -Be 'docker-tools-parity-agent-verification@v1'

    Remove-Variable -Name DockerReviewLoopHandoffSummary -Scope Global -ErrorAction SilentlyContinue
  }
}
