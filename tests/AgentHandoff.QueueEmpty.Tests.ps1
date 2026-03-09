Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Agent Handoff queue-empty mode' -Tag 'Unit' {
  It 'tolerates a queue-empty cache even when a stale numeric snapshot is still present' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $workspaceRoot = Join-Path $TestDrive 'repo'
    $toolsDir = Join-Path $workspaceRoot 'tools'
    $scriptPath = Join-Path $toolsDir 'Print-AgentHandoff.ps1'
    $issueDir = Join-Path $workspaceRoot 'tests' 'results' '_agent' 'issue'
    $cachePath = Join-Path $workspaceRoot '.agent_priority_cache.json'
    $resultsRoot = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'Print-AgentHandoff.ps1') -Destination $scriptPath -Force

    try {
      New-Item -ItemType Directory -Force -Path $issueDir | Out-Null
      New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
      Set-Content -LiteralPath (Join-Path $workspaceRoot 'AGENT_HANDOFF.txt') -Value @(
        '# Agent Handoff'
        ''
        'Synthetic queue-empty handoff workspace for test coverage.'
      ) -Encoding utf8

      Push-Location $workspaceRoot

      [pscustomobject][ordered]@{
        schema = 'standing-priority/issue@v1'
        number = 911
        title = 'Standing Priority Intake: handle an empty backlog without breaking bootstrap'
        state = 'OPEN'
        updatedAt = '2026-03-08T23:35:13Z'
        url = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/911'
        labels = @('bug', 'standing-priority')
        assignees = @()
        milestone = 'LabVIEW CI Platform v1 (2026Q2)'
        commentCount = 0
        bodyDigest = 'body-digest-911'
        digest = 'digest-911'
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir '911.json') -Encoding utf8

      [pscustomobject][ordered]@{
        schema = 'standing-priority/no-standing@v1'
        generatedAt = '2026-03-08T23:51:50.543Z'
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        labels = @('standing-priority')
        message = 'No open issues remain in LabVIEW-Community-CI-CD/compare-vi-cli-action; the standing-priority queue is empty.'
        reason = 'queue-empty'
        openIssueCount = 0
        failOnMissing = $true
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'no-standing-priority.json') -Encoding utf8

      [pscustomobject][ordered]@{
        schema = 'agent/priority-router@v1'
        issue = $null
        updatedAt = '2026-03-08T23:51:50.541Z'
        actions = @()
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $issueDir 'router.json') -Encoding utf8

      [pscustomobject][ordered]@{
        number = $null
        title = $null
        url = $null
        cachedAtUtc = '2026-03-08T23:51:50.541Z'
        repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
        state = 'NONE'
        labels = @()
        assignees = @()
        milestone = $null
        commentCount = $null
        lastSeenUpdatedAt = $null
        issueDigest = $null
        bodyDigest = $null
        lastFetchSource = 'none'
        lastFetchError = 'No open issues remain in LabVIEW-Community-CI-CD/compare-vi-cli-action; the standing-priority queue is empty.'
        noStandingReason = 'queue-empty'
        noStandingOpenIssueCount = 0
      } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cachePath -Encoding utf8

      { & $scriptPath -ApplyToggles -ResultsRoot $resultsRoot } | Should -Not -Throw

      $handoffDir = Join-Path $resultsRoot '_agent' 'handoff'
      $issueSummaryPath = Join-Path $handoffDir 'issue-summary.json'
      $routerPath = Join-Path $handoffDir 'issue-router.json'
      $sessionPath = Get-ChildItem -LiteralPath (Join-Path $resultsRoot '_agent' 'sessions') -Filter '*.json' | Select-Object -First 1

      Test-Path -LiteralPath $issueSummaryPath | Should -BeTrue
      Test-Path -LiteralPath $routerPath | Should -BeTrue
      $sessionPath | Should -Not -BeNullOrEmpty

      $issueSummary = Get-Content -LiteralPath $issueSummaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
      $issueSummary.schema | Should -Be 'standing-priority/no-standing@v1'
      $issueSummary.reason | Should -Be 'queue-empty'
      $issueSummary.openIssueCount | Should -Be 0

      $router = Get-Content -LiteralPath $routerPath -Raw | ConvertFrom-Json -ErrorAction Stop
      $router.issue | Should -Be $null
      @($router.actions).Count | Should -Be 0

      $session = Get-Content -LiteralPath $sessionPath.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
      $session.standingPriority.mode | Should -Be 'queue-empty'
      $session.standingPriority.reason | Should -Be 'queue-empty'
      $session.standingPriority.openIssueCount | Should -Be 0
    } finally {
      if ((Get-Location).Path -eq $workspaceRoot) {
        Pop-Location
      }
    }
  }
}
