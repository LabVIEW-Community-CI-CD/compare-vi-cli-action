#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Agent Handoff plane transition evidence' -Tag 'Unit' {
  It 'mirrors develop-sync plane transition evidence into the handoff bundle and session capsule' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $workspaceRoot 'tools'
    $priorityDir = Join-Path $toolsDir 'priority'
    $scriptPath = Join-Path $toolsDir 'Print-AgentHandoff.ps1'
    $entrypointPath = Join-Path $toolsDir 'Test-AgentHandoffEntryPoint.ps1'
    $watcherManagerPath = Join-Path $toolsDir 'Dev-WatcherManager.ps1'
    $issueDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'issue'
    $cachePath = Join-Path $workspaceRoot '.agent_priority_cache.json'
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $toolsDir, $priorityDir, $issueDir, $resultsRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1') -Destination $scriptPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Test-AgentHandoffEntryPoint.ps1') -Destination $entrypointPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Dev-WatcherManager.ps1') -Destination $watcherManagerPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'AGENT_HANDOFF.txt') -Destination (Join-Path $workspaceRoot 'AGENT_HANDOFF.txt') -Force

    [pscustomobject][ordered]@{
      schema = 'standing-priority/issue@v1'
      number = 1127
      title = 'Record fork-plane transitions in session-index and handoff evidence'
      state = 'OPEN'
      updatedAt = '2026-03-14T08:40:00Z'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1127'
      labels = @('ci', 'enhancement')
      assignees = @()
      milestone = $null
      commentCount = 0
      bodyDigest = 'body-digest-1127'
      digest = 'digest-1127'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir '1127.json') -Encoding utf8

    [pscustomobject][ordered]@{
      schema = 'agent/priority-router@v1'
      issue = [pscustomobject][ordered]@{
        number = 1127
        title = 'Record fork-plane transitions in session-index and handoff evidence'
      }
      updatedAt = '2026-03-14T08:40:00Z'
      actions = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'router.json') -Encoding utf8

    [pscustomobject][ordered]@{
      number = 1127
      title = 'Record fork-plane transitions in session-index and handoff evidence'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1127'
      cachedAtUtc = '2026-03-14T08:40:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      state = 'OPEN'
      labels = @('standing-priority', 'ci')
      assignees = @()
      milestone = $null
      commentCount = 0
      lastSeenUpdatedAt = '2026-03-14T08:40:00Z'
      issueDigest = 'digest-1127'
      bodyDigest = 'body-digest-1127'
      lastFetchSource = 'fixture'
      lastFetchError = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding utf8

    [pscustomobject][ordered]@{
      schema = 'priority/develop-sync-report@v1'
      generatedAt = '2026-03-14T08:40:00Z'
      actions = @(
        [pscustomobject][ordered]@{
          remote = 'origin'
          planeTransition = [pscustomobject][ordered]@{
            from = 'upstream'
            to = 'origin'
            action = 'sync'
            via = 'priority:develop:sync'
            baseRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
            headRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
          }
        }
      )
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $issueDir 'develop-sync-report.json') -Encoding utf8

    Push-Location $workspaceRoot
    try {
      { & $scriptPath -ApplyToggles -ResultsRoot $resultsRoot } | Should -Not -Throw
    } finally {
      Pop-Location
    }

    $handoffPlanePath = Join-Path $resultsRoot '_agent' 'handoff' 'plane-transition.json'
    Test-Path -LiteralPath $handoffPlanePath | Should -BeTrue
    $handoffPlane = Get-Content -LiteralPath $handoffPlanePath -Raw | ConvertFrom-Json -ErrorAction Stop
    $handoffPlane.status | Should -Be 'ok'
    $handoffPlane.transitionCount | Should -Be 1
    $handoffPlane.transitions[0].from | Should -Be 'upstream'
    $handoffPlane.transitions[0].to | Should -Be 'origin'
    $handoffPlane.transitions[0].remote | Should -Be 'origin'

    $watcherPath = Join-Path $resultsRoot '_agent' 'handoff' 'watcher-telemetry.json'
    $watcher = Get-Content -LiteralPath $watcherPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $watcher.planeTransitions.status | Should -Be 'ok'
    $watcher.planeTransitions.transitionCount | Should -Be 1

    $sessionPath = Get-ChildItem -LiteralPath (Join-Path $resultsRoot '_agent' 'sessions') -Filter '*.json' | Select-Object -First 1
    $sessionPath | Should -Not -BeNullOrEmpty
    $session = Get-Content -LiteralPath $sessionPath.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
    $session.planeTransitions.status | Should -Be 'ok'
    $session.planeTransitions.transitionCount | Should -Be 1
  }
}
