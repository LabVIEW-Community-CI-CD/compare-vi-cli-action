param(
  [string]$Group = 'pester-selfhosted',
  [switch]$Html,
  [string]$HtmlPath,
  [switch]$Json,
  [switch]$Quiet,
  [int]$Watch = 0,
  [string]$ResultsRoot,
  [string]$StakeholderPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:toolRoot = Split-Path -Parent $PSCommandPath
$script:repoRoot = Split-Path -Parent $toolRoot
$modulePath = Join-Path $toolRoot 'Dev-Dashboard.psm1'
Import-Module $modulePath -Force

function Invoke-Git {
  param([string[]]$Arguments)
  $git = Get-Command git -ErrorAction SilentlyContinue
  if (-not $git) { return $null }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $git.Source
  foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
  $psi.WorkingDirectory = $script:repoRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  try {
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
      $stdout = $process.StandardOutput.ReadToEnd()
      $process.WaitForExit()
    } finally {
      $process.Dispose()
    }
  } catch {
    return $null
  }
  if ($process.ExitCode -ne 0) { return $null }
  return ($stdout -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -First 1).Trim()
}

function Get-DashboardSnapshot {
  param(
    [string]$GroupName,
    [string]$ResultsDir,
    [string]$StakeholderFile
  )

  $session = Get-SessionLockStatus -Group $GroupName -ResultsRoot $ResultsDir
  $pester = Get-PesterTelemetry -ResultsRoot $ResultsDir
  $agentWait = Get-AgentWaitTelemetry -ResultsRoot $ResultsDir
  $watch = Get-WatchTelemetry -ResultsRoot $ResultsDir
  $stakeholders = Get-StakeholderInfo -Group $GroupName -StakeholderPath $StakeholderFile
  $labviewSnapshotPath = $null
  if ($ResultsDir) {
    $candidateWarmup = Join-Path $ResultsDir '_warmup' 'labview-processes.json'
    if (Test-Path -LiteralPath $candidateWarmup) {
      $labviewSnapshotPath = $candidateWarmup
    } else {
      $candidateFlat = Join-Path $ResultsDir 'labview-processes.json'
      if (Test-Path -LiteralPath $candidateFlat) { $labviewSnapshotPath = $candidateFlat }
    }
  }
  $labview = Get-LabVIEWSnapshot -SnapshotPath $labviewSnapshotPath
  $actions = Get-ActionItems -SessionLock $session -PesterTelemetry $pester -AgentWait $agentWait -Stakeholder $stakeholders -WatchTelemetry $watch -LabVIEWSnapshot $labview

  $branch = Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
  $commit = Invoke-Git -Arguments @('rev-parse', 'HEAD')

  $resolvedResults = $null
  if ($ResultsDir) {
    $resolved = Resolve-Path -LiteralPath $ResultsDir -ErrorAction SilentlyContinue
    if ($resolved) { $resolvedResults = $resolved.ProviderPath }
  }

  return [pscustomobject][ordered]@{
    GeneratedAt      = Get-Date
    Group            = $GroupName
    ResultsRoot      = $resolvedResults
    Branch           = $branch
    Commit           = $commit
    SessionLock      = $session
    PesterTelemetry  = $pester
    AgentWait        = $agentWait
    Stakeholders     = $stakeholders
    WatchTelemetry   = $watch
    LabVIEWSnapshot  = $labview
    ActionItems      = $actions
  }
}

function Format-Seconds {
  param([double]$Seconds)
  if (-not $Seconds -or $Seconds -lt 0) { return $null }
  if ($Seconds -lt 120) { return "$([math]::Round($Seconds,0)) s" }
  $minutes = [math]::Round($Seconds / 60, 1)
  return "$minutes min"
}

function Write-TerminalReport {
  param($Snapshot)

  $timestamp = $Snapshot.GeneratedAt.ToString('u')
  Write-Host "Dev Dashboard — $timestamp"
  Write-Host "Group : $($Snapshot.Group)"
  if ($Snapshot.Branch) { Write-Host "Branch: $($Snapshot.Branch)" }
  if ($Snapshot.Commit) {
    $shortCommit = $Snapshot.Commit.Substring(0, [Math]::Min(7, $Snapshot.Commit.Length))
    Write-Host "Commit: $shortCommit"
  }
  if ($Snapshot.ResultsRoot) { Write-Host "Results: $($Snapshot.ResultsRoot)" }
  Write-Host ''

  $session = $Snapshot.SessionLock
  Write-Host "Session Lock"
  Write-Host "  Status   : $($session.Status)"
  if ($session.SessionName) { Write-Host "  Session  : $($session.SessionName)" }
  if ($session.QueueWaitSeconds -ne $null) {
    Write-Host "  Queue    : $($session.QueueWaitSeconds) s"
  }
  if ($session.HeartbeatAgeSeconds -ne $null) {
    Write-Host "  Heartbeat: $(Format-Seconds -Seconds $session.HeartbeatAgeSeconds)"
  }
  if ($session.LockPath) {
    Write-Host "  File     : $($session.LockPath)"
  }
  $sessionErrors = @($session.Errors)
  if ($sessionErrors.Length -gt 0) {
    foreach ($error in $sessionErrors) {
      Write-Host "  Error    : $error"
    }
  }
  Write-Host ''

  $pester = $Snapshot.PesterTelemetry
  Write-Host "Pester"
  Write-Host "  Total    : $($pester.Totals.Total)"
  Write-Host "  Passed   : $($pester.Totals.Passed)"
  Write-Host "  Failed   : $($pester.Totals.Failed)"
  Write-Host "  Errors   : $($pester.Totals.Errors)"
  if ($pester.Totals.Duration) {
    Write-Host "  Duration : $($pester.Totals.Duration)s"
  }
  $dispatcherErrors = @($pester.DispatcherErrors)
  if ($dispatcherErrors.Length -gt 0) {
    foreach ($msg in $dispatcherErrors) {
      Write-Host "  Error    : $msg"
    }
  }
  $dispatcherWarnings = @($pester.DispatcherWarnings)
  if ($dispatcherWarnings.Length -gt 0) {
    foreach ($msg in $dispatcherWarnings) {
      Write-Host "  Warning  : $msg"
    }
  }
  $failedTests = @($pester.FailedTests)
  if ($failedTests.Length -gt 0) {
    Write-Host "  FailedTests:"
    foreach ($test in $failedTests) {
      Write-Host "    - $($test.Name) ($($test.Result))"
    }
  }
  Write-Host ''

  $wait = $Snapshot.AgentWait
  Write-Host "Agent Wait"
  if ($wait.Exists) {
    Write-Host "  Reason   : $($wait.Reason)"
    if ($wait.DurationSeconds) {
      Write-Host "  Duration : $(Format-Seconds -Seconds $wait.DurationSeconds)"
    }
    if ($wait.StartedAt) { Write-Host "  Started  : $($wait.StartedAt.ToString('u'))" }
    if ($wait.CompletedAt) { Write-Host "  Completed: $($wait.CompletedAt.ToString('u'))" }
  } else {
    Write-Host "  Status   : no telemetry"
  }
  $waitErrors = @($wait.Errors)
  if ($waitErrors.Length -gt 0) {
    foreach ($error in $waitErrors) {
      Write-Host "  Error    : $error"
    }
  }
  Write-Host ''

  $watch = $Snapshot.WatchTelemetry
  Write-Host "Watch Mode"
  if ($watch.Last) {
    $cls = $watch.Last.classification
    $st = if ($watch.Last.status) { $watch.Last.status } else { $watch.Last.Status }
    $failed = if ($watch.Last.stats) { $watch.Last.stats.failed } else { $null }
    $tests = if ($watch.Last.stats) { $watch.Last.stats.tests } else { $null }
    Write-Host "  Status   : $st"
    if ($cls) { Write-Host "  Trend    : $cls" }
    if ($tests -ne $null) { Write-Host "  Tests    : $tests (failed=$failed)" }
  } else {
    Write-Host "  Status   : no telemetry"
  }
  if ($watch.Stalled -and $watch.StalledSeconds -gt 0) {
    Write-Host "  Stalled  : $([math]::Round($watch.StalledSeconds,0)) s since last update"
  }
  Write-Host ''

  $labview = $Snapshot.LabVIEWSnapshot
  Write-Host "LabVIEW Snapshot"
  if ($labview.ProcessCount -gt 0) {
    Write-Host "  Count    : $($labview.ProcessCount)"
    $display = @($labview.Processes | Select-Object -First 3)
    foreach ($proc in $display) {
      $startDisplay = $proc.startTimeUtc
      if ($proc.startTimeUtc) {
        try {
          $dt = ConvertTo-DateTime -Value $proc.startTimeUtc
          if ($dt) { $startDisplay = $dt.ToString('u') }
        } catch {}
      }
      $workingSetKb = $null
      if ($proc.workingSetBytes) { $workingSetKb = [math]::Round($proc.workingSetBytes/1kb) }
      $workingSetDisplay = if ($null -eq $workingSetKb) { 'n/a' } else { $workingSetKb }
      $cpuSeconds = if ($proc.totalCpuSeconds -ne $null) { $proc.totalCpuSeconds } else { 'n/a' }
      $startDisplay = if ($startDisplay) { $startDisplay } else { 'n/a' }
      Write-Host ("  PID {0} : WorkingSet={1} KB CPU={2} Started={3}" -f $proc.pid, $workingSetDisplay, $cpuSeconds, $startDisplay)
    }
    if ($labview.ProcessCount -gt $display.Count) {
      Write-Host ("  ... {0} additional process(es) not shown" -f ($labview.ProcessCount - $display.Count))
    }
  } else {
    Write-Host "  Status   : no active LabVIEW processes captured"
  }
  if ($labview.SnapshotPath) {
    Write-Host "  Snapshot : $($labview.SnapshotPath)"
  }
  foreach ($error in @($labview.Errors)) {
    Write-Host "  Error    : $error"
  }
  Write-Host ''

  $stake = $Snapshot.Stakeholders
  Write-Host "Stakeholders"
  if ($stake.Found) {
    Write-Host "  Primary  : $($stake.PrimaryOwner)"
    if ($stake.Backup) { Write-Host "  Backup   : $($stake.Backup)" }
    $channels = @()
    if ($stake.PSObject.Properties.Name -contains 'Channels' -and $stake.Channels) {
      $channels = @($stake.Channels) | Where-Object { $_ -and $_ -ne '' }
    }
    if ($channels.Length -gt 0) {
      Write-Host "  Channels : $([string]::Join(', ', $channels))"
    }
    if ($stake.DxIssue) {
      Write-Host "  DX Issue : #$($stake.DxIssue)"
    }
  } else {
    Write-Host "  Status   : not configured"
  }
  $stakeErrors = @($stake.Errors)
  if ($stakeErrors.Length -gt 0) {
    foreach ($error in $stakeErrors) {
      Write-Host "  Error    : $error"
    }
  }
  Write-Host ''

  Write-Host "Action Items"
  if ($Snapshot.ActionItems.Count -eq 0) {
    Write-Host "  None"
  } else {
    foreach ($item in $Snapshot.ActionItems) {
      Write-Host "  [$($item.Severity.ToUpper())] $($item.Category): $($item.Message)"
    }
  }
}

function ConvertTo-HtmlReport {
  param($Snapshot)

  $encode = { param($value) if ($null -eq $value) { return '' } return [System.Net.WebUtility]::HtmlEncode([string]$value) }
  $session = $Snapshot.SessionLock
  $pester = $Snapshot.PesterTelemetry
  $wait = $Snapshot.AgentWait
  $stake = $Snapshot.Stakeholders
  $watch = $Snapshot.WatchTelemetry
  $labview = $Snapshot.LabVIEWSnapshot
  $items = $Snapshot.ActionItems
  $shortCommit = ''
  if ($Snapshot.Commit) {
    $shortCommit = $Snapshot.Commit.Substring(0, [Math]::Min(7, $Snapshot.Commit.Length))
  }

  $failedTestsHtml = if ($pester.FailedTests.Count -gt 0) {
    $rows = foreach ($test in $pester.FailedTests) {
      "<li>$(& $encode $test.Name) — $(& $encode $test.Result)</li>"
    }
    "<ul>$([string]::Join('', $rows))</ul>"
  } else { '<p>None</p>' }

  $actionItemsHtml = if ($items.Count -gt 0) {
    $rows = foreach ($item in $items) {
      $severity = if ($item.Severity) { $item.Severity.ToLowerInvariant() } else { 'info' }
      $severityClass = 'severity-info'
      switch ($severity) {
        'error' { $severityClass = 'severity-error' }
        'warning' { $severityClass = 'severity-warning' }
        Default { $severityClass = 'severity-info' }
      }
      "<li class=""$severityClass""><strong>$(& $encode $item.Severity)</strong> [$(& $encode $item.Category)] $(& $encode $item.Message)</li>"
    }
    "<ul>$([string]::Join('', $rows))</ul>"
  } else { '<p>None</p>' }

  return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Dev Dashboard</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 2rem; background: #f7f7f7; color: #222; }
    h1 { margin-bottom: 0.5rem; }
    section { background: #fff; padding: 1.5rem; border-radius: 8px; margin-bottom: 1rem; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    dt { font-weight: 600; }
    dd { margin-left: 1rem; margin-bottom: 0.5rem; }
    ul { margin: 0.5rem 0 0 1.5rem; }
    .meta { display: flex; gap: 1.5rem; flex-wrap: wrap; }
    .meta div { font-size: 0.95rem; color: #555; }
    .severity-error { color: #b00020; }
    .severity-warning { color: #d17f00; }
    .severity-info { color: #1967d2; }
    table { width: 100%; border-collapse: collapse; margin-top: 0.5rem; }
    th, td { border: 1px solid #e0e0e0; padding: 0.4rem 0.6rem; text-align: left; font-size: 0.9rem; }
    thead { background: #f0f0f0; }
  </style>
</head>
<body>
  <h1>Dev Dashboard</h1>
  <div class="meta">
    <div><strong>Generated</strong>: $(& $encode ($Snapshot.GeneratedAt.ToString('u')))</div>
    <div><strong>Group</strong>: $(& $encode $Snapshot.Group)</div>
    <div><strong>Branch</strong>: $(& $encode $Snapshot.Branch)</div>
    <div><strong>Commit</strong>: $(& $encode $shortCommit)</div>
  </div>

  <section>
    <h2>Session Lock</h2>
    <dl>
      <dt>Status</dt><dd>$(& $encode $session.Status)</dd>
      @(if ($session.SessionName) { "<dt>Session</dt><dd>$(& $encode $session.SessionName)</dd>" })
      <dt>Queue Wait</dt><dd>$(& $encode ($session.QueueWaitSeconds))</dd>
      <dt>Heartbeat Age</dt><dd>$(& $encode (Format-Seconds -Seconds $session.HeartbeatAgeSeconds))</dd>
      <dt>File</dt><dd>$(& $encode $session.LockPath)</dd>
    </dl>
  </section>

  <section>
    <h2>Pester</h2>
    <dl>
      <dt>Total</dt><dd>$(& $encode $pester.Totals.Total)</dd>
      <dt>Passed</dt><dd>$(& $encode $pester.Totals.Passed)</dd>
      <dt>Failed</dt><dd>$(& $encode $pester.Totals.Failed)</dd>
      <dt>Errors</dt><dd>$(& $encode $pester.Totals.Errors)</dd>
    </dl>
    <h3>Failed Tests</h3>
    $failedTestsHtml
  </section>

  <section>
    <h2>Agent Wait</h2>
    <dl>
      <dt>Reason</dt><dd>$(& $encode $wait.Reason)</dd>
      <dt>Duration</dt><dd>$(& $encode (Format-Seconds -Seconds $wait.DurationSeconds))</dd>
      <dt>Started</dt><dd>$(& $encode ($wait.StartedAt ? $wait.StartedAt.ToString('u') : ''))</dd>
      <dt>Completed</dt><dd>$(& $encode ($wait.CompletedAt ? $wait.CompletedAt.ToString('u') : ''))</dd>
    </dl>
  </section>

  <section>
    <h2>Watch Mode</h2>
    @(if ($watch.Last) {
        "<dl>"
        "<dt>Status</dt><dd>$(& $encode ($watch.Last.status))</dd>"
        "<dt>Trend</dt><dd>$(& $encode ($watch.Last.classification))</dd>"
        "<dt>Tests</dt><dd>$(& $encode ($watch.Last.stats.tests))</dd>"
        "<dt>Failed</dt><dd>$(& $encode ($watch.Last.stats.failed))</dd>"
        "<dt>Updated</dt><dd>$(& $encode ($watch.Last.timestamp))</dd>"
        "</dl>"
      } else {
        '<p>No telemetry</p>'
      })
    @(if ($watch.Stalled -and $watch.StalledSeconds -gt 0) { "<p class='severity-warning'>Stalled: $([math]::Round($watch.StalledSeconds,0)) seconds since last update</p>" })
    @(if ($watch.LogPath) { "<p>Log: $(& $encode $watch.LogPath)</p>" })
  </section>

  <section>
    <h2>LabVIEW Snapshot</h2>
    <dl>
      <dt>Processes</dt><dd>$(& $encode $labview.ProcessCount)</dd>
      <dt>Snapshot</dt><dd>$(& $encode $labview.SnapshotPath)</dd>
    </dl>
    @(if ($labview.ProcessCount -gt 0) {
        $rows = foreach ($proc in ($labview.Processes | Select-Object -First 5)) {
          $workingSet = $proc.workingSetBytes
          $workingSetKb = if ($workingSet) { [math]::Round($workingSet/1kb) } else { $null }
          $cpu = if ($proc.totalCpuSeconds -ne $null) { $proc.totalCpuSeconds } else { '' }
          "<tr><td>$(& $encode $proc.pid)</td><td>$(& $encode $proc.processName)</td><td>$(& $encode $workingSetKb)</td><td>$(& $encode $cpu)</td><td>$(& $encode $proc.startTimeUtc)</td></tr>"
        }
        "<table><thead><tr><th>PID</th><th>Name</th><th>Working Set (KB)</th><th>CPU (s)</th><th>Started (UTC)</th></tr></thead><tbody>$([string]::Join('', $rows))</tbody></table>"
      } else { '<p>No LabVIEW processes recorded.</p>' })
    @(if ($labview.Errors -and $labview.Errors.Count -gt 0) { "<p class='severity-warning'>Errors: $(& $encode ([string]::Join('; ', $labview.Errors)))</p>" })
  </section>

  <section>
    <h2>Stakeholders</h2>
    <dl>
      <dt>Primary</dt><dd>$(& $encode $stake.PrimaryOwner)</dd>
      <dt>Backup</dt><dd>$(& $encode $stake.Backup)</dd>
      <dt>Channels</dt><dd>$(& $encode ([string]::Join(', ', (@($stake.Channels) | Where-Object { $_ -and $_ -ne '' }))))</dd>
      <dt>DX Issue</dt><dd>$(& $encode $stake.DxIssue)</dd>
    </dl>
  </section>

  <section>
    <h2>Action Items</h2>
    $actionItemsHtml
  </section>
</body>
</html>
"@
}

function Invoke-Dashboard {
  param()

  $snapshot = Get-DashboardSnapshot -GroupName $Group -ResultsDir $ResultsRoot -StakeholderFile $StakeholderPath

  if (-not $Quiet) {
    Write-TerminalReport -Snapshot $snapshot
  }

  if ($Html) {
    $target = if ($HtmlPath) { $HtmlPath } else { Join-Path (Join-Path $toolRoot 'dashboard') 'dashboard.html' }
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    ConvertTo-HtmlReport -Snapshot $snapshot | Out-File -FilePath $target -Encoding utf8
  }

  return $snapshot
}

if ($Watch -gt 0) {
  while ($true) {
    if (-not $Quiet) { Clear-Host }
    $snapshot = Invoke-Dashboard
    if ($Json) {
      $snapshot | ConvertTo-Json -Depth 6
    }
    Start-Sleep -Seconds $Watch
  }
} else {
  $snapshot = Invoke-Dashboard
  if ($Json) {
    $snapshot | ConvertTo-Json -Depth 6
  }
}
