param(
  [Parameter()][string]$ResultsDir = 'tests/results',
  [Parameter()][string]$LogFile = 'pester-dispatcher.log',
  [Parameter()][string]$SummaryFile = 'pester-summary.json',
  [Parameter()][int]$Tail = 40,
  [Parameter()][switch]$SkipSummaryWatch,
  [Parameter()][switch]$Quiet,
  [Parameter()][switch]$PreferNodeWatcher,
  [Parameter()][switch]$ForcePowerShell,
  [Parameter()][int]$WarnSeconds = 90,
  [Parameter()][int]$HangSeconds = 180,
  [Parameter()][int]$PollMs = 10000,
  [Parameter()][int]$NoProgressSeconds = 0,
  [Parameter()][string]$ProgressRegex = '^(?:\s*\[[-+\*]\]|\s*It\s)',
  [Parameter()][string]$EventsFile = '',
  [Parameter()][switch]$ExitOnHang,
  [Parameter()][switch]$ExitOnNoProgress
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NodeWatcher {
  param(
    [string]$ResultsDir,
    [string]$LogFile,
    [string]$SummaryFile,
    [int]$TailLines,
    [switch]$Quiet,
    [int]$WarnSeconds,
    [int]$HangSeconds,
    [int]$PollMs,
    [int]$NoProgressSeconds,
    [string]$ProgressRegex,
    [string]$EventsFile,
    [switch]$ExitOnHang,
    [switch]$ExitOnNoProgress
  )
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) { return $null }
  $scriptRoot = Split-Path -Parent $PSCommandPath
  $nodeScript = Join-Path $scriptRoot 'follow-pester-artifacts.mjs'
  if (-not (Test-Path -LiteralPath $nodeScript)) { return $null }
  $arguments = @(
    $nodeScript,
    '--results', $ResultsDir,
    '--log', $LogFile,
    '--summary', $SummaryFile,
    '--tail', $TailLines.ToString(),
    '--warn-seconds', $WarnSeconds.ToString(),
    '--hang-seconds', $HangSeconds.ToString(),
    '--poll-ms', $PollMs.ToString(),
    '--no-progress-seconds', $NoProgressSeconds.ToString(),
    '--progress-regex', $ProgressRegex
  )
  if ($EventsFile) { $arguments += @('--events-file', $EventsFile) }
  if ($Quiet) { $arguments += '--quiet' }
  if ($ExitOnHang) { $arguments += '--exit-on-hang' }
  if ($ExitOnNoProgress) { $arguments += '--exit-on-no-progress' }
  try {
    $process = Start-Process -FilePath $nodeCmd.Source -ArgumentList $arguments -NoNewWindow -PassThru
    $process.WaitForExit()
    return $process.ExitCode
  } catch {
    Write-Warning "[follow] Node watcher failed to start: $($_.Exception.Message)"
    return $null
  }
}

$watcherPreference = 'auto'
if ($ForcePowerShell) {
  $watcherPreference = 'powershell'
} elseif ($PreferNodeWatcher) {
  $watcherPreference = 'node'
} elseif ($env:PREFERRED_PESTER_WATCHER) {
  $watcherPreference = $env:PREFERRED_PESTER_WATCHER
}

$preferNode = $false
switch -Regex ($watcherPreference) {
  '^(?i:ps|powershell)$' { $preferNode = $false; break }
  '^(?i:node)$' { $preferNode = $true; break }
  default { $preferNode = $true }
}

if ($preferNode -and -not $ForcePowerShell) {
  $exitCode = Invoke-NodeWatcher -ResultsDir $ResultsDir -LogFile $LogFile -SummaryFile $SummaryFile -TailLines $Tail -Quiet:$Quiet -WarnSeconds $WarnSeconds -HangSeconds $HangSeconds -PollMs $PollMs -NoProgressSeconds $NoProgressSeconds -ProgressRegex $ProgressRegex -EventsFile $EventsFile -ExitOnHang:$ExitOnHang -ExitOnNoProgress:$ExitOnNoProgress
  if ($exitCode -ne $null) {
    exit $exitCode
  }
  Write-Warning '[follow] Falling back to PowerShell watcher (Node watcher unavailable).'
  if ($ExitOnHang) {
    Write-Warning '[follow] ExitOnHang is only available with the Node watcher; continuing without fail-fast behaviour.'
  }
  if ($ExitOnNoProgress) {
    Write-Warning '[follow] ExitOnNoProgress is only available with the Node watcher; continuing without fail-fast behaviour.'
  }
}

function Invoke-FileTailRead {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter()][long]$StartOffset
  )
  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $null = $fs.Seek($StartOffset, [System.IO.SeekOrigin]::Begin)
    $reader = New-Object System.IO.StreamReader($fs)
    try {
      $data = $reader.ReadToEnd()
      return [pscustomobject]@{
        Data = $data
        Position = $fs.Position
      }
    } finally {
      $reader.Close()
    }
  } finally {
    $fs.Close()
  }
}

function Show-InitialLogTail {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter()][int]$TailLines = 40
  )
  if (Test-Path -LiteralPath $Path) {
    if (-not $Quiet) {
      Write-Host ("[follow] Initial tail for {0} (last {1} lines)" -f $Path, $TailLines)
    }
    Get-Content -LiteralPath $Path -Tail $TailLines | ForEach-Object {
      if ($_ -ne '') { Write-Host $_ }
    }
    return (Get-Item -LiteralPath $Path).Length
  }
  if (-not $Quiet) {
    Write-Host ("[follow] Waiting for log file: {0}" -f $Path)
  }
  return 0
}

function Emit-PesterSummary {
  param(
    [Parameter(Mandatory)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $attempts = 0
  while ($attempts -lt 3) {
    try {
      $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
      if ([string]::IsNullOrWhiteSpace($json)) { return }
      $obj = $json | ConvertFrom-Json -ErrorAction Stop
      $result = $obj.result
      if (-not $result -and $obj.Result) { $result = $obj.Result }
      $totals = $obj.totals
      if (-not $totals -and $obj.Totals) { $totals = $obj.Totals }
      $tests = $null; $passed = $null; $failed = $null; $skipped = $null
      if ($totals) {
        $tests = $totals.tests; if (-not $tests -and $totals.Tests -ne $null) { $tests = $totals.Tests }
        $passed = $totals.passed; if (-not $passed -and $totals.Passed -ne $null) { $passed = $totals.Passed }
        $failed = $totals.failed; if (-not $failed -and $totals.Failed -ne $null) { $failed = $totals.Failed }
        $skipped = $totals.skipped; if (-not $skipped -and $totals.Skipped -ne $null) { $skipped = $totals.Skipped }
      }
      $duration = $obj.durationSeconds
      if (-not $duration -and $obj.DurationSeconds) { $duration = $obj.DurationSeconds }
      if (-not $duration -and $obj.duration) { $duration = $obj.duration }
      $parts = @('[summary]')
      if ($result) { $parts += ('Result={0}' -f $result) }
      if ($tests -ne $null -or $passed -ne $null -or $failed -ne $null) {
        $parts += ('Tests={0}' -f ($tests ?? '?'))
        $parts += ('Passed={0}' -f ($passed ?? '?'))
        $parts += ('Failed={0}' -f ($failed ?? '?'))
        if ($skipped -ne $null) { $parts += ('Skipped={0}' -f $skipped) }
      }
      if ($duration) { $parts += ('Duration={0}' -f $duration) }
      Write-Host ($parts -join ' ')
      return
    } catch {
      Start-Sleep -Milliseconds 100
      $attempts++
      if ($attempts -ge 3) {
        Write-Warning ("[summary] Unable to parse {0}: {1}" -f $Path, $_.Exception.Message)
      }
    }
  }
}

$resultsFull = [System.IO.Path]::GetFullPath($ResultsDir)
$logFull = [System.IO.Path]::GetFullPath((Join-Path $resultsFull $LogFile))
$summaryFull = [System.IO.Path]::GetFullPath((Join-Path $resultsFull $SummaryFile))
$logDir = Split-Path -Parent $logFull
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$script:logPath = $logFull
$script:logPosition = Show-InitialLogTail -Path $logFull -TailLines $Tail
$script:logTailLines = $Tail
$watchers = @()
$registrations = @()
$watchSummary = -not $SkipSummaryWatch

try {
  $logWatcher = New-Object System.IO.FileSystemWatcher
  $logWatcher.Path = $logDir
  $logWatcher.Filter = (Split-Path -Leaf $logFull)
  $logWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
  $logWatcher.IncludeSubdirectories = $false
  $logWatcher.EnableRaisingEvents = $true
  $watchers += $logWatcher

  $logAction = {
    $args = $Event.SourceEventArgs
    $path = $args.FullPath
    $change = $args.ChangeType.ToString()
    if ($change -eq 'Deleted') { return }
    Start-Sleep -Milliseconds 80
    if ($change -eq 'Created' -or $change -eq 'Renamed') {
      $script:logPath = $path
      $script:logPosition = Show-InitialLogTail -Path $path -TailLines $script:logTailLines
      return
    }
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
      $result = Invoke-FileTailRead -Path $path -StartOffset $script:logPosition
      $script:logPosition = $result.Position
      if ($result.Data) {
        $lines = $result.Data -split "`r?`n"
        foreach ($line in $lines) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          Write-Host ("[log] {0}" -f $line)
        }
      }
    } catch {
      Write-Warning ("[log] Unable to read {0}: {1}" -f $path, $_.Exception.Message)
    }
  }

  $registrations += Register-ObjectEvent -InputObject $logWatcher -EventName Changed -SourceIdentifier 'FollowPester_LogChanged' -Action $logAction
  $registrations += Register-ObjectEvent -InputObject $logWatcher -EventName Created -SourceIdentifier 'FollowPester_LogCreated' -Action $logAction
  $registrations += Register-ObjectEvent -InputObject $logWatcher -EventName Renamed -SourceIdentifier 'FollowPester_LogRenamed' -Action $logAction

  if ($watchSummary) {
    $summaryDir = Split-Path -Parent $summaryFull
    if (-not (Test-Path -LiteralPath $summaryDir)) {
      New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $summaryFull) {
      Emit-PesterSummary -Path $summaryFull
    }
    $summaryWatcher = New-Object System.IO.FileSystemWatcher
    $summaryWatcher.Path = $summaryDir
    $summaryWatcher.Filter = (Split-Path -Leaf $summaryFull)
    $summaryWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
    $summaryWatcher.IncludeSubdirectories = $false
    $summaryWatcher.EnableRaisingEvents = $true
    $watchers += $summaryWatcher

    $summaryAction = {
      $args = $Event.SourceEventArgs
      if ($args.ChangeType.ToString() -eq 'Deleted') { return }
      Start-Sleep -Milliseconds 120
      Emit-PesterSummary -Path $args.FullPath
    }
    $registrations += Register-ObjectEvent -InputObject $summaryWatcher -EventName Changed -SourceIdentifier 'FollowPester_SummaryChanged' -Action $summaryAction
    $registrations += Register-ObjectEvent -InputObject $summaryWatcher -EventName Created -SourceIdentifier 'FollowPester_SummaryCreated' -Action $summaryAction
    $registrations += Register-ObjectEvent -InputObject $summaryWatcher -EventName Renamed -SourceIdentifier 'FollowPester_SummaryRenamed' -Action $summaryAction
  }

  if (-not $Quiet) {
    $msg = "Watching {0}" -f $logFull
    if ($watchSummary) { $msg += (" and {0}" -f $summaryFull) }
    Write-Host ($msg + ' (Ctrl+C to stop)')
  }

  while ($true) {
    Start-Sleep -Seconds 1
  }
} finally {
  foreach ($reg in $registrations) {
    try {
      Unregister-Event -SourceIdentifier $reg.Name -ErrorAction SilentlyContinue
    } catch {}
    try { $reg.Dispose() } catch {}
  }
  foreach ($watcher in $watchers) {
    try { $watcher.EnableRaisingEvents = $false } catch {}
    try { $watcher.Dispose() } catch {}
  }
  if (-not $Quiet) {
    Write-Host '[follow] Watchers stopped.'
  }
}
