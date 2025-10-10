param(
  [switch]$Ensure,
  [switch]$Stop,
  [switch]$Status,
  [switch]$Trim,
  [switch]$AutoTrim,
  [string]$ResultsDir = 'tests/results',
  [int]$WarnSeconds = 60,
  [int]$HangSeconds = 120,
  [int]$PollMs = 2000,
  [int]$NoProgressSeconds = 90,
  [string]$ProgressRegex = '^(?:\s*\[[-+\*]\]|\s*It\s)',
  [int]$AutoTrimCooldownSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MaxLogBytes = 5MB
$MaxLogLines = 4000

function Get-WatcherPaths {
  param([string]$ResultsDir)
  $root = [System.IO.Path]::GetFullPath($ResultsDir)
  $agentDir = Join-Path $root '_agent'
  $watchDir = Join-Path $agentDir 'watcher'
  if (-not (Test-Path -LiteralPath $watchDir)) { New-Item -ItemType Directory -Force -Path $watchDir | Out-Null }
  [pscustomobject]@{
    Root     = $root
    Dir      = $watchDir
    PidFile  = Join-Path $watchDir 'pid.json'
    OutFile  = Join-Path $watchDir 'watch.out'
    ErrFile  = Join-Path $watchDir 'watch.err'
    StatusFile = Join-Path $watchDir 'watcher-status.json'
    HeartbeatFile = Join-Path $watchDir 'watcher-self.json'
    TrimMetadataFile = Join-Path $watchDir 'watcher-trim.json'
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Test-ProcessAlive {
  param([int]$Pid)
  try { $p = Get-Process -Id $Pid -ErrorAction Stop; return ($p -ne $null) } catch { return $false }
}

function Get-ProcessCommandLine {
  param([int]$Pid)
  try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$Pid" -ErrorAction Stop
    return $cim.CommandLine
  } catch {
    return $null
  }
}

function Get-WatcherProcessInfo {
  param([int]$Pid)
  try {
    $proc = Get-Process -Id $Pid -ErrorAction Stop
  } catch {
    return $null
  }
  $cmdLine = Get-ProcessCommandLine -Pid $Pid
  $path = $null
  try { $path = $proc.MainModule.FileName } catch {}
  [pscustomobject]@{
    Process = $proc
    CommandLine = $cmdLine
    Path = $path
  }
}

function Test-WatcherProcess {
  param(
    [pscustomobject]$ProcessInfo,
    [pscustomobject]$Paths
  )
  if (-not $ProcessInfo) {
    return [pscustomobject]@{ IsValid = $false; Reason = 'process not found' }
  }
  $cmd = $ProcessInfo.CommandLine
  if (-not $cmd) {
    return [pscustomobject]@{ IsValid = $false; Reason = 'command line unavailable' }
  }
  $cmdLower = $cmd.ToLowerInvariant()
  $scriptPath = (Join-Path (Split-Path -Parent $PSCommandPath) 'follow-pester-artifacts.mjs')
  $scriptLower = $scriptPath.ToLowerInvariant()
  $resultsLower = $Paths.Root.ToLowerInvariant()
  if ($cmdLower -notlike "*$scriptLower*") {
    return [pscustomobject]@{ IsValid = $false; Reason = 'unexpected script path' }
  }
  if ($cmdLower -notlike "*$resultsLower*") {
    return [pscustomobject]@{ IsValid = $false; Reason = 'unexpected results directory' }
  }
  [pscustomobject]@{ IsValid = $true; Reason = '' }
}

function Initialize-TrimMetadata {
  param([int]$CooldownSeconds)
  [ordered]@{
    schema = 'dev-watcher/trim-meta-v1'
    cooldownSeconds = $CooldownSeconds
    trimCount = 0
    autoTrimCount = 0
    manualTrimCount = 0
    lastTrimAt = $null
    lastAutoTrimAt = $null
    lastManualTrimAt = $null
    lastTrimKind = $null
    lastTrimBytes = $null
  }
}

function Get-TrimMetadata {
  param(
    [pscustomobject]$Paths,
    [int]$CooldownSeconds
  )
  $meta = Initialize-TrimMetadata -CooldownSeconds $CooldownSeconds
  $metaPath = $Paths.TrimMetadataFile
  if (Test-Path -LiteralPath $metaPath) {
    try {
      $raw = Get-Content -LiteralPath $metaPath -Raw
      if ($raw) {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($data) {
          foreach ($prop in $data.PSObject.Properties) {
            $meta[$prop.Name] = $prop.Value
          }
        }
      }
    } catch {
      Write-Warning ("[watcher] Failed to read trim metadata {0}: {1}" -f $metaPath, $_.Exception.Message)
    }
  }
  $meta['cooldownSeconds'] = $CooldownSeconds
  return $meta
}

function Set-TrimMetadata {
  param(
    [pscustomobject]$Paths,
    [System.Collections.IDictionary]$Metadata
  )
  $metaPath = $Paths.TrimMetadataFile
  try {
    if (-not (Test-Path -LiteralPath $Paths.Dir)) {
      New-Item -ItemType Directory -Force -Path $Paths.Dir | Out-Null
    }
    ($Metadata | ConvertTo-Json -Depth 4) | Out-File -FilePath $metaPath -Encoding utf8
  } catch {
    Write-Warning ("[watcher] Failed to persist trim metadata {0}: {1}" -f $metaPath, $_.Exception.Message)
  }
}

function Parse-TimestampUtc {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  try {
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    return [datetime]::Parse($Value, $culture, $styles)
  } catch {
    return $null
  }
}

function Normalize-JsonString {
  param($Value)
  if ($null -eq $Value) { return '' }
  if ($Value -is [string]) { return $Value }
  if ($Value -is [System.Array]) { return [string]::Join([Environment]::NewLine, $Value) }
  return [string]$Value
}

function Trim-LogFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{
      Trimmed = $false
      Path = $Path
      Reason = 'missing'
      OriginalBytes = 0
      ResultBytes = 0
      RemovedBytes = 0
      TailLines = 0
    }
  }
  $info = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $info) {
    return [pscustomobject]@{
      Trimmed = $false
      Path = $Path
      Reason = 'stat-failed'
      OriginalBytes = 0
      ResultBytes = 0
      RemovedBytes = 0
      TailLines = 0
    }
  }
  $originalBytes = $info.Length
  if ($originalBytes -le $MaxLogBytes) {
    return [pscustomobject]@{
      Trimmed = $false
      Path = $Path
      Reason = 'below-threshold'
      OriginalBytes = $originalBytes
      ResultBytes = $originalBytes
      RemovedBytes = 0
      TailLines = 0
    }
  }
  $lines = Get-Content -LiteralPath $Path -Tail $MaxLogLines
  $tailCount = if ($lines) { ($lines | Measure-Object).Count } else { 0 }
  $temp = [System.IO.Path]::GetTempFileName()
  try {
    $lines | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
  } catch {
    try { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } catch {}
    throw
  }
  $resultInfo = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
  $resultBytes = if ($resultInfo) { $resultInfo.Length } else { 0 }
  $removedBytes = [math]::Max(0, $originalBytes - $resultBytes)
  return [pscustomobject]@{
    Trimmed = $true
    Path = $Path
    Reason = 'trimmed'
    OriginalBytes = $originalBytes
    ResultBytes = $resultBytes
    RemovedBytes = $removedBytes
    TailLines = $tailCount
  }
}

function Test-LogsNeedTrim {
  param([pscustomobject]$Paths)
  foreach ($logPath in @($Paths.OutFile, $Paths.ErrFile)) {
    if (Test-Path -LiteralPath $logPath) {
      try {
        $item = Get-Item -LiteralPath $logPath -ErrorAction Stop
        if ($item.Length -gt $MaxLogBytes) { return $true }
      } catch {}
    }
  }
  return $false
}

function Invoke-WatcherTrim {
  param(
    [pscustomobject]$Paths,
    [pscustomobject]$Status,
    [string]$Reason,
    [int]$CooldownSeconds,
    [switch]$RespectCooldown
  )

  $nowUtc = (Get-Date).ToUniversalTime()
  $metadata = Get-TrimMetadata -Paths $Paths -CooldownSeconds $CooldownSeconds
  $cooldownSeconds = [int]($metadata['cooldownSeconds'])
  if ($cooldownSeconds -le 0) { $cooldownSeconds = $CooldownSeconds }

  $needsTrim = $false
  if ($Status -and $Status.PSObject.Properties['needsTrim']) {
    $needsTrim = [bool]$Status.PSObject.Properties['needsTrim'].Value
  } else {
    $needsTrim = Test-LogsNeedTrim -Paths $Paths
  }

  if (-not $needsTrim) {
    return [pscustomobject]@{
      Trimmed = $false
      RemovedBytes = 0
      Reason = 'no-needs-trim'
      CooldownSeconds = $cooldownSeconds
      CooldownRemainingSeconds = $null
      Results = @()
      Metadata = $metadata
    }
  }

  $lastTrimAt = Parse-TimestampUtc ($metadata['lastTrimAt'])
  $cooldownRemaining = $null
  if ($RespectCooldown -and $lastTrimAt) {
    $elapsedSeconds = ($nowUtc - $lastTrimAt).TotalSeconds
    if ($elapsedSeconds -lt $cooldownSeconds) {
      $cooldownRemaining = [int][math]::Ceiling($cooldownSeconds - $elapsedSeconds)
      return [pscustomobject]@{
        Trimmed = $false
        RemovedBytes = 0
        Reason = 'cooldown'
        CooldownSeconds = $cooldownSeconds
        CooldownRemainingSeconds = $cooldownRemaining
        Results = @()
        Metadata = $metadata
      }
    }
  }

  $results = @()
  foreach ($logPath in @($Paths.OutFile, $Paths.ErrFile)) {
    try {
      $results += ,(Trim-LogFile -Path $logPath)
    } catch {
      Write-Warning ("[watcher] Failed to trim log {0}: {1}" -f $logPath, $_.Exception.Message)
      $results += ,[pscustomobject]@{
        Trimmed = $false
        Path = $logPath
        Reason = 'error'
        OriginalBytes = $null
        ResultBytes = $null
        RemovedBytes = 0
        TailLines = 0
      }
    }
  }

  $trimmedRecords = @($results | Where-Object { $_.Trimmed })
  $totalRemoved = ($trimmedRecords | Measure-Object -Property RemovedBytes -Sum).Sum
  if (-not $totalRemoved) { $totalRemoved = 0 }

  if ($trimmedRecords.Count -gt 0) {
    $metadata['cooldownSeconds'] = $cooldownSeconds
    $metadata['trimCount'] = [int]($metadata['trimCount']) + 1
    if ($Reason -eq 'auto') {
      $metadata['autoTrimCount'] = [int]($metadata['autoTrimCount']) + 1
      $metadata['lastAutoTrimAt'] = $nowUtc.ToString('o')
    } else {
      $metadata['manualTrimCount'] = [int]($metadata['manualTrimCount']) + 1
      $metadata['lastManualTrimAt'] = $nowUtc.ToString('o')
    }
    $metadata['lastTrimAt'] = $nowUtc.ToString('o')
    $metadata['lastTrimKind'] = $Reason
    $metadata['lastTrimBytes'] = $totalRemoved
    Set-TrimMetadata -Paths $Paths -Metadata $metadata
  } else {
    $metadata['cooldownSeconds'] = $cooldownSeconds
    Set-TrimMetadata -Paths $Paths -Metadata $metadata
  }

  return [pscustomobject]@{
    Trimmed = ($trimmedRecords.Count -gt 0)
    RemovedBytes = $totalRemoved
    Reason = if ($trimmedRecords.Count -gt 0) { 'trimmed' } else { 'already-trimmed' }
    CooldownSeconds = $cooldownSeconds
    CooldownRemainingSeconds = $cooldownRemaining
    Results = $results
    Metadata = $metadata
  }
}


function Get-LogSnapshot {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return [pscustomobject]@{ path = $Path; exists = $false }
  }
  $item = Get-Item -LiteralPath $Path
  [pscustomobject]@{
    path = $Path
    exists = $true
    sizeBytes = $item.Length
    lastWriteTime = $item.LastWriteTimeUtc.ToString('o')
  }
}

function Get-PropValue {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }
  $prop = $Object.PSObject.Properties[$Name]
  if ($prop) { return $prop.Value }
  return $null
}

function Start-DevWatcher {
  param([string]$ResultsDir,[int]$WarnSeconds,[int]$HangSeconds,[int]$PollMs,[int]$NoProgressSeconds,[string]$ProgressRegex,[switch]$IncludeProgressRegex)
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  foreach ($logPath in @($paths.OutFile, $paths.ErrFile)) {
    try { [void](Trim-LogFile -Path $logPath) } catch { Write-Warning ([string]::Format('[watcher] Failed to trim log {0}: {1}', $logPath, $_.Exception.Message)) }
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw 'Node.js not found on PATH (required for watcher).' }
  $script = Join-Path (Split-Path -Parent $PSCommandPath) 'follow-pester-artifacts.mjs'
  if (-not (Test-Path -LiteralPath $script)) { throw "Watcher script not found: $script" }
  $args = @(
    $script,
    '--results', $paths.Root,
    '--warn-seconds', [string]$WarnSeconds,
    '--hang-seconds', [string]$HangSeconds,
    '--poll-ms', [string]$PollMs,
    '--no-progress-seconds', [string]$NoProgressSeconds,
    '--status-file', $paths.StatusFile,
    '--heartbeat-file', $paths.HeartbeatFile
  )
  if ($IncludeProgressRegex -and $ProgressRegex) {
    $progressArgument = $ProgressRegex.Replace(' ', '')
    $args += @('--progress-regex', $progressArgument)
  }
  $si = New-Object System.Diagnostics.ProcessStartInfo
  $si.FileName = $node.Source
  $si.UseShellExecute = $false
  $si.CreateNoWindow = $true
  $si.RedirectStandardOutput = $true
  $si.RedirectStandardError  = $true
  foreach ($arg in $args) { $null = $si.ArgumentList.Add($arg) }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $si
  $null = $p.Start()
  # async copy to files
  $outStream = [System.IO.StreamWriter]::new($paths.OutFile, $true)
  $errStream = [System.IO.StreamWriter]::new($paths.ErrFile, $true)
  $null = $p.StandardOutput.BaseStream.CopyToAsync($outStream.BaseStream)
  $null = $p.StandardError.BaseStream.CopyToAsync($errStream.BaseStream)
  $pidObj = [ordered]@{
    schema    = 'dev-watcher/pid-v1'
    pid       = $p.Id
    startedAt = (Get-Date).ToString('o')
    nodePath  = $node.Source
    script    = $script
    args      = $args
    outFile   = $paths.OutFile
    errFile   = $paths.ErrFile
    statusFile = $paths.StatusFile
    heartbeatFile = $paths.HeartbeatFile
  }
  ($pidObj | ConvertTo-Json -Depth 5) | Out-File -FilePath $paths.PidFile -Encoding utf8
  Write-Host ("Started dev watcher (PID {0})" -f $p.Id)
  return $p.Id
}

function Stop-DevWatcher {
  param([string]$ResultsDir)
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  $pidObj = Read-JsonFile -Path $paths.PidFile
  if ($pidObj -and $pidObj.pid -is [int]) {
    if (Test-ProcessAlive -Pid $pidObj.pid) {
      try { Stop-Process -Id $pidObj.pid -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-Host 'Stopped dev watcher.'
  } else {
    Write-Host 'No dev watcher PID found.'
  }
  # Always clear files regardless of PID state
  Remove-Item -LiteralPath $paths.PidFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $paths.StatusFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $paths.HeartbeatFile -Force -ErrorAction SilentlyContinue
}

function Get-DevWatcherStatus {
  param([string]$ResultsDir)
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  $pidObj = Read-JsonFile -Path $paths.PidFile
  $watcherPid = if ($pidObj -and $pidObj.pid -is [int]) { [int]$pidObj.pid } else { $null }
  $alive = $false
  $procInfo = $null
  $validation = $null
  if ($watcherPid) {
    $alive = Test-ProcessAlive -Pid $watcherPid
    if ($alive) {
      $procInfo = Get-WatcherProcessInfo -Pid $watcherPid
      $validation = Test-WatcherProcess -ProcessInfo $procInfo -Paths $paths
    }
  }

  $statusFileExists = Test-Path -LiteralPath $paths.StatusFile
  $heartbeatFileExists = Test-Path -LiteralPath $paths.HeartbeatFile
  $statusData = if ($statusFileExists) { Read-JsonFile -Path $paths.StatusFile } else { $null }
  $heartbeatData = if ($heartbeatFileExists) { Read-JsonFile -Path $paths.HeartbeatFile } else { $null }
  $heartbeatTimestamp = Get-PropValue $heartbeatData 'timestamp'
  $stateFromStatus = Get-PropValue $statusData 'state'
  $state = if ($stateFromStatus) { $stateFromStatus } elseif ($alive) { 'ok' } else { 'stopped' }
  $metrics = Get-PropValue $statusData 'metrics'
  if (-not $metrics) { $metrics = @{} }
  $thresholdData = Get-PropValue $statusData 'thresholds'
  $thresholds = if ($thresholdData) { $thresholdData } else {
    @{
      warnSeconds = $null
      hangSeconds = $null
      noProgressSeconds = $null
      pollMs = $null
    }
  }

  $heartbeatAgeSeconds = $null
  $heartbeatFresh = $false
  $heartbeatReason = $null
  if ($heartbeatTimestamp) {
    try {
      $culture = [System.Globalization.CultureInfo]::InvariantCulture
      $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
      $heartbeatMoment = [datetime]::Parse($heartbeatTimestamp, $culture, $styles)
      $ageSpan = ([datetime]::UtcNow) - $heartbeatMoment
      $ageSecondsValue = $null
      if ($ageSpan.TotalSeconds -ge 0) {
        $ageSecondsValue = [int][math]::Floor($ageSpan.TotalSeconds)
        $heartbeatAgeSeconds = $ageSecondsValue
      }
      $pollSeconds = $null
      if ($thresholds -and $thresholds.pollMs) {
        $pollSeconds = [double]$thresholds.pollMs / 1000.0
      }
      $staleSeconds = if ($pollSeconds -and $pollSeconds -gt 0) {
        [int][math]::Ceiling($pollSeconds * 4)
      } else { 10 }
      if ($ageSpan.TotalSeconds -ge 0 -and $ageSpan.TotalSeconds -le $staleSeconds) {
        $heartbeatFresh = $true
      } else {
        $ageForReason = if ($ageSecondsValue -ne $null) { $ageSecondsValue } else { [int][math]::Floor([math]::Max($ageSpan.TotalSeconds, 0)) }
        $heartbeatReason = "[heartbeat] stale (~${ageForReason}s)"
      }
    } catch {
      $heartbeatReason = '[heartbeat] timestamp parse failed'
    }
  } else {
    $heartbeatReason = '[heartbeat] missing'
  }

  $outInfo = Get-LogSnapshot -Path $paths.OutFile
  $errInfo = Get-LogSnapshot -Path $paths.ErrFile
  $needsTrim = ($outInfo.exists -and $outInfo.sizeBytes -gt $MaxLogBytes) -or ($errInfo.exists -and $errInfo.sizeBytes -gt $MaxLogBytes)

  $trimMetadata = Get-TrimMetadata -Paths $paths -CooldownSeconds $AutoTrimCooldownSeconds
  $lastTrimAtRaw = $trimMetadata['lastTrimAt']
  $lastTrimKind = $trimMetadata['lastTrimKind']
  $lastTrimBytes = $trimMetadata['lastTrimBytes']
  $lastAutoTrimAt = $trimMetadata['lastAutoTrimAt']
  $lastManualTrimAt = $trimMetadata['lastManualTrimAt']
  $trimCount = $trimMetadata['trimCount']
  $autoTrimCount = $trimMetadata['autoTrimCount']
  $manualTrimCount = $trimMetadata['manualTrimCount']
  $trimCooldownSeconds = [int]$trimMetadata['cooldownSeconds']
  if ($trimCooldownSeconds -le 0) { $trimCooldownSeconds = $AutoTrimCooldownSeconds }
  $lastTrimMoment = Parse-TimestampUtc $lastTrimAtRaw
  $autoTrimEligible = $false
  $autoTrimCooldownRemaining = $null
  $nextEligibleAt = $null
  if ($needsTrim) {
    if ($lastTrimMoment) {
      $elapsedSinceTrim = ([datetime]::UtcNow) - $lastTrimMoment
      if ($elapsedSinceTrim.TotalSeconds -ge $trimCooldownSeconds) {
        $autoTrimEligible = $true
      } else {
        $autoTrimEligible = $false
        $autoTrimCooldownRemaining = [int][math]::Ceiling([math]::Max($trimCooldownSeconds - $elapsedSinceTrim.TotalSeconds, 0))
        $nextEligibleAt = $lastTrimMoment.AddSeconds($trimCooldownSeconds).ToString('o')
      }
    } else {
      $autoTrimEligible = $true
    }
  }
  if (-not $needsTrim -and $lastTrimMoment -and $trimCooldownSeconds -gt 0) {
    $nextEligibleAt = $lastTrimMoment.AddSeconds($trimCooldownSeconds).ToString('o')
  }

  $processVerified = if ($validation) { $validation.IsValid } else { $false }
  $verificationReason = if ($validation) { $validation.Reason } else { $null }
  if ($processVerified -and -not $heartbeatFresh) {
    $processVerified = $false
    if ($heartbeatReason) {
      $verificationReason = if ($verificationReason) { "$verificationReason; $heartbeatReason" } else { $heartbeatReason }
    }
  } elseif (-not $processVerified -and -not $verificationReason -and -not $heartbeatFresh -and $heartbeatReason) {
    $verificationReason = $heartbeatReason
  }

  $obj = [ordered]@{
    schema = 'dev-watcher/status-v2'
    timestamp = (Get-Date).ToString('o')
    alive  = $alive
    pid    = $watcherPid
    verifiedProcess = $processVerified
    verificationReason = $verificationReason
    state  = if ($alive) { $state } else { 'stopped' }
    startedAt = if ($statusData) { Get-PropValue $statusData 'startedAt' } elseif ($pidObj) { $pidObj.startedAt } else { $null }
    lastActivityAt = Get-PropValue $metrics 'lastActivityAt'
    lastProgressAt = Get-PropValue $metrics 'lastProgressAt'
    lastSummaryAt = Get-PropValue $metrics 'lastSummaryAt'
    lastHangWatchAt = Get-PropValue $metrics 'lastHangWatchAt'
    lastHangSuspectAt = Get-PropValue $metrics 'lastHangSuspectAt'
    lastBusyWatchAt = Get-PropValue $metrics 'lastBusyWatchAt'
    lastBusySuspectAt = Get-PropValue $metrics 'lastBusySuspectAt'
    bytesSinceProgress = Get-PropValue $metrics 'bytesSinceProgress'
    lastHeartbeatAt = $heartbeatTimestamp
    heartbeatAgeSeconds = $heartbeatAgeSeconds
    heartbeatFresh = $heartbeatFresh
    heartbeatReason = $heartbeatReason
    thresholds = $thresholds
    files = @{ 
      pid = @{ path = $paths.PidFile }
      status = @{ path = $paths.StatusFile; exists = $statusFileExists }
      heartbeat = @{
        path = $paths.HeartbeatFile
        exists = $heartbeatFileExists
        timestamp = $heartbeatTimestamp
        ageSeconds = $heartbeatAgeSeconds
        schema = Get-PropValue $heartbeatData 'schema'
      }
      out = $outInfo
      err = $errInfo
      trim = @{
        path = $paths.TrimMetadataFile
        exists = (Test-Path -LiteralPath $paths.TrimMetadataFile)
      }
    }
    process = @{
      commandLine = Get-PropValue $procInfo 'CommandLine'
      path = Get-PropValue $procInfo 'Path'
      verified = $processVerified
    }
    needsTrim = $needsTrim
    autoTrim = @{
      cooldownSeconds = $trimCooldownSeconds
      eligible = $autoTrimEligible
      cooldownRemainingSeconds = $autoTrimCooldownRemaining
      nextEligibleAt = $nextEligibleAt
      lastTrimAt = $lastTrimAtRaw
      lastTrimKind = $lastTrimKind
      lastTrimBytes = $lastTrimBytes
      lastAutoTrimAt = $lastAutoTrimAt
      lastManualTrimAt = $lastManualTrimAt
      trimCount = $trimCount
      autoTrimCount = $autoTrimCount
      manualTrimCount = $manualTrimCount
    }
  }
  return ($obj | ConvertTo-Json -Depth 6)
}

if ($Ensure) {
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  $pidObj = Read-JsonFile -Path $paths.PidFile
  $needStart = $true
  if ($pidObj -and $pidObj.pid -is [int]) {
    $alive = Test-ProcessAlive -Pid $pidObj.pid
    if ($alive) {
      $procInfo = Get-WatcherProcessInfo -Pid $pidObj.pid
      $validation = Test-WatcherProcess -ProcessInfo $procInfo -Paths $paths
      if ($validation.IsValid) {
        $statusDataEnsure = Read-JsonFile -Path $paths.StatusFile
        $thresholdDataEnsure = Get-PropValue $statusDataEnsure 'thresholds'
        $pollMsEnsure = if ($thresholdDataEnsure) { Get-PropValue $thresholdDataEnsure 'pollMs' } else { $null }
        $heartbeatEnsure = Read-JsonFile -Path $paths.HeartbeatFile
        $heartbeatTimestampEnsure = Get-PropValue $heartbeatEnsure 'timestamp'
        $hbFresh = $false
        $hbReason = '[heartbeat] missing'
        if ($heartbeatTimestampEnsure) {
          try {
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            $hbMoment = [datetime]::Parse($heartbeatTimestampEnsure, $culture, $styles)
            $ageSpan = ([datetime]::UtcNow) - $hbMoment
            $pollSecondsEnsure = if ($pollMsEnsure) { [double]$pollMsEnsure / 1000.0 } else { $null }
            $staleSecondsEnsure = if ($pollSecondsEnsure -and $pollSecondsEnsure -gt 0) { [int][math]::Ceiling($pollSecondsEnsure * 4) } else { 10 }
            if ($ageSpan.TotalSeconds -ge 0 -and $ageSpan.TotalSeconds -le $staleSecondsEnsure) {
              $hbFresh = $true
            } else {
              $hbReason = "[heartbeat] stale (~$([int][math]::Floor([math]::Max($ageSpan.TotalSeconds,0))))s)"
            }
          } catch {
            $hbReason = '[heartbeat] timestamp parse failed'
          }
        }
        if ($hbFresh) {
          $needStart = $false
        } else {
          Write-Warning "[watcher] ${hbReason}. Restarting."
          Stop-DevWatcher -ResultsDir $ResultsDir | Out-Null
          $needStart = $true
        }
      } else {
        Write-Warning "[watcher] Existing process did not match expectations: $($validation.Reason). Restarting."
        Stop-DevWatcher -ResultsDir $ResultsDir | Out-Null
        $needStart = $true
      }
    }
  }
  if ($needStart) {
    $includeRegex = $PSBoundParameters.ContainsKey('ProgressRegex')
    Start-DevWatcher -ResultsDir $ResultsDir -WarnSeconds $WarnSeconds -HangSeconds $HangSeconds -PollMs $PollMs -NoProgressSeconds $NoProgressSeconds -ProgressRegex $ProgressRegex -IncludeProgressRegex:$includeRegex | Out-Null
  } else {
    Write-Host ("Dev watcher already running (PID {0})." -f $pidObj.pid)
  }
  $statusJsonEnsureFinal = Normalize-JsonString (Get-DevWatcherStatus -ResultsDir $ResultsDir)
  $statusEnsureFinal = $null
  try { $statusEnsureFinal = $statusJsonEnsureFinal | ConvertFrom-Json -ErrorAction Stop } catch {}
  if ($statusEnsureFinal) {
    $trimOutcome = Invoke-WatcherTrim -Paths $paths -Status $statusEnsureFinal -Reason 'auto' -CooldownSeconds $AutoTrimCooldownSeconds -RespectCooldown
    if ($trimOutcome.Trimmed) {
      Write-Host ("[watcher] Auto-trimmed logs (~{0} bytes removed)." -f $trimOutcome.RemovedBytes)
    } elseif ($trimOutcome.Reason -eq 'cooldown' -and $trimOutcome.CooldownRemainingSeconds -ne $null) {
      Write-Host ("[watcher] Auto-trim cooldown active (~{0}s remaining)." -f $trimOutcome.CooldownRemainingSeconds)
    }
  }
}
elseif ($Stop) {
  Stop-DevWatcher -ResultsDir $ResultsDir
}
elseif ($Status) {
  # Emit status JSON to the success stream so callers can capture output without spawning nested pwsh
  Get-DevWatcherStatus -ResultsDir $ResultsDir | Write-Output
}
elseif ($Trim) {
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  $statusJsonManual = Normalize-JsonString (Get-DevWatcherStatus -ResultsDir $ResultsDir)
  $statusManual = $null
  try { $statusManual = $statusJsonManual | ConvertFrom-Json -ErrorAction Stop } catch {}
  $trimOutcome = Invoke-WatcherTrim -Paths $paths -Status $statusManual -Reason 'manual' -CooldownSeconds $AutoTrimCooldownSeconds
  if ($trimOutcome.Trimmed) {
    Write-Host ("Trimmed watcher logs (~{0} bytes removed)." -f $trimOutcome.RemovedBytes)
  } elseif ($trimOutcome.Reason -eq 'no-needs-trim') {
    Write-Host 'No trimming needed.'
  } else {
    Write-Host ("No trimming performed ({0})." -f $trimOutcome.Reason)
  }
}
elseif ($AutoTrim) {
  $statusJson = Normalize-JsonString (Get-DevWatcherStatus -ResultsDir $ResultsDir)
  $status = $null
  try { $status = $statusJson | ConvertFrom-Json -ErrorAction Stop } catch {
    Write-Warning ("[watcher] Failed to gather watcher status: {0}" -f $_.Exception.Message)
  }
  $paths = Get-WatcherPaths -ResultsDir $ResultsDir
  $trimOutcome = Invoke-WatcherTrim -Paths $paths -Status $status -Reason 'auto' -CooldownSeconds $AutoTrimCooldownSeconds -RespectCooldown
  if ($trimOutcome.Trimmed) {
    Write-Host ("Trimmed watcher logs (~{0} bytes removed)." -f $trimOutcome.RemovedBytes)
  } elseif ($trimOutcome.Reason -eq 'cooldown' -and $trimOutcome.CooldownRemainingSeconds -ne $null) {
    Write-Host ("Auto-trim cooldown active (~{0}s remaining)." -f $trimOutcome.CooldownRemainingSeconds)
  } elseif ($trimOutcome.Reason -eq 'no-needs-trim') {
    Write-Host 'No trimming needed.'
  } else {
    Write-Host ("Auto-trim skipped ({0})." -f $trimOutcome.Reason)
  }
}
else {
  Write-Host 'Usage:'
  Write-Host '  Ensure watcher:  pwsh -File tools/Dev-WatcherManager.ps1 -Ensure'
  Write-Host '  Show status:     pwsh -File tools/Dev-WatcherManager.ps1 -Status'
  Write-Host '  Stop watcher:    pwsh -File tools/Dev-WatcherManager.ps1 -Stop'
  Write-Host '  Trim logs:       pwsh -File tools/Dev-WatcherManager.ps1 -Trim'
  Write-Host '  Auto-trim if needed: pwsh -File tools/Dev-WatcherManager.ps1 -AutoTrim'
}
