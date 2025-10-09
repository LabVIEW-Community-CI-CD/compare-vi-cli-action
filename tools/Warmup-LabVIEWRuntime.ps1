<#
.SYNOPSIS
  Deterministic LabVIEW runtime warmup for self-hosted Windows runners.

.DESCRIPTION
  Ensures a LabVIEW.exe process is running (or can be started) before downstream
  orchestration begins. Launches LabVIEW via ProcessStartInfo with UI-suppression
  toggles, waits for readiness, emits NDJSON breadcrumbs, and optionally stops
  LabVIEW when warmup completes. Designed to run outside of GitHub-hosted agents.

.PARAMETER LabVIEWPath
  Explicit path to LabVIEW.exe. When omitted, derived from LABVIEW_PATH,
  or the canonical install path for LabVIEW <version>/<bitness>.

.PARAMETER MinimumSupportedLVVersion
  Version string used when deriving the canonical LabVIEW path. Defaults to 2025,
  falling back to LABVIEW_VERSION or MINIMUM_SUPPORTED_LV_VERSION.

.PARAMETER SupportedBitness
  LabVIEW bitness (32 or 64). Defaults to 64, falling back to LABVIEW_BITNESS,
  or MINIMUM_SUPPORTED_LV_BITNESS.

.PARAMETER TimeoutSeconds
  Time to wait for LabVIEW to appear after launch. Default 30 seconds.

.PARAMETER IdleWaitSeconds
  Additional idle gate after LabVIEW starts. Default 2 seconds.

.PARAMETER KeepLabVIEW
  Leave LabVIEW running after warmup (default behaviour). When omitted with
  -StopAfterWarmup, LabVIEW is stopped before exit.

.PARAMETER StopAfterWarmup
  Request that LabVIEW be stopped once warmup completes.

.PARAMETER JsonLogPath
  NDJSON event log path (schema warmup-labview-v1). Defaults to
  tests/results/_warmup/labview-runtime.ndjson when not suppressed.

.PARAMETER SnapshotPath
  Optional JSON snapshot file capturing LabVIEW processes. Defaults to
  tests/results/_warmup/labview-processes.json.

.PARAMETER SkipSnapshot
  Skip process snapshot emission.

.PARAMETER DryRun
  Compute the warmup plan and emit events without launching LabVIEW.

.PARAMETER KillOnTimeout
  If LabVIEW is still running when StopAfterWarmup is requested, terminate it forcibly.
#>
[CmdletBinding()]
param(
  [string]$LabVIEWPath,
  [string]$MinimumSupportedLVVersion,
  [ValidateSet('32','64')][string]$SupportedBitness,
  [int]$TimeoutSeconds = 30,
  [int]$IdleWaitSeconds = 2,
  [switch]$KeepLabVIEW,
  [switch]$StopAfterWarmup,
  [string]$JsonLogPath,
  [string]$SnapshotPath = 'tests/results/_warmup/labview-processes.json',
  [switch]$SkipSnapshot,
  [switch]$DryRun,
  [switch]$KillOnTimeout
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonEvent {
  param([string]$Type,[hashtable]$Data)
  if (-not $JsonLogPath) { return }
  try {
    $dir = Split-Path -Parent $JsonLogPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString('o')
      type      = $Type
      schema    = 'warmup-labview-v1'
    }
    if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }
    ($payload | ConvertTo-Json -Compress) | Add-Content -Path $JsonLogPath
  } catch {
    Write-Warning "Warmup-LabVIEWRuntime: failed to append event: $($_.Exception.Message)"
  }
}

function Write-StepSummaryLine {
  param([string]$Message)
  if ($env:GITHUB_STEP_SUMMARY) {
    $Message | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  }
}

function Write-Snapshot {
  param([string]$Path)
  if ($SkipSnapshot -or -not $Path) { return }
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $procs = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,StartTime,Path)
    $payload = [ordered]@{
      schema = 'labview-process-snapshot/v1'
      at     = (Get-Date).ToString('o')
      items  = $procs
    }
    $payload | ConvertTo-Json -Depth 4 | Out-File -FilePath $Path -Encoding utf8
  } catch {
    Write-Warning "Warmup-LabVIEWRuntime: failed to capture snapshot: $($_.Exception.Message)"
  }
}

if ($IsWindows -ne $true) { return }

if (-not $JsonLogPath -and -not ($env:WARMUP_NO_JSON -eq '1')) {
  $JsonLogPath = 'tests/results/_warmup/labview-runtime.ndjson'
}

if (-not $SupportedBitness) {
  $SupportedBitness = if ($env:LABVIEW_BITNESS) {
    $env:LABVIEW_BITNESS
  } elseif ($env:MINIMUM_SUPPORTED_LV_BITNESS) {
    $env:MINIMUM_SUPPORTED_LV_BITNESS
  } else {
    '64'
  }
}

if (-not $MinimumSupportedLVVersion) {
  $MinimumSupportedLVVersion = if ($env:LOOP_LABVIEW_VERSION) {
    $env:LOOP_LABVIEW_VERSION
  } elseif ($env:LABVIEW_VERSION) {
    $env:LABVIEW_VERSION
  } elseif ($env:MINIMUM_SUPPORTED_LV_VERSION) {
    $env:MINIMUM_SUPPORTED_LV_VERSION
  } else {
    '2025'
  }
}

if (-not $LabVIEWPath) { if ($env:LABVIEW_PATH) { $LabVIEWPath = $env:LABVIEW_PATH } }

if (-not $LabVIEWPath) {
  $pf = if ($SupportedBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  if ($pf) { $LabVIEWPath = Join-Path $pf ("National Instruments\LabVIEW $MinimumSupportedLVVersion\LabVIEW.exe") }
}

Write-JsonEvent 'plan' @{
  exePath    = $LabVIEWPath
  timeout    = $TimeoutSeconds
  idleWait   = $IdleWaitSeconds
  keep       = $KeepLabVIEW.IsPresent
  stopAfter  = $StopAfterWarmup.IsPresent
  bitness    = $SupportedBitness
  version    = $MinimumSupportedLVVersion
  dryRun     = $DryRun.IsPresent
}

if (-not $LabVIEWPath) {
  Write-Warning "Warmup-LabVIEWRuntime: LabVIEW path not provided and cannot be inferred."
  Write-JsonEvent 'skip' @{ reason = 'labview-path-missing' }
  return
}

if (-not (Test-Path -LiteralPath $LabVIEWPath -PathType Leaf)) {
  Write-Warning "Warmup-LabVIEWRuntime: LabVIEW executable not found at $LabVIEWPath."
  Write-JsonEvent 'skip' @{ reason = 'labview-path-missing'; path = $LabVIEWPath }
  return
}

try {
  $existing = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
} catch {
  $existing = @()
}

if ($existing.Count -gt 0) {
  Write-Host ("Warmup: LabVIEW already running (PID(s): {0})" -f ($existing.Id -join ',')) -ForegroundColor Gray
  Write-StepSummaryLine ("- Warmup: LabVIEW already running (PID(s): {0})" -f ($existing.Id -join ','))
  Write-JsonEvent 'labview-present' @{ pids = ($existing.Id -join ','); alreadyRunning = $true }
  if ($StopAfterWarmup) {
    Write-Host "Warmup: StopAfterWarmup requested; stopping existing LabVIEW instance(s)." -ForegroundColor Gray
    foreach ($proc in $existing) {
      try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Write-Warning "Warmup: failed to stop LabVIEW PID $($proc.Id): $($_.Exception.Message)" }
    }
    Write-JsonEvent 'labview-stopped' @{ pids = ($existing.Id -join ','); reason = 'pre-existing' }
  }
  Write-Snapshot -Path $SnapshotPath
  return
}

if ($DryRun) {
  Write-Host "Warmup: dry run; LabVIEW would be launched via $LabVIEWPath." -ForegroundColor DarkGray
  return
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $LabVIEWPath
$psi.Arguments = ''
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

try { $psi.EnvironmentVariables['LV_NO_ACTIVATE'] = '1' } catch {}
try { $psi.EnvironmentVariables['LV_SUPPRESS_UI'] = '1' } catch {}
try { $psi.EnvironmentVariables['LV_CURSOR_RESTORE'] = '1' } catch {}
try { $psi.EnvironmentVariables['LV_IDLE_WAIT_SECONDS'] = [string]$IdleWaitSeconds } catch {}
try { $psi.EnvironmentVariables['LV_IDLE_MAX_WAIT_SECONDS'] = '5' } catch {}

Write-Host ("Warmup: launching LabVIEW (hidden) via {0}" -f $LabVIEWPath) -ForegroundColor Gray
Write-StepSummaryLine "- Warmup: launching LabVIEW (hidden)"
Write-JsonEvent 'spawn' @{ exe = $LabVIEWPath }

$proc = $null
try {
  $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
  Write-JsonEvent 'error' @{ stage = 'start'; message = $_.Exception.Message }
  throw
}

$deadline = (Get-Date).AddSeconds([Math]::Max(1,$TimeoutSeconds))
do {
  Start-Sleep -Milliseconds 200
  try { $existing = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue) } catch { $existing = @() }
  if ($existing.Count -gt 0) { break }
} while ((Get-Date) -lt $deadline)

if ($existing.Count -eq 0) {
  Write-Warning "Warmup: LabVIEW did not appear within $TimeoutSeconds second(s)."
  Write-JsonEvent 'timeout' @{ stage = 'spawn'; seconds = $TimeoutSeconds }
  if ($KillOnTimeout -and $proc -and -not $proc.HasExited) {
    try { $proc.Kill($true) } catch {}
  }
  return
}

Write-Host ("Warmup: LabVIEW started (PID(s): {0})" -f ($existing.Id -join ',')) -ForegroundColor Green
Write-StepSummaryLine ("- Warmup: LabVIEW running (PID(s): {0})" -f ($existing.Id -join ','))
Write-JsonEvent 'labview-detected' @{ pids = ($existing.Id -join ',') }

if ($IdleWaitSeconds -gt 0) {
  Start-Sleep -Seconds $IdleWaitSeconds
  Write-JsonEvent 'idle-gate' @{ seconds = $IdleWaitSeconds }
}

Write-Snapshot -Path $SnapshotPath

if ($StopAfterWarmup -and -not $KeepLabVIEW) {
  Write-Host "Warmup: stopping LabVIEW per StopAfterWarmup request." -ForegroundColor Gray
  foreach ($proc in $existing) {
    try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { Write-Warning "Warmup: failed to stop LabVIEW PID $($proc.Id): $($_.Exception.Message)" }
  }
  Write-JsonEvent 'labview-stopped' @{ reason = 'warmup-complete' }
} else {
  Write-JsonEvent 'warmup-complete' @{ kept = $true }
}
