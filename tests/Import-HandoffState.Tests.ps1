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

  It 'surfaces turn-boundary continuity supervision when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'priority/continuity-telemetry-report@v1'
      generatedAt = '2026-03-21T20:00:00Z'
      repoRoot = 'C:\repo'
      status = 'maintained'
      issueContext = [ordered]@{
        mode = 'issue'
        issue = 1711
        present = $true
        fresh = $true
        observedAt = '2026-03-21T19:58:00Z'
        reason = $null
      }
      continuity = [ordered]@{
        status = 'maintained'
        preservedWithoutPrompt = $true
        promptDependency = 'low'
        unattendedSignalCount = 4
        quietPeriod = [ordered]@{
          status = 'covered'
          continuityReferenceAt = '2026-03-21T19:59:00Z'
          silenceGapSeconds = 60
          operatorQuietPeriodTreatedAsPause = $false
        }
        turnBoundary = [ordered]@{
          status = 'active-work-pending'
          supervisionState = 'supervised-background'
          operatorTurnEndWouldCreateIdleGap = $false
          operatorPromptRequiredToResume = $false
          activeLaneIssue = 1711
          wakeCondition = 'github-checks-finished'
          source = 'delivery-state'
          reason = 'standing issue #1711 is supervised in the background'
          pendingActions = @('Resume when wake condition ''github-checks-finished'' is satisfied for standing issue #1711.')
        }
        recommendation = 'Resume when wake condition ''github-checks-finished'' is satisfied for standing issue #1711.'
      }
      sources = [ordered]@{
        writerLease = [ordered]@{ path = 'writer.json'; exists = $true; observedAt = '2026-03-21T19:59:00Z'; ageSeconds = 60; freshnessThresholdSeconds = 1800; fresh = $true; error = $null }
        router = [ordered]@{ path = 'router.json'; exists = $true; observedAt = '2026-03-21T19:58:00Z'; ageSeconds = 120; freshnessThresholdSeconds = 21600; fresh = $true; error = $null }
        noStanding = [ordered]@{ path = 'no-standing.json'; exists = $false; observedAt = $null; ageSeconds = $null; freshnessThresholdSeconds = 21600; fresh = $false; error = $null }
        handoffEntrypoint = [ordered]@{ path = 'entrypoint-status.json'; exists = $true; observedAt = '2026-03-21T19:57:00Z'; ageSeconds = 180; freshnessThresholdSeconds = 86400; fresh = $true; error = $null }
        sessions = [ordered]@{ path = 'sessions'; exists = $true; observedAt = '2026-03-21T19:56:00Z'; ageSeconds = 240; freshnessThresholdSeconds = 604800; fresh = $true; count = 1; latestPath = 'session.json' }
        deliveryState = [ordered]@{ path = 'delivery-agent-state.json'; exists = $true; observedAt = '2026-03-21T19:55:00Z'; ageSeconds = 300; freshnessThresholdSeconds = 21600; fresh = $true; error = $null }
        observerHeartbeat = [ordered]@{ path = 'observer-heartbeat.json'; exists = $false; observedAt = $null; ageSeconds = $null; freshnessThresholdSeconds = 21600; fresh = $false; error = $null }
      }
      artifacts = [ordered]@{
        runtimePath = 'tests/results/_agent/runtime/continuity-telemetry.json'
        handoffPath = 'tests/results/_agent/handoff/continuity-summary.json'
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'continuity-summary.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Continuity summary'
    $output | Should -Match 'supervision\s+: supervised-background'
    $output | Should -Match 'prompt-resume\s+: false'
    $output | Should -Match 'pending\s+: Resume when wake condition'
    $global:HandoffContinuitySummary.schema | Should -Be 'priority/continuity-telemetry-report@v1'

    Remove-Variable -Name HandoffContinuitySummary -Scope Global -ErrorAction SilentlyContinue
  }
  It 'surfaces monitoring-mode state when present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'Import-HandoffState.ps1'
    $handoffDir = Join-Path $TestDrive 'handoff'
    New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

    [ordered]@{
      schema = 'agent-handoff/monitoring-mode-v1'
      generatedAt = '2026-03-22T13:00:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      policy = [ordered]@{
        path = 'tools/policy/template-monitoring.json'
        compareRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        pivotTargetRepository = 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
        wakeConditions = @('compare-queue-not-empty')
      }
      compare = [ordered]@{
        queueState = [ordered]@{ reportPath = 'tests/results/_agent/issue/no-standing-priority.json'; ready = $true; status = 'queue-empty'; detail = 'queue-empty' }
        continuity = [ordered]@{ reportPath = 'tests/results/_agent/handoff/continuity-summary.json'; ready = $true; status = 'maintained'; detail = 'safe-idle' }
        pivotGate = [ordered]@{ reportPath = 'tests/results/_agent/promotion/template-pivot-gate-report.json'; ready = $true; status = 'ready'; detail = 'future-agent-may-pivot' }
        readyForMonitoring = $true
      }
      templateMonitoring = [ordered]@{
        status = 'pass'
        repositories = @()
        unsupportedPaths = @()
      }
      wakeConditions = @()
      summary = [ordered]@{
        status = 'active'
        futureAgentAction = 'future-agent-may-pivot'
        wakeConditionCount = 0
        triggeredWakeConditions = @()
      }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $handoffDir 'monitoring-mode.json') -Encoding utf8

    $output = & $scriptPath -HandoffDir $handoffDir *>&1 | Out-String

    $output | Should -Match '\[handoff\] Monitoring mode'
    $output | Should -Match 'action\s+: future-agent-may-pivot'
    $output | Should -Match 'template\s+: pass'
    $global:HandoffMonitoringMode.schema | Should -Be 'agent-handoff/monitoring-mode-v1'

    Remove-Variable -Name HandoffMonitoringMode -Scope Global -ErrorAction SilentlyContinue
  }
}
