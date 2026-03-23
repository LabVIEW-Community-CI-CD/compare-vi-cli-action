[CmdletBinding()]
param(
  [string]$HandoffPath = (Join-Path (Resolve-Path '.').Path 'AGENT_HANDOFF.txt'),
  [string]$ResultsRoot = (Join-Path (Resolve-Path '.').Path 'tests/results'),
  [int]$MaxLines = 80,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($MaxLines -lt 1) {
  throw 'MaxLines must be greater than zero.'
}

if (-not (Test-Path -LiteralPath $HandoffPath -PathType Leaf)) {
  throw "Handoff file not found: $HandoffPath"
}

$handoffLines = Get-Content -LiteralPath $HandoffPath -ErrorAction Stop
$handoffText = $handoffLines -join "`n"

$requiredHeadings = @(
  '# Agent Handoff',
  '## First Actions',
  '## Live State Surfaces',
  '## Current-State Artifacts',
  '## Working Rules',
  '## When Handoff Looks Wrong'
)

$requiredArtifacts = @(
  '.agent_priority_cache.json',
  'tests/results/_agent/issue/router.json',
  'tests/results/_agent/issue/no-standing-priority.json',
  'tests/results/_agent/verification/docker-review-loop-summary.json',
  'tests/results/_agent/handoff/continuity-summary.json',
  'tests/results/_agent/handoff/entrypoint-status.json',
  'tests/results/_agent/handoff/monitoring-mode.json',
  'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json',
  'tests/results/_agent/handoff/*.json',
  'tests/results/_agent/sessions/*.json'
)

$commandCatalog = [ordered]@{
  bootstrap = 'pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1'
  standingPriority = 'pwsh -NoLogo -NoProfile -File tools/Get-StandingPriority.ps1 -Plain'
  printHandoff = 'pwsh -NoLogo -NoProfile -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim'
  projectPortfolio = 'node tools/npm/run-script.mjs priority:project:portfolio:check'
  developSync = 'node tools/npm/run-script.mjs priority:develop:sync'
  monitoringMode = 'node tools/npm/run-script.mjs priority:monitoring:mode'
  governorSummary = 'node tools/npm/run-script.mjs priority:governor:summary'
  governorPortfolio = 'node tools/npm/run-script.mjs priority:governor:portfolio'
}

$artifactCatalog = [ordered]@{
  priorityCache = '.agent_priority_cache.json'
  router = 'tests/results/_agent/issue/router.json'
  noStandingPriority = 'tests/results/_agent/issue/no-standing-priority.json'
  dockerReviewLoopSummary = 'tests/results/_agent/verification/docker-review-loop-summary.json'
  continuitySummary = 'tests/results/_agent/handoff/continuity-summary.json'
  entrypointStatus = 'tests/results/_agent/handoff/entrypoint-status.json'
  monitoringMode = 'tests/results/_agent/handoff/monitoring-mode.json'
  autonomousGovernorSummary = 'tests/results/_agent/handoff/autonomous-governor-summary.json'
  autonomousGovernorPortfolioSummary = 'tests/results/_agent/handoff/autonomous-governor-portfolio-summary.json'
  handoffGlob = 'tests/results/_agent/handoff/*.json'
  sessionGlob = 'tests/results/_agent/sessions/*.json'
}

$violations = [System.Collections.Generic.List[string]]::new()
$missingHeadings = @($requiredHeadings | Where-Object { $handoffLines -notcontains $_ })
$missingArtifacts = @($requiredArtifacts | Where-Object { $handoffText -notmatch [regex]::Escape($_) })

$hasPrimaryHeading = $handoffLines.Count -gt 0 -and [string]::Equals($handoffLines[0], '# Agent Handoff', [System.StringComparison]::Ordinal)
$withinLineBudget = $handoffLines.Count -le $MaxLines
$hasStableEntrypointGuidance = $handoffText -match 'stable handoff entrypoint'
$hasNoStatusLogGuidance = $handoffText -match 'not a running\s+status log'
$hasMachineGeneratedGuidance = $handoffText -match 'machine-generated artifacts'
$hasDatedHistorySections = [regex]::IsMatch($handoffText, '(?m)^## 20\d{2}-\d{2}-\d{2}$')

if (-not $hasPrimaryHeading) {
  $violations.Add("Expected first line to be '# Agent Handoff'.")
}

if (-not $withinLineBudget) {
  $violations.Add(("Expected AGENT_HANDOFF.txt to stay within {0} lines, found {1}." -f $MaxLines, $handoffLines.Count))
}

if ($missingHeadings.Count -gt 0) {
  $violations.Add(("Missing required headings: {0}" -f ($missingHeadings -join ', ')))
}

if ($missingArtifacts.Count -gt 0) {
  $violations.Add(("Missing live artifact references: {0}" -f ($missingArtifacts -join ', ')))
}

if (-not $hasStableEntrypointGuidance) {
  $violations.Add('Expected stable handoff entrypoint guidance.')
}

if (-not $hasNoStatusLogGuidance) {
  $violations.Add('Expected guidance that AGENT_HANDOFF.txt is not a running status log.')
}

if (-not $hasMachineGeneratedGuidance) {
  $violations.Add('Expected guidance that live state belongs in machine-generated artifacts.')
}

if ($hasDatedHistorySections) {
  $violations.Add('Found dated historical section headings; AGENT_HANDOFF.txt must stay evergreen.')
}

$status = if ($violations.Count -gt 0) { 'fail' } else { 'pass' }
$result = [ordered]@{
  schema = 'agent-handoff/entrypoint-status-v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  handoffPath = $HandoffPath
  maxLines = $MaxLines
  actualLineCount = $handoffLines.Count
  status = $status
  checks = [ordered]@{
    primaryHeading = $hasPrimaryHeading
    lineBudget = $withinLineBudget
    requiredHeadings = ($missingHeadings.Count -eq 0)
    liveArtifactGuidance = ($missingArtifacts.Count -eq 0)
    stableEntrypointGuidance = $hasStableEntrypointGuidance
    noStatusLogGuidance = $hasNoStatusLogGuidance
    machineGeneratedArtifactGuidance = $hasMachineGeneratedGuidance
    noDatedHistorySections = (-not $hasDatedHistorySections)
  }
  commands = $commandCatalog
  artifacts = $artifactCatalog
  violations = @($violations)
}

$handoffDir = Join-Path $ResultsRoot '_agent/handoff'
New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
$statusPath = Join-Path $handoffDir 'entrypoint-status.json'
($result | ConvertTo-Json -Depth 6) | Out-File -FilePath $statusPath -Encoding utf8

if (-not $Quiet) {
  Write-Host ("[handoff-entrypoint] status={0} lines={1}/{2} -> {3}" -f $status, $handoffLines.Count, $MaxLines, $statusPath)
}
if ($violations.Count -gt 0) {
  if (-not $Quiet) {
    foreach ($violation in $violations) {
      Write-Host ("[handoff-entrypoint] violation: {0}" -f $violation) -ForegroundColor Red
    }
  }
  throw 'AGENT_HANDOFF.txt failed the entrypoint contract.'
}

if (-not $Quiet) {
  Write-Output $statusPath
}
