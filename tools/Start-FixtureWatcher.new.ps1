<#
.SYNOPSIS
  Starts a FileSystemWatcher to monitor root VI fixtures (VI1.vi / VI2.vi) for any modifications during a test or action run.

.DESCRIPTION
  Emits structured log entries (JSON one per line) to stdout and optionally to a log file whenever a relevant filesystem event occurs.
  Designed for forensic investigation of unexpected fixture shrinkage / mutation.

  Events captured: Changed, Created, Deleted, Renamed.
  Each emitted JSON object fields:
    tsUtc              - UTC timestamp in ISO 8601 format
    event              - Change | Created | Deleted | Renamed | Error | Initial | Heartbeat
    fullPath           - Full path of affected file (post-rename new path)
    oldFullPath        - (Rename only) Old path
    name               - File name (post-rename)
    oldName            - (Rename only) Old file name
    length             - Current file length in bytes (0 if missing / not accessible)
    sha256             - Hex SHA256 of current file contents (null if missing or unreadable)
    exists             - Boolean indicating if file currently exists
    error              - (Error events) Exception message
    watcherRoot        - Root directory being watched (repo root)
    version            - Schema version for the log shape (v1)
    cpuPercent         - (Heartbeat + -IncludePerfMetrics) Approx host CPU usage (%)
    diskWriteBytesPerSec - (Heartbeat + -IncludePerfMetrics) LogicalDisk write bytes/sec for root drive

.PARAMETER LogPath
  Optional path to also append JSON lines (UTF-8) for archival. If not provided, only stdout is used.

.PARAMETER Quiet
  Suppress the initial banner and only emit JSON lines.

.PARAMETER DurationSeconds
  Optional duration after which the watcher auto-stops (helpful in CI). If omitted, runs until Ctrl+C / host process exit.

.PARAMETER PollHashOnChangeOnly
  If set, only compute hash for Changed/Created/Renamed (skip Deleted/Error). Default true.

.PARAMETER IncludeInitialState
  If set (default), emits a synthetic snapshot entry for each target file at startup with event = "Initial".

.PARAMETER HeartbeatSeconds
  Emit periodic Heartbeat events (one per target) capturing current size/hash (and optionally perf metrics).

.PARAMETER IncludePerfMetrics
  When set, Heartbeat events include cpuPercent and diskWriteBytesPerSec.

.PARAMETER Once
  Emit initial state (if requested) then exit immediately (ignores heartbeat/duration).

.PARAMETER IncludeSubdirectories
  Monitor subdirectories for .vi files (default: false).

.PARAMETER Targets
  Override list of target file names. Defaults to VI1.vi,VI2.vi.

.EXAMPLE
  pwsh -File tools/Start-FixtureWatcher.ps1 -LogPath fixture-watch.log -DurationSeconds 300

.NOTES
  Exit Codes:
    0 - Normal termination (timeout or Ctrl+C)
    9 - Failed to initialize watcher (path invalid or FSW error)
#>
[CmdletBinding()]
param(
  [string]$LogPath,
  [switch]$Quiet,
  [int]$DurationSeconds,
  [switch]$PollHashOnChangeOnly,
  [switch]$IncludeInitialState,
  [int]$HeartbeatSeconds,
  [switch]$IncludePerfMetrics,
  [switch]$Once,
  [switch]$IncludeSubdirectories,
  [string[]]$Targets = @('VI1.vi','VI2.vi')
)

if (-not $PSBoundParameters.ContainsKey('PollHashOnChangeOnly')) { $PollHashOnChangeOnly = $true }
if (-not $PSBoundParameters.ContainsKey('IncludeInitialState')) { $IncludeInitialState = $true }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath '.').ProviderPath
if (-not (Test-Path $root)) { Write-Error "Root path not found: $root"; exit 9 }

function New-LogObject {
  param(
    [string]$EventName,
    [System.IO.FileSystemEventArgs]$FsArgs,
    [System.IO.RenamedEventArgs]$RenameArgs,
    [string]$ErrorMessage
  )
  $fullPath = $null
  $oldFullPath = $null
  $name = $null
  $oldName = $null
  if ($RenameArgs) {
    $fullPath = $RenameArgs.FullPath
    $oldFullPath = $RenameArgs.OldFullPath
    $name = $RenameArgs.Name
    $oldName = $RenameArgs.OldName
  } elseif ($FsArgs) {
    $fullPath = $FsArgs.FullPath
    $name = $FsArgs.Name
  } elseif ($ErrorMessage) {
    $fullPath = $null
  }

  $exists = $false
  $length = 0
  $sha256 = $null
  if ($fullPath -and (Test-Path -LiteralPath $fullPath)) {
    try {
      $fi = Get-Item -LiteralPath $fullPath -ErrorAction Stop
      $exists = $true
      $length = [int64]$fi.Length
      $needHash = $true
      if ($PollHashOnChangeOnly -and $EventName -in @('Deleted','Error')) { $needHash = $false }
      if ($needHash) {
        try {
          $bytes = [System.IO.File]::ReadAllBytes($fullPath)
          $sha256 = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        } catch { $sha256 = $null }
      }
    } catch {}
  }

  [pscustomobject]@{
    schema      = 'fixture-watch-log-v1'
    version     = 1
    tsUtc       = (Get-Date).ToUniversalTime().ToString('o')
    event       = $EventName
    fullPath    = $fullPath
    oldFullPath = $oldFullPath
    name        = $name
    oldName     = $oldName
    length      = $length
    sha256      = $sha256
    exists      = $exists
    watcherRoot = $root
    error       = $ErrorMessage
    targets     = $Targets
  }
}

function Write-LogObject {
  param([object]$Obj)
  if ($IncludePerfMetrics -and $Obj.event -eq 'Heartbeat') {
    $cpuPercent = $null; $diskWrite = $null
    try {
      $idle = (Get-Counter -Counter '\\Processor(_Total)\\% Idle Time' -ErrorAction Stop).CounterSamples[0].CookedValue
      $cpuPercent = [math]::Round([math]::Max(0,[math]::Min(100,100 - $idle)),2)
    } catch {}
    try {
      $driveRoot = ([IO.Path]::GetPathRoot($root)).TrimEnd('\\')
      $driveName = ($driveRoot.TrimEnd(':')) + ':'
      $diskSample = (Get-Counter -Counter '\\LogicalDisk(*)\\Disk Write Bytes/sec' -ErrorAction Stop).CounterSamples | Where-Object { $_.InstanceName -ieq $driveName }
      if ($diskSample) { $diskWrite = [math]::Round($diskSample.CookedValue,2) }
    } catch {}
    $Obj = [pscustomobject]@{
      schema      = $Obj.schema
      version     = $Obj.version
      tsUtc       = $Obj.tsUtc
      event       = $Obj.event
      fullPath    = $Obj.fullPath
      oldFullPath = $Obj.oldFullPath
      name        = $Obj.name
      oldName     = $Obj.oldName
      length      = $Obj.length
      sha256      = $Obj.sha256
      exists      = $Obj.exists
      watcherRoot = $Obj.watcherRoot
      error       = $Obj.error
      targets     = $Obj.targets
      cpuPercent  = $cpuPercent
      diskWriteBytesPerSec = $diskWrite
    }
  }
  $json = $Obj | ConvertTo-Json -Depth 4 -Compress
  Write-Output $json
  if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $json -Encoding UTF8 }
}

if (-not $Quiet) {
  Write-Host "=== Fixture Watcher (targets: $($Targets -join ', ')) ===" -ForegroundColor Cyan
  if ($LogPath) { Write-Host "Logging to: $LogPath" -ForegroundColor DarkCyan }
  if ($DurationSeconds) { Write-Host "Auto-stop after $DurationSeconds s" -ForegroundColor DarkCyan }
  if ($HeartbeatSeconds -gt 0) { Write-Host "Heartbeat every $HeartbeatSeconds s" -ForegroundColor DarkCyan }
  if ($IncludePerfMetrics) { Write-Host "Including perf metrics (cpuPercent, diskWriteBytesPerSec) on Heartbeats" -ForegroundColor DarkCyan }
  if ($Once) { Write-Host "Once mode: emit initial state then exit" -ForegroundColor DarkCyan }
  if ($IncludeSubdirectories) { Write-Host "Including subdirectories" -ForegroundColor DarkCyan }
}

$watcher = New-Object System.IO.FileSystemWatcher $root, '*.vi'
$watcher.IncludeSubdirectories = [bool]$IncludeSubdirectories
$watcher.EnableRaisingEvents = $true
$watcher.NotifyFilter = [IO.NotifyFilters]'FileName, LastWrite, Size'

$eventHandlerChanged = Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier 'FixtureChanged' -Action {
  if ($Targets -contains $EventArgs.Name) { Write-LogObject (New-LogObject -EventName 'Changed' -FsArgs $EventArgs) }
}
$eventHandlerCreated = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'FixtureCreated' -Action {
  if ($Targets -contains $EventArgs.Name) { Write-LogObject (New-LogObject -EventName 'Created' -FsArgs $EventArgs) }
}
$eventHandlerDeleted = Register-ObjectEvent -InputObject $watcher -EventName Deleted -SourceIdentifier 'FixtureDeleted' -Action {
  if ($Targets -contains $EventArgs.Name) { Write-LogObject (New-LogObject -EventName 'Deleted' -FsArgs $EventArgs) }
}
$eventHandlerRenamed = Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier 'FixtureRenamed' -Action {
  if ($Targets -contains $EventArgs.OldName -or $Targets -contains $EventArgs.Name) { Write-LogObject (New-LogObject -EventName 'Renamed' -RenameArgs $EventArgs) }
}
$eventHandlerError = Register-ObjectEvent -InputObject $watcher -EventName Error -SourceIdentifier 'FixtureError' -Action {
  Write-LogObject (New-LogObject -EventName 'Error' -ErrorMessage $EventArgs.GetException().Message)
}

try {
  if ($IncludeInitialState) {
    foreach ($t in $Targets) {
      $path = Join-Path $root $t
      $fake = [pscustomobject]@{ FullPath=$path; Name=$t }
      Write-LogObject (New-LogObject -EventName 'Initial' -FsArgs $fake)
    }
  }
  if ($Once) { return }
  $stopTime = if ($DurationSeconds) { (Get-Date).AddSeconds($DurationSeconds) } else { [DateTime]::MaxValue }
  $nextHeartbeat = if ($HeartbeatSeconds -gt 0) { (Get-Date).AddSeconds($HeartbeatSeconds) } else { [DateTime]::MaxValue }
  while ((Get-Date) -lt $stopTime) {
    if ($HeartbeatSeconds -gt 0 -and (Get-Date) -ge $nextHeartbeat) {
      foreach ($t in $Targets) {
        $p = Join-Path $root $t
        $fake = [pscustomobject]@{ FullPath=$p; Name=[System.IO.Path]::GetFileName($p) }
        Write-LogObject (New-LogObject -EventName 'Heartbeat' -FsArgs $fake)
      }
      $nextHeartbeat = (Get-Date).AddSeconds($HeartbeatSeconds)
    }
    Start-Sleep -Milliseconds 250
  }
}
finally {
  foreach ($h in @($eventHandlerChanged,$eventHandlerCreated,$eventHandlerDeleted,$eventHandlerRenamed,$eventHandlerError)) {
    if ($h) { Unregister-Event -SourceIdentifier $h.Name -ErrorAction SilentlyContinue }
  }
  if ($watcher) { $watcher.EnableRaisingEvents = $false; $watcher.Dispose() }
}
