<#
.SYNOPSIS
  Deterministic LabVIEW runtime warmup for self-hosted Windows runners.

.DESCRIPTION
  Primes the LabVIEW runtime without launching LabVIEW.exe directly. Uses
  LVCompare (via tools/Prime-LVCompare.ps1) to warm shared components, emits
  NDJSON breadcrumbs, and optionally stops any pre-existing LabVIEW processes.
  Designed to run outside of GitHub-hosted agents.

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
  Retained for backwards compatibility; with the LVCompare strategy this flag
  currently has no effect because LabVIEW is not started directly.

.PARAMETER StopAfterWarmup
  When pre-existing LabVIEW processes are detected, request that they be stopped
  once warmup completes. Has no effect when no LabVIEW process exists.

.PARAMETER JsonLogPath
  NDJSON event log path (schema warmup-labview-v1). Defaults to
  tests/results/_warmup/labview-runtime.ndjson when not suppressed.

.PARAMETER SnapshotPath
  Optional JSON snapshot file capturing LabVIEW processes. Defaults to
  tests/results/_warmup/labview-processes.json.

.PARAMETER SkipSnapshot
  Skip process snapshot emission.

.PARAMETER DryRun
  Compute the warmup plan and emit events without invoking LVCompare.

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
  strategy   = 'lvcompare-prime'
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

if ($KeepLabVIEW) {
  Write-JsonEvent 'notice' @{ message = 'KeepLabVIEW flag ignored; LVCompare prime does not start LabVIEW.' }
}

if ($StopAfterWarmup) {
  Write-JsonEvent 'notice' @{ message = 'StopAfterWarmup has no effect; LVCompare prime does not leave LabVIEW running.' }
}

if ($DryRun) {
  Write-Host "Warmup: dry run; LVCompare prime would execute via Prime-LVCompare.ps1." -ForegroundColor DarkGray
  Write-JsonEvent 'skip' @{ reason = 'dry-run'; strategy = 'lvcompare-prime' }
  return
}

$primeScript = if ($env:WARMUP_PRIME_SCRIPT -and (Test-Path -LiteralPath $env:WARMUP_PRIME_SCRIPT -PathType Leaf)) {
  $env:WARMUP_PRIME_SCRIPT
} else {
  Join-Path (Split-Path -Parent $PSCommandPath) 'Prime-LVCompare.ps1'
}
if (-not (Test-Path -LiteralPath $primeScript -PathType Leaf)) {
  Write-Warning "Warmup-LabVIEWRuntime: Prime-LVCompare.ps1 not found at $primeScript."
  Write-JsonEvent 'skip' @{ reason = 'prime-script-missing'; path = $primeScript }
  return
}

$repoRoot = (Resolve-Path '.').Path
$baseVi = if ($env:LV_BASE_VI) { $env:LV_BASE_VI } else { Join-Path $repoRoot 'VI1.vi' }
$headVi = if ($env:LV_HEAD_VI) { $env:LV_HEAD_VI } else { Join-Path $repoRoot 'VI2.vi' }

if (-not (Test-Path -LiteralPath $baseVi -PathType Leaf)) {
  Write-Warning "Warmup-LabVIEWRuntime: Base VI not found at $baseVi."
  Write-JsonEvent 'skip' @{ reason = 'base-vi-missing'; path = $baseVi }
  return
}
if (-not (Test-Path -LiteralPath $headVi -PathType Leaf)) {
  Write-Warning "Warmup-LabVIEWRuntime: Head VI not found at $headVi; falling back to base VI."
  $headVi = $baseVi
}

Write-Host "Warmup: running LVCompare prime to warm LabVIEW runtime (no direct LabVIEW launch)." -ForegroundColor Gray
Write-StepSummaryLine "- Warmup: running LVCompare prime"
Write-JsonEvent 'prime-start' @{
  script = $primeScript
  baseVi = $baseVi
  headVi = $headVi
}

$primeParams = [ordered]@{
  BaseVi        = $baseVi
  HeadVi        = $headVi
  LabVIEWBitness = $SupportedBitness
  ExpectNoDiff  = $true
  LeakCheck     = $true
}
if ($LabVIEWPath) { $primeParams['LabVIEWExePath'] = $LabVIEWPath }
if ($KillOnTimeout) { $primeParams['KillOnTimeout'] = $true }

$primeArgsForLog = @()
foreach ($entry in $primeParams.GetEnumerator()) {
  if ($entry.Value -is [bool]) {
    if ($entry.Value) { $primeArgsForLog += "-$($entry.Key)" }
  } else {
    $primeArgsForLog += "-$($entry.Key)"
    $primeArgsForLog += $entry.Value
  }
}
Write-Host ("Warmup: prime args -> {0}" -f ($primeArgsForLog -join ' ')) -ForegroundColor DarkGray
Write-JsonEvent 'prime-args' @{ args = ($primeArgsForLog -join ' ') }

try {
  & $primeScript @primeParams | Out-Null
  $primeExit = $LASTEXITCODE
  Write-JsonEvent 'prime-exit' @{ exitCode = $primeExit }
  if ($primeExit -ne 0) {
    throw "Prime-LVCompare exited with code $primeExit"
  }
} catch {
  Write-JsonEvent 'error' @{ stage = 'prime'; message = $_.Exception.Message }
  throw
}

Write-Snapshot -Path $SnapshotPath
Write-JsonEvent 'warmup-complete' @{ kept = $false; strategy = 'lvcompare-prime' }
