Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Local Agent Handoff' -Tag 'Unit' {
  It 'prints AGENT_HANDOFF.txt' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $workspaceRoot 'tools'
    $script = Join-Path $toolsDir 'Print-AgentHandoff.ps1'
    $entrypointPath = Join-Path $toolsDir 'Test-AgentHandoffEntryPoint.ps1'
    $watcherManagerPath = Join-Path $toolsDir 'Dev-WatcherManager.ps1'
    $issueDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'issue'
    $cachePath = Join-Path $workspaceRoot '.agent_priority_cache.json'
    New-Item -ItemType Directory -Force -Path $toolsDir, $issueDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1') -Destination $script -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Test-AgentHandoffEntryPoint.ps1') -Destination $entrypointPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Dev-WatcherManager.ps1') -Destination $watcherManagerPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'AGENT_HANDOFF.txt') -Destination (Join-Path $workspaceRoot 'AGENT_HANDOFF.txt') -Force

    [pscustomobject][ordered]@{
      schema = 'standing-priority/issue@v1'
      number = 1909
      title = 'Build Sagan context concentrator for durable subagent memory'
      state = 'OPEN'
      updatedAt = '2026-03-25T07:00:00Z'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
      labels = @('governor', 'standing-priority')
      assignees = @()
      milestone = $null
      commentCount = 0
      bodyDigest = 'body-digest-1909'
      digest = 'digest-1909'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir '1909.json') -Encoding utf8

    [pscustomobject][ordered]@{
      schema = 'agent/priority-router@v1'
      issue = [pscustomobject][ordered]@{
        number = 1909
        title = 'Build Sagan context concentrator for durable subagent memory'
      }
      updatedAt = '2026-03-25T07:00:00Z'
      actions = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'router.json') -Encoding utf8

    [pscustomobject][ordered]@{
      number = 1909
      title = 'Build Sagan context concentrator for durable subagent memory'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
      cachedAtUtc = '2026-03-25T07:00:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      state = 'OPEN'
      labels = @('standing-priority', 'governor')
      assignees = @()
      milestone = $null
      commentCount = 0
      lastSeenUpdatedAt = '2026-03-25T07:00:00Z'
      issueDigest = 'digest-1909'
      bodyDigest = 'body-digest-1909'
      lastFetchSource = 'fixture'
      lastFetchError = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding utf8

    $fixture = [pscustomobject]@{
      WorkspaceRoot = $workspaceRoot
      ScriptPath = $script
    }
    $handoffPath = Join-Path $fixture.WorkspaceRoot 'AGENT_HANDOFF.txt'
    Test-Path -LiteralPath $handoffPath | Should -BeTrue
    $handoffLines = Get-Content -LiteralPath $handoffPath
    $handoffText = $handoffLines -join "`n"
    $handoffLines.Count | Should -BeLessOrEqual 80
    $handoffText | Should -Match '^# Agent Handoff'
    $handoffText | Should -Match '## First Actions'
    $handoffText | Should -Match '## Live State Surfaces'
    $handoffText | Should -Not -Match '^## 20\d{2}-\d{2}-\d{2}'
    $script = $fixture.ScriptPath
    Test-Path -LiteralPath $script | Should -BeTrue
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
    Push-Location $fixture.WorkspaceRoot
    try {
      $null = & $script -ApplyToggles -ResultsRoot $resultsRoot
    } finally {
      Pop-Location
    }
    $env:LV_SUPPRESS_UI | Should -Be '1'
    $env:WATCH_RESULTS_DIR | Should -Match 'tests/results/_watch'
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/entrypoint-status.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-summary.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/issue-router.json') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot '_agent/handoff/plane-transition.json') | Should -BeTrue

    $planeTransition = Get-Content -LiteralPath (Join-Path $resultsRoot '_agent/handoff/plane-transition.json') -Raw | ConvertFrom-Json -ErrorAction Stop
    $planeTransition.schema | Should -Be 'agent-handoff/plane-transition-v1'
    $planeTransition.status | Should -Not -BeNullOrEmpty
  }

  It 'declares governor execution process-model fields in the handoff printer' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script = Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1'
    Test-Path -LiteralPath $script | Should -BeTrue
    $content = Get-Content -LiteralPath $script -Raw
    $content | Should -Match 'execSurf\s*:'
    $content | Should -Match 'executionTopologyRuntimeSurface'
    $content | Should -Match 'execProc\s*:'
    $content | Should -Match 'executionTopologyProcessModelClass'
    $content | Should -Match 'execSim\s*:'
    $content | Should -Match 'executionTopologyRequestedSimultaneous'
    $content | Should -Match 'execCell\s*:'
    $content | Should -Match 'executionTopologyCellClass'
    $content | Should -Match 'execSuite\s*:'
    $content | Should -Match 'executionTopologySuiteClass'
    $content | Should -Match 'execAuth\s*:'
    $content | Should -Match 'executionTopologyOperatorAuthorizationRef'
  }

  It 'ignores provider review receipts when summarizing hook results' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $workspaceRoot 'tools'
    $script = Join-Path $toolsDir 'Print-AgentHandoff.ps1'
    $entrypointPath = Join-Path $toolsDir 'Test-AgentHandoffEntryPoint.ps1'
    $watcherManagerPath = Join-Path $toolsDir 'Dev-WatcherManager.ps1'
    $issueDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'issue'
    $cachePath = Join-Path $workspaceRoot '.agent_priority_cache.json'
    New-Item -ItemType Directory -Force -Path $toolsDir, $issueDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1') -Destination $script -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Test-AgentHandoffEntryPoint.ps1') -Destination $entrypointPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Dev-WatcherManager.ps1') -Destination $watcherManagerPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'AGENT_HANDOFF.txt') -Destination (Join-Path $workspaceRoot 'AGENT_HANDOFF.txt') -Force

    [pscustomobject][ordered]@{
      schema = 'standing-priority/issue@v1'
      number = 1909
      title = 'Build Sagan context concentrator for durable subagent memory'
      state = 'OPEN'
      updatedAt = '2026-03-25T07:00:00Z'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
      labels = @('governor', 'standing-priority')
      assignees = @()
      milestone = $null
      commentCount = 0
      bodyDigest = 'body-digest-1909'
      digest = 'digest-1909'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir '1909.json') -Encoding utf8

    [pscustomobject][ordered]@{
      schema = 'agent/priority-router@v1'
      issue = [pscustomobject][ordered]@{
        number = 1909
        title = 'Build Sagan context concentrator for durable subagent memory'
      }
      updatedAt = '2026-03-25T07:00:00Z'
      actions = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'router.json') -Encoding utf8

    [pscustomobject][ordered]@{
      number = 1909
      title = 'Build Sagan context concentrator for durable subagent memory'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1909'
      cachedAtUtc = '2026-03-25T07:00:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      state = 'OPEN'
      labels = @('standing-priority', 'governor')
      assignees = @()
      milestone = $null
      commentCount = 0
      lastSeenUpdatedAt = '2026-03-25T07:00:00Z'
      issueDigest = 'digest-1909'
      bodyDigest = 'body-digest-1909'
      lastFetchSource = 'fixture'
      lastFetchError = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding utf8

    $fixture = [pscustomobject]@{
      WorkspaceRoot = $workspaceRoot
    }
    Test-Path -LiteralPath $script | Should -BeTrue

    $resultsRoot = Join-Path $TestDrive 'results-with-hooks'
    $hooksDir = Join-Path $resultsRoot '_hooks'
    New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null

    @{
      schema = 'hooks-summary/v1'
      hook = 'pre-commit'
      timestamp = '2026-03-25T05:31:42Z'
      status = 'ok'
      exitCode = 0
      environment = @{
        plane = 'windows-pwsh'
        enforcement = 'warn'
      }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $hooksDir 'pre-commit.json') -Encoding utf8

    @{
      schema = 'priority/agent-review-policy@v1'
      overall = @{
        status = 'failed'
      }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $hooksDir 'pre-commit-agent-review-policy.json') -Encoding utf8

    @{
      schema = 'priority/copilot-cli-review@v1'
      overall = @{
        status = 'failed'
      }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $hooksDir 'pre-commit-copilot-cli-review.json') -Encoding utf8

    Push-Location $fixture.WorkspaceRoot
    try {
      $null = & $script -ApplyToggles -ResultsRoot $resultsRoot
    } finally {
      Pop-Location
    }

    $hookSummaryPath = Join-Path $resultsRoot '_agent/handoff/hook-summary.json'
    Test-Path -LiteralPath $hookSummaryPath | Should -BeTrue
    $hookSummary = @(Get-Content -LiteralPath $hookSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop)
    $hookSummary.Count | Should -Be 1
    $hookSummary[0].hook | Should -Be 'pre-commit'
    $hookSummary[0].status | Should -Be 'ok'
  }
}
