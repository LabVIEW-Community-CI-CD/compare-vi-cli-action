#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$HandoffDir = (Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-NullableValue {
  param($Value)
  if ($null -eq $Value) { return 'n/a' }
  if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return 'n/a' }
  return $Value
}

function Format-BoolLabel {
  param([object]$Value)
  if ($Value -eq $true) { return 'true' }
  if ($Value -eq $false) { return 'false' }
  return 'unknown'
}

function Read-HandoffJson {
  param([string]$Name)
  $path = Join-Path $HandoffDir $Name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

if (-not (Test-Path -LiteralPath $HandoffDir -PathType Container)) {
  Write-Host "[handoff] directory not found: $HandoffDir" -ForegroundColor Yellow
  return
}

$issueSummary = Read-HandoffJson -Name 'issue-summary.json'
$issueRouter  = Read-HandoffJson -Name 'issue-router.json'
$hookSummary  = Read-HandoffJson -Name 'hook-summary.json'
$watcherTelemetry = Read-HandoffJson -Name 'watcher-telemetry.json'
$planeTransitionSummary = Read-HandoffJson -Name 'plane-transition.json'
$releaseSummary = Read-HandoffJson -Name 'release-summary.json'
$testSummary = Read-HandoffJson -Name 'test-summary.json'
$dockerReviewLoopSummary = Read-HandoffJson -Name 'docker-review-loop-summary.json'
$entrypointStatus = Read-HandoffJson -Name 'entrypoint-status.json'
$continuitySummary = Read-HandoffJson -Name 'continuity-summary.json'
$operatorSteeringEvent = Read-HandoffJson -Name 'operator-steering-event.json'

if ($issueSummary) {
  Write-Host '[handoff] Standing priority snapshot' -ForegroundColor Cyan
  if (($issueSummary.PSObject.Properties['schema'] -and $issueSummary.schema -eq 'standing-priority/no-standing@v1') -or
      ($issueSummary.PSObject.Properties['reason'] -and $issueSummary.reason -eq 'queue-empty')) {
    Write-Host '  issue    : none (queue empty)'
    Write-Host ("  reason   : {0}" -f ($issueSummary.reason ?? 'queue-empty'))
    Write-Host ("  open     : {0}" -f (Format-NullableValue $issueSummary.openIssueCount))
    Write-Host ("  message  : {0}" -f (Format-NullableValue $issueSummary.message))
  } else {
    Write-Host ("  issue    : #{0}" -f $issueSummary.number)
    Write-Host ("  title    : {0}" -f ($issueSummary.title ?? '(none)'))
    Write-Host ("  state    : {0}" -f ($issueSummary.state ?? 'n/a'))
    Write-Host ("  updated  : {0}" -f ($issueSummary.updatedAt ?? 'n/a'))
    Write-Host ("  digest   : {0}" -f ($issueSummary.digest ?? 'n/a'))
  }
  Set-Variable -Name StandingPrioritySnapshot -Scope Global -Value $issueSummary -Force
}

if ($issueRouter) {
  Write-Host '[handoff] Router actions' -ForegroundColor Cyan
  foreach ($action in ($issueRouter.actions | Sort-Object priority)) {
    Write-Host ("  - {0} (priority {1})" -f $action.key, $action.priority)
  }
  Set-Variable -Name StandingPriorityRouter -Scope Global -Value $issueRouter -Force
}

if ($hookSummary) {
  Write-Host '[handoff] Hook summaries' -ForegroundColor Cyan
  foreach ($entry in $hookSummary | Sort-Object hook) {
    Write-Host ("  {0} : {1} (plane {2})" -f $entry.hook, $entry.status, ($entry.plane ?? 'n/a'))
  }
  Set-Variable -Name HookHandoffSummary -Scope Global -Value $hookSummary -Force
}

if ($watcherTelemetry) {
  Write-Host '[handoff] Watcher telemetry available' -ForegroundColor Cyan
  if ($watcherTelemetry.PSObject.Properties['events'] -and $watcherTelemetry.events) {
    $eventSource = if ($watcherTelemetry.events.PSObject.Properties['source']) { $watcherTelemetry.events.source } else { $null }
    $eventLast = if ($watcherTelemetry.events.PSObject.Properties['lastEventAt']) { $watcherTelemetry.events.lastEventAt } else { $null }
    Write-Host ("  events   : present={0} count={1}" -f (Format-BoolLabel $watcherTelemetry.events.present), (Format-NullableValue $watcherTelemetry.events.count))
    Write-Host ("  path     : {0}" -f (Format-NullableValue $watcherTelemetry.events.path))
    if ($eventSource) {
      Write-Host ("  source   : {0}" -f (Format-NullableValue $eventSource))
    }
    if ($eventLast) {
      Write-Host ("  last     : {0}" -f (Format-NullableValue $eventLast))
    }
  }
  Set-Variable -Name WatcherHandoffTelemetry -Scope Global -Value $watcherTelemetry -Force
}

if ($planeTransitionSummary) {
  Write-Host '[handoff] Plane transition evidence' -ForegroundColor Cyan
  Write-Host ("  status   : {0}" -f (Format-NullableValue $planeTransitionSummary.status))
  Write-Host ("  count    : {0}" -f (Format-NullableValue $planeTransitionSummary.transitionCount))
  if ($planeTransitionSummary.reason) {
    Write-Host ("  reason   : {0}" -f (Format-NullableValue $planeTransitionSummary.reason))
  }
  foreach ($transition in @($planeTransitionSummary.transitions | Select-Object -First 5)) {
    $remoteValue = if ($transition.PSObject.Properties['remote']) { $transition.remote } else { $null }
    $remoteLabel = if ($remoteValue) { " remote=$remoteValue" } else { '' }
    Write-Host ("  - {0}->{1} ({2}) via {3}{4}" -f (Format-NullableValue $transition.from), (Format-NullableValue $transition.to), (Format-NullableValue $transition.action), (Format-NullableValue $transition.via), $remoteLabel)
  }
  Set-Variable -Name PlaneTransitionHandoffSummary -Scope Global -Value $planeTransitionSummary -Force
}

if ($releaseSummary) {
  Write-Host '[handoff] SemVer status' -ForegroundColor Cyan
  Write-Host ("  version : {0}" -f (Format-NullableValue $releaseSummary.version))
  Write-Host ("  valid   : {0}" -f (Format-BoolLabel $releaseSummary.valid))
  if ($releaseSummary.issues) {
    foreach ($issue in $releaseSummary.issues) {
      Write-Host ("    issue : {0}" -f $issue)
    }
  }
  Set-Variable -Name ReleaseHandoffSummary -Scope Global -Value $releaseSummary -Force
}

if ($testSummary) {
  Write-Host '[handoff] Test results' -ForegroundColor Cyan
  $entries = @()
  $statusLabel = 'unknown'
  $total = 0
  $generatedAt = $null
  $notes = @()

  if ($testSummary -is [System.Array]) {
    $entries = @($testSummary)
    $total = $entries.Count
    $statusLabel = if (@($entries | Where-Object { $_.exitCode -ne 0 }).Count -gt 0) { 'failed' } else { 'passed' }
  } elseif ($testSummary -is [psobject]) {
    $resultsProp = $testSummary.PSObject.Properties['results']
    if ($resultsProp) {
      $entries = @($resultsProp.Value)
      $statusProp = $testSummary.PSObject.Properties['status']
      $statusLabel = if ($statusProp) { $statusProp.Value } else { 'unknown' }
      $totalProp = $testSummary.PSObject.Properties['total']
      $total = if ($totalProp) { $totalProp.Value } else { $entries.Count }
      $generatedProp = $testSummary.PSObject.Properties['generatedAt']
      if ($generatedProp) { $generatedAt = $generatedProp.Value }
      $notesProp = $testSummary.PSObject.Properties['notes']
      if ($notesProp -and $notesProp.Value) { $notes = @($notesProp.Value) }
    }
  }

  $failureEntries = @($entries | Where-Object { $_.exitCode -ne 0 })
  $failureCount = $failureEntries.Count
  Write-Host ("  status   : {0}" -f (Format-NullableValue $statusLabel))
  Write-Host ("  total    : {0}" -f $total)
  Write-Host ("  failures : {0}" -f $failureCount)
  if ($generatedAt) {
    Write-Host ("  generated: {0}" -f (Format-NullableValue $generatedAt))
  }
  if ($notes -and $notes.Count -gt 0) {
    foreach ($note in $notes) {
      Write-Host ("  note     : {0}" -f (Format-NullableValue $note))
    }
  }
  foreach ($entry in $entries) {
    Write-Host ("  {0} => exit {1}" -f ($entry.command ?? '(unknown)'), (Format-NullableValue $entry.exitCode))
  }
  Set-Variable -Name TestHandoffSummary -Scope Global -Value $testSummary -Force
}

if ($dockerReviewLoopSummary) {
  Write-Host '[handoff] Docker review loop summary' -ForegroundColor Cyan
  if ($dockerReviewLoopSummary.PSObject.Properties['overall'] -and $dockerReviewLoopSummary.overall) {
    Write-Host ("  status   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.status))
    Write-Host ("  failed   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.failedCheck))
    Write-Host ("  exitCode : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.exitCode))
    if ($dockerReviewLoopSummary.overall.message) {
      Write-Host ("  message  : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.overall.message))
    }
  }
  if ($dockerReviewLoopSummary.PSObject.Properties['git'] -and $dockerReviewLoopSummary.git) {
    Write-Host ("  branch   : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.branch))
    Write-Host ("  head     : {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.headSha))
    Write-Host ("  mergeBase: {0}" -f (Format-NullableValue $dockerReviewLoopSummary.git.upstreamDevelopMergeBase))
    Write-Host ("  dirty    : {0}" -f (Format-BoolLabel $dockerReviewLoopSummary.git.dirtyTracked))
  }
  if ($dockerReviewLoopSummary.PSObject.Properties['requirementsCoverage'] -and $dockerReviewLoopSummary.requirementsCoverage) {
    $coverage = $dockerReviewLoopSummary.requirementsCoverage
    Write-Host ("  reqs     : total={0} covered={1} uncovered={2}" -f (Format-NullableValue $coverage.requirementTotal), (Format-NullableValue $coverage.requirementCovered), (Format-NullableValue $coverage.requirementUncovered))
  }
  Set-Variable -Name DockerReviewLoopHandoffSummary -Scope Global -Value $dockerReviewLoopSummary -Force
}

if ($entrypointStatus) {
  Write-Host '[handoff] Entrypoint index' -ForegroundColor Cyan
  Write-Host ("  status   : {0}" -f (Format-NullableValue $entrypointStatus.status))
  Write-Host ("  lines    : {0}/{1}" -f (Format-NullableValue $entrypointStatus.actualLineCount), (Format-NullableValue $entrypointStatus.maxLines))
  if ($entrypointStatus.PSObject.Properties['commands'] -and $entrypointStatus.commands) {
    foreach ($commandName in @('bootstrap', 'standingPriority', 'printHandoff', 'projectPortfolio', 'developSync')) {
      if ($entrypointStatus.commands.PSObject.Properties[$commandName]) {
        Write-Host ("  command.{0} : {1}" -f $commandName, (Format-NullableValue $entrypointStatus.commands.$commandName))
      }
    }
  }
  if ($entrypointStatus.PSObject.Properties['artifacts'] -and $entrypointStatus.artifacts) {
    foreach ($artifactName in @('priorityCache', 'router', 'noStandingPriority', 'entrypointStatus', 'handoffGlob', 'sessionGlob')) {
      if ($entrypointStatus.artifacts.PSObject.Properties[$artifactName]) {
        Write-Host ("  artifact.{0} : {1}" -f $artifactName, (Format-NullableValue $entrypointStatus.artifacts.$artifactName))
      }
    }
  }
  if ($entrypointStatus.PSObject.Properties['violations'] -and $entrypointStatus.violations) {
    foreach ($violation in @($entrypointStatus.violations)) {
      Write-Host ("  violation: {0}" -f (Format-NullableValue $violation))
    }
  }
  Set-Variable -Name HandoffEntrypointStatus -Scope Global -Value $entrypointStatus -Force
}

if ($continuitySummary) {
  Write-Host '[handoff] Continuity summary' -ForegroundColor Cyan
  Write-Host ("  status   : {0}" -f (Format-NullableValue $continuitySummary.status))
  if ($continuitySummary.PSObject.Properties['issueContext'] -and $continuitySummary.issueContext) {
    Write-Host ("  context  : {0}" -f (Format-NullableValue $continuitySummary.issueContext.mode))
  }
  if ($continuitySummary.PSObject.Properties['continuity'] -and $continuitySummary.continuity) {
    $quiet = $continuitySummary.continuity.quietPeriod
    if ($quiet) {
      Write-Host ("  quiet    : {0}" -f (Format-NullableValue $quiet.status))
      Write-Host ("  gap      : {0}s" -f (Format-NullableValue $quiet.silenceGapSeconds))
      Write-Host ("  pause    : {0}" -f (Format-BoolLabel $quiet.operatorQuietPeriodTreatedAsPause))
    }
    if ($continuitySummary.continuity.PSObject.Properties['turnBoundary'] -and $continuitySummary.continuity.turnBoundary) {
      Write-Host ("  boundary : {0}" -f (Format-NullableValue $continuitySummary.continuity.turnBoundary.status))
      Write-Host ("  boundary-gap : {0}" -f (Format-BoolLabel $continuitySummary.continuity.turnBoundary.operatorTurnEndWouldCreateIdleGap))
    }
    Write-Host ("  signals  : {0}" -f (Format-NullableValue $continuitySummary.continuity.unattendedSignalCount))
    Write-Host ("  action   : {0}" -f (Format-NullableValue $continuitySummary.continuity.recommendation))
  }
  Set-Variable -Name HandoffContinuitySummary -Scope Global -Value $continuitySummary -Force
}

if ($operatorSteeringEvent) {
  Write-Host '[handoff] Operator steering event' -ForegroundColor Cyan
  Write-Host ("  steering : {0}" -f (Format-NullableValue $operatorSteeringEvent.steeringKind))
  Write-Host ("  trigger  : {0}" -f (Format-NullableValue $operatorSteeringEvent.triggerKind))
  if ($operatorSteeringEvent.PSObject.Properties['issueContext'] -and $operatorSteeringEvent.issueContext) {
    Write-Host ("  issue    : {0}" -f (Format-NullableValue $operatorSteeringEvent.issueContext.issue))
  }
  if ($operatorSteeringEvent.PSObject.Properties['fundingWindow'] -and $operatorSteeringEvent.fundingWindow) {
    Write-Host ("  funding  : {0}" -f (Format-NullableValue $operatorSteeringEvent.fundingWindow.invoiceTurnId))
  }
  Set-Variable -Name HandoffOperatorSteeringEvent -Scope Global -Value $operatorSteeringEvent -Force
}
