Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Agent Handoff Docker parity verification' -Tag 'Unit' {
  It 'mirrors the authoritative Docker review-loop summary into the handoff bundle' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $workspaceRoot 'tools'
    $priorityDir = Join-Path $toolsDir 'priority'
    $scriptPath = Join-Path $toolsDir 'Print-AgentHandoff.ps1'
    $entrypointPath = Join-Path $toolsDir 'Test-AgentHandoffEntryPoint.ps1'
    $issueDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'issue'
    $verificationDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'verification'
    $cachePath = Join-Path $workspaceRoot '.agent_priority_cache.json'
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $toolsDir, $priorityDir, $issueDir, $verificationDir, $resultsRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1') -Destination $scriptPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Test-AgentHandoffEntryPoint.ps1') -Destination $entrypointPath -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot 'AGENT_HANDOFF.txt') -Destination (Join-Path $workspaceRoot 'AGENT_HANDOFF.txt') -Force

    [pscustomobject][ordered]@{
      schema = 'standing-priority/issue@v1'
      number = 1053
      title = 'Docker Desktop local-first review loop'
      state = 'OPEN'
      updatedAt = '2026-03-13T15:10:00Z'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
      labels = @('standing-priority', 'ci')
      assignees = @()
      milestone = $null
      commentCount = 0
      bodyDigest = 'body-digest-1053'
      digest = 'digest-1053'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir '1053.json') -Encoding utf8

    [pscustomobject][ordered]@{
      schema = 'agent/priority-router@v1'
      issue = [pscustomobject][ordered]@{
        number = 1053
        title = 'Docker Desktop local-first review loop'
      }
      updatedAt = '2026-03-13T15:10:00Z'
      actions = @()
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'router.json') -Encoding utf8

    [pscustomobject][ordered]@{
      number = 1053
      title = 'Docker Desktop local-first review loop'
      url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1053'
      cachedAtUtc = '2026-03-13T15:10:00Z'
      repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
      state = 'OPEN'
      labels = @('standing-priority', 'ci')
      assignees = @()
      milestone = $null
      commentCount = 0
      lastSeenUpdatedAt = '2026-03-13T15:10:00Z'
      issueDigest = 'digest-1053'
      bodyDigest = 'body-digest-1053'
      lastFetchSource = 'fixture'
      lastFetchError = $null
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding utf8

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'priority' '__fixtures__' 'handoff' 'docker-review-loop-summary.json') -Destination (Join-Path $verificationDir 'docker-review-loop-summary.json') -Force

    Push-Location $workspaceRoot
    try {
      { & $scriptPath -ApplyToggles -ResultsRoot $resultsRoot } | Should -Not -Throw
    } finally {
      Pop-Location
    }

    $handoffSummaryPath = Join-Path $resultsRoot '_agent' 'handoff' 'docker-review-loop-summary.json'
    Test-Path -LiteralPath $handoffSummaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $handoffSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $summary.schema | Should -Be 'docker-tools-parity-agent-verification@v1'
    $summary.authoritativeSource | Should -Be 'docker-tools-parity'
    $summary.git.headSha | Should -Be '433e8aa70326007be74c27ccf54c1ae91559b6f3'
  }
}
