param(
  [string]$PipeName,
  [string]$SentinelPath,
  [string]$ResultsDir = 'tests/results/_invoker',
  [string]$ReadyFile,
  [string]$StoppedFile,
  [string]$PidFile
)

$ErrorActionPreference = 'Stop'

function New-ParentDir {
  param([string]$Path)
  if (-not $Path) { return }
  $dir = [System.IO.Path]::GetDirectoryName($Path)
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if (-not $PipeName) {
  $PipeName = "lvci.invoker.$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ID')).$([Environment]::GetEnvironmentVariable('GITHUB_JOB')).$([Environment]::GetEnvironmentVariable('GITHUB_RUN_ATTEMPT'))"
}
if (-not $ReadyFile)   { $ReadyFile   = Join-Path $ResultsDir "_invoker/ready.json" }
if (-not $StoppedFile) { $StoppedFile = Join-Path $ResultsDir "_invoker/stopped.json" }
if (-not $PidFile)     { $PidFile     = Join-Path $ResultsDir "_invoker/pid.txt" }

$invokerDir = Join-Path $ResultsDir '_invoker'
New-Item -ItemType Directory -Path $invokerDir -Force | Out-Null

if ($SentinelPath) {
  New-ParentDir -Path $SentinelPath
  if (-not (Test-Path -LiteralPath $SentinelPath)) { New-Item -ItemType File -Path $SentinelPath -Force | Out-Null }
}

$trackerModule = Join-Path (Split-Path $PSScriptRoot -Parent) 'LabVIEWPidTracker.psm1'
$trackerLoaded = $false
$trackerPath = $null
$trackerContextPath = $null
$trackerState = $null
$trackerFinalState = $null
$trackerError = $null
if (Test-Path -LiteralPath $trackerModule -PathType Leaf) {
  try {
    Import-Module $trackerModule -Force -ErrorAction Stop | Out-Null
    $trackerLoaded = $true
  } catch {
    $trackerLoaded = $false
    $trackerError = $_.Exception.Message
  }
}
if ($trackerLoaded) {
  $trackerPath = Join-Path $invokerDir 'labview-pid.json'
  $trackerContextPath = Join-Path $invokerDir 'labview-pid-context.json'
  try {
    $trackerState = Start-LabVIEWPidTracker -TrackerPath $trackerPath -Source 'invoker:init'
  } catch {
    $trackerLoaded = $false
    $trackerPath = $null
    $trackerContextPath = $null
    $trackerState = $null
    $trackerError = $_.Exception.Message
  }
}

# Default single-compare sessions to enable autostop unless explicitly disabled
if ($env:LVCI_SINGLE_COMPARE -and -not $env:LVCI_SINGLE_COMPARE_AUTOSTOP) {
  $env:LVCI_SINGLE_COMPARE_AUTOSTOP = '1'
}

# Touch console-spawns.ndjson (artifact presence guarantee)
$spawns = Join-Path $ResultsDir '_invoker/console-spawns.ndjson'
if (-not (Test-Path -LiteralPath $spawns)) { New-Item -ItemType File -Path $spawns -Force | Out-Null }

# Write PID file
$pidContent = [string]$PID
Set-Content -LiteralPath $PidFile -Value $pidContent -Encoding ASCII

# Write ready marker
$now = (Get-Date).ToUniversalTime().ToString('o')
$readyObj = [pscustomobject]@{ schema='invoker-ready/v1'; pipe=$PipeName; pid=$PID; at=$now }
if ($trackerLoaded -and $trackerPath) {
  $trackerReady = [ordered]@{ enabled = $true; path = $trackerPath }
  if ($trackerState) { $trackerReady['initial'] = $trackerState }
  if ($trackerContextPath) { $trackerReady['contextPath'] = $trackerContextPath }
  Add-Member -InputObject $readyObj -MemberType NoteProperty -Name labviewPidTracker -Value ([pscustomobject]$trackerReady)
} elseif ($trackerError) {
  Add-Member -InputObject $readyObj -MemberType NoteProperty -Name labviewPidTrackerError -Value $trackerError
}
$readyObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReadyFile -Encoding UTF8

# Load server module and run loop until sentinel removed
Import-Module (Join-Path $PSScriptRoot 'RunnerInvoker.psm1') -Force
$hb = Join-Path $ResultsDir '_invoker/heartbeat.ndjson'
try {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = 0
  $job = Start-Job -ScriptBlock {
    param($pn,$sp,$rd,$trackerCtxPath,$trackerEnabled)
    Import-Module (Join-Path $using:PSScriptRoot 'RunnerInvoker.psm1') -Force
    Start-InvokerLoop -PipeName $pn -SentinelPath $sp -ResultsDir $rd -PollIntervalMs 200 -TrackerContextPath $trackerCtxPath -TrackerContextSource 'invoker:loop' -TrackerEnabled:$trackerEnabled
  } -ArgumentList @($PipeName,$SentinelPath,$ResultsDir,$trackerContextPath,$trackerLoaded)
  while ($true) {
    if ($SentinelPath -and -not (Test-Path -LiteralPath $SentinelPath)) { break }
    if (($sw.ElapsedMilliseconds - $last) -ge 1000) {
      $beat = [pscustomobject]@{ at=(Get-Date).ToUniversalTime().ToString('o'); pid=$PID }
      ($beat | ConvertTo-Json -Compress) | Add-Content -LiteralPath $hb -Encoding UTF8
      $last = $sw.ElapsedMilliseconds
    }
    Start-Sleep -Milliseconds 200
  }
}
finally {
  try { Receive-Job * | Out-Null; Remove-Job * -Force -ErrorAction SilentlyContinue } catch {}
  $stopStamp = (Get-Date).ToUniversalTime().ToString('o')
  $trackerContextRecord = $null
  if ($trackerLoaded -and $trackerPath) {
    if ($trackerContextPath -and (Test-Path -LiteralPath $trackerContextPath -PathType Leaf)) {
      try {
        $ctxRaw = Get-Content -LiteralPath $trackerContextPath -Raw -Encoding UTF8
        if ($ctxRaw) {
          $parsed = $ctxRaw | ConvertFrom-Json -Depth 6
          if ($parsed) {
            $ordered = [ordered]@{}
            foreach ($prop in $parsed.PSObject.Properties) { $ordered[$prop.Name] = $prop.Value }
            $ordered['stopObservedAt'] = $stopStamp
            $trackerContextRecord = [pscustomobject]$ordered
          }
        }
      } catch {}
    }
    if (-not $trackerContextRecord) {
      $fallback = [ordered]@{ stage = 'invoker:stop'; stopObservedAt = $stopStamp }
      if ($SentinelPath) { $fallback['sentinelPath'] = $SentinelPath }
      $trackerContextRecord = [pscustomobject]$fallback
    }
    $contextStage = $null
    if ($trackerContextRecord.PSObject.Properties['stage']) {
      try { $contextStage = [string]$trackerContextRecord.stage } catch { $contextStage = $null }
    }
    $stopSource = if ($contextStage) { $contextStage } else { 'invoker:stop' }
    $stopArgs = @{ TrackerPath = $trackerPath; Source = $stopSource }
    if ($trackerState -and $trackerState.PSObject.Properties['Pid'] -and $trackerState.Pid) {
      $stopArgs['Pid'] = $trackerState.Pid
    }
    if ($trackerContextRecord) { $stopArgs['Context'] = $trackerContextRecord }
    try {
      $trackerFinalState = Stop-LabVIEWPidTracker @stopArgs
    } catch {
      $trackerFinalState = $null
      $trackerError = $_.Exception.Message
    }
  }

  $stopPayload = [ordered]@{
    schema = 'invoker-stopped/v1'
    pid    = $PID
    at     = $stopStamp
  }
  if ($SentinelPath) { $stopPayload['sentinelPath'] = $SentinelPath }
  if ($trackerLoaded) {
    $trackerBlock = [ordered]@{ enabled = $true }
    if ($trackerPath) { $trackerBlock['path'] = $trackerPath }
    if ($trackerContextPath) { $trackerBlock['contextPath'] = $trackerContextPath }
    if ($trackerState) { $trackerBlock['initial'] = $trackerState }
    if ($trackerFinalState) {
      $trackerBlock['final'] = $trackerFinalState
    } elseif ($trackerState) {
      $trackerBlock['final'] = $trackerState
    }
    if ($trackerError) { $trackerBlock['error'] = $trackerError }
    $stopPayload['labviewPidTracker'] = [pscustomobject]$trackerBlock
  } elseif ($trackerError) {
    $stopPayload['labviewPidTrackerError'] = $trackerError
  }
  [pscustomobject]$stopPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StoppedFile -Encoding UTF8
}
