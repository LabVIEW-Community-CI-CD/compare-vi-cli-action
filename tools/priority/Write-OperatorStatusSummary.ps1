#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Group = 'pester-selfhosted',
  [string]$ResultsRoot = (Join-Path (Resolve-Path '.').Path 'tests/results'),
  [string]$DashboardRoot = (Join-Path (Resolve-Path '.').Path 'tests/results/dev-dashboard'),
  [string]$OutputPath = (Join-Path (Resolve-Path '.').Path 'tests/results/_agent/operator-status.md')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invokeDashboard = Join-Path (Resolve-Path '.').Path 'tools/Invoke-DevDashboard.ps1'
if (-not (Test-Path -LiteralPath $invokeDashboard -PathType Leaf)) {
  throw "Invoke-DevDashboard.ps1 not found at $invokeDashboard"
}

if (-not (Test-Path -LiteralPath $DashboardRoot -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $DashboardRoot | Out-Null
}

pwsh -NoLogo -NoProfile -File $invokeDashboard -Group $Group -ResultsRoot $ResultsRoot -OutputRoot $DashboardRoot -JsonOnly | Out-Null
$jsonPath = Join-Path $DashboardRoot 'dashboard.json'
if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
  throw "dashboard.json not found at $jsonPath"
}

$dashboard = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -ErrorAction Stop

$branch = if ($dashboard.PSObject.Properties.Name -contains 'Branch') { $dashboard.Branch } else { 'unknown' }
$commit = if ($dashboard.PSObject.Properties.Name -contains 'Commit') { $dashboard.Commit } else { 'unknown' }
if ($commit -and $commit.Length -gt 8) { $commit = $commit.Substring(0, 8) }

$sessionLock = if ($dashboard.PSObject.Properties.Name -contains 'SessionLock') { $dashboard.SessionLock } else { $null }
$pester = if ($dashboard.PSObject.Properties.Name -contains 'PesterTelemetry') { $dashboard.PesterTelemetry } else { $null }
$watch = if ($dashboard.PSObject.Properties.Name -contains 'WatchTelemetry') { $dashboard.WatchTelemetry } else { $null }
$actions = if ($dashboard.PSObject.Properties.Name -contains 'ActionItems') { @($dashboard.ActionItems) } else { @() }

$laneState = if ($sessionLock -and ($sessionLock.PSObject.Properties.Name -contains 'Status')) { $sessionLock.Status } else { 'unknown' }
$sessionStatus = if ($pester -and ($pester.PSObject.Properties.Name -contains 'SessionStatus')) { $pester.SessionStatus } else { 'unknown' }
$blockers = @($actions | Where-Object { ($_.PSObject.Properties.Name -contains 'Severity') -and ("$($_.Severity)" -match '^(high|critical)$') })
if ($blockers.Count -eq 0) {
  $blockers = @($actions | Select-Object -First 3)
}

$totals = if ($pester -and ($pester.PSObject.Properties.Name -contains 'Totals')) { $pester.Totals } else { $null }
$total = if ($totals -and ($totals.PSObject.Properties.Name -contains 'Total')) { $totals.Total } else { 0 }
$passed = if ($totals -and ($totals.PSObject.Properties.Name -contains 'Passed')) { $totals.Passed } else { 0 }
$failed = if ($totals -and ($totals.PSObject.Properties.Name -contains 'Failed')) { $totals.Failed } else { 0 }
$errors = if ($totals -and ($totals.PSObject.Properties.Name -contains 'Errors')) { $totals.Errors } else { 0 }

$queueWait = if ($sessionLock -and ($sessionLock.PSObject.Properties.Name -contains 'QueueWaitSeconds')) { $sessionLock.QueueWaitSeconds } else { $null }
$heartbeatAge = if ($sessionLock -and ($sessionLock.PSObject.Properties.Name -contains 'HeartbeatAgeSeconds')) { $sessionLock.HeartbeatAgeSeconds } else { $null }

$trend = @(
  "pester_total=$total",
  "pester_passed=$passed",
  "pester_failed=$failed",
  "pester_errors=$errors"
)
if ($queueWait -ne $null) { $trend += "queue_wait_seconds=$queueWait" }
if ($heartbeatAge -ne $null) { $trend += "heartbeat_age_seconds=$heartbeatAge" }
if ($watch -and ($watch.PSObject.Properties.Name -contains 'State')) { $trend += "watch_state=$($watch.State)" }

$exceptionUsage = @()
if ($actions.Count -gt 0) {
  $exceptionUsage = @($actions | Where-Object {
      ($_.PSObject.Properties.Name -contains 'Category') -and ("$($_.Category)" -match '(override|exception|bypass|admin)')
    })
}

$lines = @()
$lines += "# Operator Status Summary"
$lines += ""
$lines += "- GeneratedAtUtc: $([DateTime]::UtcNow.ToString('o'))"
$lines += "- Group: $Group"
$lines += "- Branch: $branch"
$lines += "- Commit: $commit"
$lines += "- LaneState: $laneState"
$lines += "- SessionStatus: $sessionStatus"
$lines += ""
$lines += "## Blockers"
if ($blockers.Count -eq 0) {
  $lines += "- none"
} else {
  foreach ($item in $blockers) {
    $msg = if ($item.PSObject.Properties.Name -contains 'Message') { $item.Message } else { "$item" }
    $sev = if ($item.PSObject.Properties.Name -contains 'Severity') { $item.Severity } else { 'info' }
    $lines += "- [$sev] $msg"
  }
}
$lines += ""
$lines += "## Trend Metrics"
foreach ($entry in $trend) { $lines += "- $entry" }
$lines += ""
$lines += "## Exception Usage"
if ($exceptionUsage.Count -eq 0) {
  $lines += "- none"
} else {
  foreach ($item in $exceptionUsage) {
    $msg = if ($item.PSObject.Properties.Name -contains 'Message') { $item.Message } else { "$item" }
    $lines += "- $msg"
  }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$lines -join "`n" | Out-File -LiteralPath $OutputPath -Encoding utf8
Write-Host "Operator status summary written: $OutputPath"
