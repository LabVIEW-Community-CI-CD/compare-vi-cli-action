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

if ($issueSummary) {
  Write-Host '[handoff] Standing priority snapshot' -ForegroundColor Cyan
  Write-Host ("  issue    : #{0}" -f $issueSummary.number)
  Write-Host ("  title    : {0}" -f ($issueSummary.title ?? '(none)'))
  Write-Host ("  state    : {0}" -f ($issueSummary.state ?? 'n/a'))
  Write-Host ("  updated  : {0}" -f ($issueSummary.updatedAt ?? 'n/a'))
  Write-Host ("  digest   : {0}" -f ($issueSummary.digest ?? 'n/a'))
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
