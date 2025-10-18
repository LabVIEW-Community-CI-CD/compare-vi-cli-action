<#
.SYNOPSIS
  Runs LVCompare.exe against two VIs to validate CLI readiness and emit diff breadcrumbs.

.DESCRIPTION
  Executes LVCompare.exe with deterministic defaults (-nobdcosm -nofppos -noattr), captures
  exit code/duration, optionally enforces expectations about diff presence, and emits NDJSON
  events for downstream observability. Intended as a lightweight readiness probe before
  expensive orchestrations or as a sample compare to generate baseline artifacts.

.PARAMETER LVCompareExePath
  Full path to LVCompare.exe. Defaults to LVCOMPARE_PATH or the canonical install path.

.PARAMETER LabVIEWExePath
  Optional LabVIEW.exe path passed to LVCompare via -lvpath. Falls back to LOOP_LABVIEW_PATH,
  LABVIEW_PATH, or the canonical LabVIEW 2025 64-bit install when available.

.PARAMETER BaseVi
  Base VI path. Defaults to LV_BASE_VI or repo-root VI1.vi.

.PARAMETER HeadVi
  Head VI path. Defaults to LV_HEAD_VI or repo-root VI2.vi.

.PARAMETER DiffArguments
  Additional arguments appended to LVCompare invocation (array). Defaults to -nobdcosm,
  -nofppos, -noattr. Pass @() to suppress.

.PARAMETER TimeoutSeconds
  Maximum time to wait for LVCompare to exit. Defaults to 60 seconds.

.PARAMETER ExpectDiff
  Assert that LVCompare reports a diff (exit code 1). Fails the script if not satisfied.

.PARAMETER ExpectNoDiff
  Assert that LVCompare reports no diff (exit code 0). Fails the script if not satisfied.

.PARAMETER KillOnTimeout
  Kill LVCompare when TimeoutSeconds elapses and the process remains running.

.PARAMETER JsonLogPath
  NDJSON event log path (schema prime-lvcompare-v1). Defaults to
  tests/results/_warmup/prime-lvcompare.ndjson when not suppressed.

.PARAMETER LeakCheck
  After run completes, check for lingering LVCompare or LabVIEW processes and emit JSON summary.

.PARAMETER LeakJsonPath
  Optional location for leak summary (defaults to tests/results/_warmup/prime-lvcompare-leak.json).

.PARAMETER LeakGraceSeconds
  Optional grace delay before leak check to reduce false positives (default 0.5 seconds).
#>
[CmdletBinding(DefaultParameterSetName='Default')]
param(
  [string]$LVCompareExePath,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [ValidateSet('32','64')][string]$LabVIEWBitness = '64',
  [string]$BaseVi,
  [string]$HeadVi,
  [string[]]$DiffArguments = @('-nobdcosm','-nofppos','-noattr'),
  [int]$TimeoutSeconds = 60,
  [switch]$ExpectDiff,
  [switch]$ExpectNoDiff,
  [switch]$KillOnTimeout,
  [string]$JsonLogPath,
  [switch]$LeakCheck,
  [string]$LeakJsonPath,
  [double]$LeakGraceSeconds = 0.5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force } catch {}

$labviewPidTrackerModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'LabVIEWPidTracker.psm1'
$labviewPidTrackerLoaded = $false
$labviewPidTrackerPath = $null
$labviewPidTrackerState = $null
$labviewPidTrackerFinalized = $false
$labviewPidTrackerFinalState = $null

if (Test-Path -LiteralPath $labviewPidTrackerModule -PathType Leaf) {
  try {
    Import-Module $labviewPidTrackerModule -Force
    $labviewPidTrackerLoaded = $true
  } catch {
    Write-Warning ("Prime-LVCompare: failed to import LabVIEW PID tracker module: {0}" -f $_.Exception.Message)
  }
}

function Initialize-LabVIEWPidTracker {
  if (-not $script:labviewPidTrackerLoaded -or $script:labviewPidTrackerState -or -not $script:labviewPidTrackerPath) { return }
  try {
    $script:labviewPidTrackerState = Start-LabVIEWPidTracker -TrackerPath $script:labviewPidTrackerPath -Source 'prime-lvcompare:init'
    if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
      $modeText = if ($script:labviewPidTrackerState.Reused) { 'Reusing existing' } else { 'Tracking detected' }
      Write-Host ("[labview-pid] {0} LabVIEW.exe PID {1}." -f $modeText, $script:labviewPidTrackerState.Pid) -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning ("Prime-LVCompare: failed to start LabVIEW PID tracker: {0}" -f $_.Exception.Message)
    $script:labviewPidTrackerLoaded = $false
    $script:labviewPidTrackerPath = $null
    $script:labviewPidTrackerState = $null
  }
}

function Finalize-LabVIEWPidTracker {
  param(
    [string]$Status,
    [Nullable[int]]$ExitCode,
    [Nullable[int]]$ProcessExitCode,
    [Nullable[bool]]$DiffDetected,
    [string]$Message,
    [string]$LabVIEWPath,
    [string]$LVComparePath,
    [Nullable[double]]$DurationMs
  )

  if (-not $script:labviewPidTrackerLoaded -or -not $script:labviewPidTrackerPath -or $script:labviewPidTrackerFinalized) { return }

  $context = [ordered]@{ stage = 'prime-lvcompare:summary' }
  if ($Status) { $context.status = $Status } else { $context.status = 'unknown' }
  if ($PSBoundParameters.ContainsKey('ExitCode') -and $ExitCode -ne $null) { $context.exitCode = [int]$ExitCode }
  if ($PSBoundParameters.ContainsKey('ProcessExitCode') -and $ProcessExitCode -ne $null) { $context.processExitCode = [int]$ProcessExitCode }
  if ($PSBoundParameters.ContainsKey('DiffDetected')) { $context.diffDetected = [bool]$DiffDetected }
  if ($PSBoundParameters.ContainsKey('DurationMs') -and $DurationMs -ne $null) { $context.durationMs = [double]$DurationMs }
  if ($PSBoundParameters.ContainsKey('LabVIEWPath') -and $LabVIEWPath) { $context.labviewPath = $LabVIEWPath }
  if ($PSBoundParameters.ContainsKey('LVComparePath') -and $LVComparePath) { $context.lvcomparePath = $LVComparePath }
  if ($PSBoundParameters.ContainsKey('Message') -and $Message) { $context.message = $Message }

  $args = @{ TrackerPath = $script:labviewPidTrackerPath; Source = 'prime-lvcompare:summary' }
  if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
    $args.Pid = $script:labviewPidTrackerState.Pid
  }
  if ($context) { $args.Context = [pscustomobject]$context }

  try {
    $script:labviewPidTrackerFinalState = Stop-LabVIEWPidTracker @args
  } catch {
    Write-Warning ("Prime-LVCompare: failed to finalize LabVIEW PID tracker: {0}" -f $_.Exception.Message)
  } finally {
    $script:labviewPidTrackerFinalized = $true
  }
}

if ($ExpectDiff.IsPresent -and $ExpectNoDiff.IsPresent) {
  throw "ExpectDiff and ExpectNoDiff are mutually exclusive."
}

function Write-JsonEvent {
  param([string]$Type,[hashtable]$Data)
  if (-not $JsonLogPath) { return }
  try {
    $dir = Split-Path -Parent $JsonLogPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $payload = [ordered]@{
      timestamp = (Get-Date).ToString('o')
      type      = $Type
      schema    = 'prime-lvcompare-v1'
    }
    if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }
    ($payload | ConvertTo-Json -Compress) | Add-Content -Path $JsonLogPath
  } catch {
    Write-Warning "Prime-LVCompare: failed to append event: $($_.Exception.Message)"
  }
}

function Write-JsonFile {
  param([string]$Path,[object]$Object)
  if (-not $Path) { return }
  try {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -Type Directory -Path $dir | Out-Null }
    $Object | ConvertTo-Json -Depth 6 | Out-File -FilePath $Path -Encoding utf8
  } catch {
    Write-Warning "Prime-LVCompare: failed to write $Path: $($_.Exception.Message)"
  }
}

if ($IsWindows -ne $true) {
  Write-JsonEvent 'skip' @{ reason = 'non-windows' }
  return
}

if (-not $JsonLogPath -and -not ($env:WARMUP_NO_JSON -eq '1')) {
  $JsonLogPath = 'tests/results/_warmup/prime-lvcompare.ndjson'
}

$repoRoot = (Resolve-Path '.').Path

$trackerBaseDir = $null
if ($JsonLogPath) {
  try { $trackerBaseDir = Split-Path -Parent $JsonLogPath } catch { $trackerBaseDir = $null }
}
if (-not $trackerBaseDir -or [string]::IsNullOrWhiteSpace($trackerBaseDir)) {
  $trackerBaseDir = 'tests/results/_warmup'
}
if (-not [System.IO.Path]::IsPathRooted($trackerBaseDir)) {
  $trackerBaseDir = Join-Path $repoRoot $trackerBaseDir
}
$labviewPidTrackerPath = Join-Path $trackerBaseDir '_agent' 'labview-pid.json'
Initialize-LabVIEWPidTracker

if (-not $BaseVi) {
  $BaseVi = if ($env:LV_BASE_VI) { $env:LV_BASE_VI } else { Join-Path $repoRoot 'VI1.vi' }
}
if (-not $HeadVi) {
  $HeadVi = if ($env:LV_HEAD_VI) { $env:LV_HEAD_VI } else { Join-Path $repoRoot 'VI2.vi' }
}

$LVCompareExePath = if ($LVCompareExePath) {
  $LVCompareExePath
} elseif ($env:LVCOMPARE_PATH) {
  $env:LVCOMPARE_PATH
} else {
  try { Resolve-LVComparePath } catch { 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' }
}

if (-not (Test-Path -LiteralPath $LVCompareExePath -PathType Leaf)) {
  Write-Warning "Prime-LVCompare: LVCompare.exe not found at $LVCompareExePath."
  Write-JsonEvent 'skip' @{ reason = 'lvcompare-missing'; path = $LVCompareExePath }
  Finalize-LabVIEWPidTracker -Status 'skipped' -ExitCode 0 -ProcessExitCode 0 -Message ("lvcompare-missing: {0}" -f $LVCompareExePath) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath
  return
}

if (-not (Test-Path -LiteralPath $BaseVi -PathType Leaf)) {
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 1 -ProcessExitCode 1 -Message ("base-vi-missing: {0}" -f $BaseVi) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath
  throw "Base VI not found at $BaseVi"
}
if (-not (Test-Path -LiteralPath $HeadVi -PathType Leaf)) {
  Finalize-LabVIEWPidTracker -Status 'error' -ExitCode 1 -ProcessExitCode 1 -Message ("head-vi-missing: {0}" -f $HeadVi) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath
  throw "Head VI not found at $HeadVi"
}

if (-not $LabVIEWExePath) {
  if ($env:LABVIEW_PATH) { $LabVIEWExePath = $env:LABVIEW_PATH }
}
if (-not $LabVIEWExePath) {
  $parent = if ($LabVIEWBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  if ($parent) { $LabVIEWExePath = Join-Path $parent 'National Instruments\LabVIEW 2025\LabVIEW.exe' }
}

Write-JsonEvent 'plan' @{
  cli      = $LVCompareExePath
  baseVi   = $BaseVi
  headVi   = $HeadVi
  lvPath   = $LabVIEWExePath
  timeout  = $TimeoutSeconds
  diffArgs = if ($DiffArguments) { ($DiffArguments -join ' ') } else { '' }
}

$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $LVCompareExePath
$args = @($BaseVi,$HeadVi)
if ($LabVIEWExePath) { $args += @('-lvpath', $LabVIEWExePath) }
if ($DiffArguments) { $args += $DiffArguments }
$psi.Arguments = ($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

Write-JsonEvent 'spawn' @{ args = $psi.Arguments }
Write-Host ("Prime-LVCompare: running `{0}` {1}" -f $LVCompareExePath, $psi.Arguments) -ForegroundColor Gray

$proc = $null
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
  $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
  Write-JsonEvent 'error' @{ stage = 'start'; message = $_.Exception.Message }
  Finalize-LabVIEWPidTracker -Status 'error' -Message $_.Exception.Message -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath
  throw
}

$completed = $proc.WaitForExit([Math]::Max(1,$TimeoutSeconds) * 1000)
if (-not $completed) {
  Write-Warning "Prime-LVCompare: LVCompare.exe (PID $($proc.Id)) did not exit within $TimeoutSeconds second(s)."
  Write-JsonEvent 'timeout' @{ seconds = $TimeoutSeconds; pid = $proc.Id }
  if ($KillOnTimeout) {
    try { $proc.Kill($true) } catch {}
  }
  $timeoutExit = $null
  try { $timeoutExit = $proc.ExitCode } catch { $timeoutExit = $null }
  Finalize-LabVIEWPidTracker -Status 'timeout' -ExitCode $timeoutExit -ProcessExitCode $timeoutExit -Message ("timeout-after {0}s" -f $TimeoutSeconds) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath
  throw "LVCompare did not complete before timeout."
}
$stopwatch.Stop()

$exitCode = $proc.ExitCode
$diffDetected = ($exitCode -eq 1)
$durationMs = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds,2)

Write-JsonEvent 'result' @{
  exitCode     = $exitCode
  diffDetected = $diffDetected
  durationMs   = $durationMs
}

if ($ExpectDiff -and -not $diffDetected) {
  Write-JsonEvent 'assertion' @{ expected = 'diff'; actual = 'no-diff'; exitCode = $exitCode }
  Finalize-LabVIEWPidTracker -Status 'assertion-failed' -ExitCode $exitCode -ProcessExitCode $exitCode -DiffDetected $diffDetected -Message ("expected-diff exit:{0}" -f $exitCode) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath -DurationMs $durationMs
  throw "Prime-LVCompare expected a diff but LVCompare exit code was $exitCode."
}
if ($ExpectNoDiff -and $diffDetected) {
  Write-JsonEvent 'assertion' @{ expected = 'no-diff'; actual = 'diff'; exitCode = $exitCode }
  Finalize-LabVIEWPidTracker -Status 'assertion-failed' -ExitCode $exitCode -ProcessExitCode $exitCode -DiffDetected $diffDetected -Message ("expected-no-diff exit:{0}" -f $exitCode) -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath -DurationMs $durationMs
  throw "Prime-LVCompare expected no diff but LVCompare exit code was $exitCode."
}

$finalStatus = if ($diffDetected) { 'diff' } else { 'ok' }
Finalize-LabVIEWPidTracker -Status $finalStatus -ExitCode $exitCode -ProcessExitCode $exitCode -DiffDetected $diffDetected -DurationMs $durationMs -LabVIEWPath $LabVIEWExePath -LVComparePath $LVCompareExePath

if ($LeakCheck) {
  if (-not $LeakJsonPath -and -not ($env:WARMUP_NO_JSON -eq '1')) {
    $LeakJsonPath = 'tests/results/_warmup/prime-lvcompare-leak.json'
  }
  if ($LeakGraceSeconds -gt 0) { Start-Sleep -Seconds $LeakGraceSeconds }
  $lvcomparePids = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $labviewPids = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $payload = [ordered]@{
    schema = 'prime-lvcompare-leak/v1'
    at     = (Get-Date).ToString('o')
    lvcompare = @{
      remaining = $lvcomparePids
      count     = ($lvcomparePids | Measure-Object).Count
    }
    labview = @{
      remaining = $labviewPids
      count     = ($labviewPids | Measure-Object).Count
    }
  }
  Write-JsonFile -Path $LeakJsonPath -Object $payload
  Write-JsonEvent 'leak-check' @{ lvcompareCount = $payload.lvcompare.count; labviewCount = $payload.labview.count }
}

$result = [pscustomobject]@{
  ExitCode     = $exitCode
  DiffDetected = $diffDetected
  DurationMs   = $durationMs
  LVCompare    = $LVCompareExePath
  LabVIEW      = $LabVIEWExePath
  BaseVi       = $BaseVi
  HeadVi       = $HeadVi
}

$trackerConsoleLine = $null
if ($labviewPidTrackerPath) {
  $trackerConsoleLine = "LabVIEW PID Tracker recorded at $labviewPidTrackerPath"
  Write-Host $trackerConsoleLine -ForegroundColor DarkGray
}

$result
exit $exitCode
