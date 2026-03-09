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
$releaseSummary = Read-HandoffJson -Name 'release-summary.json'
$testSummary = Read-HandoffJson -Name 'test-summary.json'
$entrypointStatus = Read-HandoffJson -Name 'entrypoint-status.json'

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
