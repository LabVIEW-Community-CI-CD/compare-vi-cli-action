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

  It 'surfaces plane transition evidence when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'agent-handoff/plane-transition-v1'
      generatedAt = '2026-03-14T08:40:00Z'
      status = 'ok'
      reason = $null
      transitionCount = 1
      transitions = @(
        [ordered]@{
          from = 'upstream'
          to = 'origin'
          action = 'sync'
          via = 'priority:develop:sync'
          sourceType = 'develop-sync'
          sourceLabel = 'develop-sync-report'
        }
      )
      sources = @()
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'plane-transition.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Plane transition evidence'
    $output | Should -Match 'status\s+: ok'
    $output | Should -Match 'upstream->origin'
    $global:PlaneTransitionHandoffSummary.schema | Should -Be 'agent-handoff/plane-transition-v1'

    Remove-Variable -Name PlaneTransitionHandoffSummary -Scope Global -ErrorAction SilentlyContinue
  }
}
