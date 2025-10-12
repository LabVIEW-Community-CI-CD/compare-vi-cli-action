<#
.SYNOPSIS
  Deterministic driver for LVCompare.exe with capture and optional HTML report.

.DESCRIPTION
  Wraps the repository's capture pipeline to run LVCompare against two VIs with
  stable arguments, explicit LabVIEW selection via -lvpath, and NDJSON crumbs.
  Produces standard artifacts under the chosen OutputDir:
    - lvcompare-capture.json (schema lvcompare-capture-v1)
    - compare-report.html (when -RenderReport)
    - lvcompare-stdout.txt / lvcompare-stderr.txt / lvcompare-exitcode.txt

.PARAMETER BaseVi
  Path to the base VI.

.PARAMETER HeadVi
  Path to the head VI.

.PARAMETER LabVIEWExePath
  Path to the LabVIEW executable handed to LVCompare via -lvpath. Defaults to
  LabVIEW 2025 64-bit canonical path when not provided and env overrides are absent.
  Alias: -LabVIEWPath (legacy).

.PARAMETER LVComparePath
  Optional explicit LVCompare.exe path. Defaults to canonical install or LVCOMPARE_PATH when omitted.

.PARAMETER Flags
  Additional LVCompare flags. Defaults to -nobdcosm -nofppos -noattr unless
  -ReplaceFlags is used.

.PARAMETER ReplaceFlags
  Replace default flags entirely with the provided -Flags.

.PARAMETER OutputDir
  Target directory for artifacts (default: tests/results/single-compare).

.PARAMETER RenderReport
  Emit compare-report.html (default: enabled).

.PARAMETER JsonLogPath
  NDJSON crumb log (schema prime-lvcompare-v1 compatible): spawn/result/paths.

.PARAMETER Quiet
  Reduce console noise from the capture script.

.PARAMETER LeakCheck
  After run, record remaining LVCompare/LabVIEW PIDs in a JSON summary.

.PARAMETER LeakJsonPath
  Optional path for leak summary JSON (default tests/results/single-compare/compare-leak.json).

.PARAMETER CaptureScriptPath
  Optional path to an alternate Capture-LVCompare.ps1 implementation (primarily for tests).

.PARAMETER Summary
  When set, prints a concise human-readable outcome and appends to $GITHUB_STEP_SUMMARY when available.

.PARAMETER LeakGraceSeconds
  Optional grace delay before leak check to reduce false positives (default 0.5 seconds).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BaseVi,
  [Parameter(Mandatory=$true)][string]$HeadVi,
  [Alias('LabVIEWPath')]
  [string]$LabVIEWExePath,
  [ValidateSet('32','64')][string]$LabVIEWBitness = '64',
  [Alias('LVCompareExePath')]
  [string]$LVComparePath,
[string[]]$Flags,
[switch]$ReplaceFlags,
[string]$OutputDir = 'tests/results/single-compare',
[switch]$RenderReport,
[string]$JsonLogPath,
[switch]$Quiet,
[switch]$LeakCheck,
[string]$LeakJsonPath,
[string]$CaptureScriptPath,
[switch]$Summary,
[double]$LeakGraceSeconds = 0.5,
[int]$TimeoutSeconds = 60,
[switch]$KillOnTimeout,
[switch]$CloseOnComplete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'VendorTools.psm1') -Force } catch {}

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
  } catch { Write-Warning "Invoke-LVCompare: failed to append event: $($_.Exception.Message)" }
}

function New-DirIfMissing([string]$Path) { if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

$repoRoot = (Resolve-Path '.').Path
New-DirIfMissing -Path $OutputDir

# Resolve LabVIEW path (prefer explicit/env LABVIEW_PATH; fallback to 2025 canonical by bitness)
if (-not $LabVIEWExePath) {
  if ($env:LABVIEW_PATH) { $LabVIEWExePath = $env:LABVIEW_PATH }
}
if (-not $LabVIEWExePath) {
  $parent = if ($LabVIEWBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  if ($parent) { $LabVIEWExePath = Join-Path $parent 'National Instruments\LabVIEW 2025\LabVIEW.exe' }
}
if (-not $LabVIEWExePath -or -not (Test-Path -LiteralPath $LabVIEWExePath -PathType Leaf)) {
  $expectedParent = if ($LabVIEWBitness -eq '32') { ${env:ProgramFiles(x86)} } else { ${env:ProgramFiles} }
  $expected = if ($expectedParent) { Join-Path $expectedParent 'National Instruments\LabVIEW 2025\LabVIEW.exe' } else { '(unknown ProgramFiles)' }
  Write-Error ("Invoke-LVCompare: LabVIEWExePath could not be resolved. Set LABVIEW_PATH or pass -LabVIEWExePath. Expected canonical for bitness {0}: {1}" -f $LabVIEWBitness, $expected)
  exit 2
}

# Compose flags list: -lvpath then normalization flags
$defaultFlags = @('-nobdcosm','-nofppos','-noattr')
$effectiveFlags = @()
if ($LabVIEWExePath) { $effectiveFlags += @('-lvpath', $LabVIEWExePath) }
if ($ReplaceFlags.IsPresent) {
  if ($Flags) { $effectiveFlags += $Flags }
} else {
  $effectiveFlags += $defaultFlags
  if ($Flags) { $effectiveFlags += $Flags }
}

Write-JsonEvent 'plan' @{
  base      = $BaseVi
  head      = $HeadVi
  lvpath    = $LabVIEWExePath
  lvcompare = $LVComparePath
  flags     = ($effectiveFlags -join ' ')
  out       = $OutputDir
  report    = $RenderReport.IsPresent
}

# Invoke the repository capture script in-process
if ($CaptureScriptPath) {
  $captureScript = $CaptureScriptPath
} else {
  $captureScript = Join-Path $repoRoot 'scripts' 'Capture-LVCompare.ps1'
}
if (-not (Test-Path -LiteralPath $captureScript -PathType Leaf)) { throw "Capture-LVCompare.ps1 not found at $captureScript" }

try {
  $captureParams = @{
    Base         = $BaseVi
    Head         = $HeadVi
    LvArgs       = $effectiveFlags
    RenderReport = $RenderReport.IsPresent
    OutputDir    = $OutputDir
    Quiet        = $Quiet.IsPresent
    ReportStagingDir = (Join-Path $OutputDir (Join-Path '_staging' 'compare'))
  }
  # Derive CI-aware defaults when not explicitly provided
  $isCI = ($env:GITHUB_ACTIONS -eq 'true' -or $env:CI -eq 'true')
  $effectiveTimeout = $TimeoutSeconds
  $effectiveKill    = if ($PSBoundParameters.ContainsKey('KillOnTimeout')) { $KillOnTimeout.IsPresent } else { $isCI }
  $effectiveClose   = if ($PSBoundParameters.ContainsKey('CloseOnComplete')) { $CloseOnComplete.IsPresent } else { $isCI }
  $captureParams.TimeoutSeconds = [int]$effectiveTimeout
  if ($effectiveKill)    { $captureParams.KillOnTimeout   = $true }
  if ($effectiveClose)   { $captureParams.CloseOnComplete = $true }
  if (-not $LVComparePath) {
    try { $LVComparePath = Resolve-LVComparePath } catch {}
  }
  if ($LVComparePath) { $captureParams.LvComparePath = $LVComparePath }
  & $captureScript @captureParams
} catch {
  Write-JsonEvent 'error' @{ stage='capture'; message=$_.Exception.Message }
  throw
}

# Read capture JSON to surface exit code and command
$capPath = Join-Path $OutputDir 'lvcompare-capture.json'
if (-not (Test-Path -LiteralPath $capPath -PathType Leaf)) { Write-JsonEvent 'error' @{ stage='post'; message='missing capture json' }; exit 2 }
$cap = Get-Content -LiteralPath $capPath -Raw | ConvertFrom-Json
if (-not $cap) { Write-JsonEvent 'error' @{ stage='post'; message='unable to parse capture json' }; exit 2 }

$exitCode = [int]$cap.exitCode
$duration = [double]$cap.seconds
$reportPathStaging = Join-Path $OutputDir (Join-Path '_staging' 'compare' 'compare-report.html')
Write-JsonEvent 'result' @{ exitCode=$exitCode; seconds=$duration; command=$cap.command; reportStaging=(Test-Path $reportPathStaging) }

if ($LeakCheck) {
  if (-not $LeakJsonPath) { $LeakJsonPath = Join-Path $OutputDir 'compare-leak.json' }
  if ($LeakGraceSeconds -gt 0) { Start-Sleep -Seconds $LeakGraceSeconds }
  $lvcomparePids = @(); $labviewPids = @()
  try { $lvcomparePids = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  try { $labviewPids   = @(Get-Process -Name 'LabVIEW'   -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id) } catch {}
  $leak = [ordered]@{
    schema = 'prime-lvcompare-leak/v1'
    at     = (Get-Date).ToString('o')
    lvcompare = @{ remaining=$lvcomparePids; count=($lvcomparePids|Measure-Object).Count }
    labview   = @{ remaining=$labviewPids;   count=($labviewPids  |Measure-Object).Count }
  }
  $dir = Split-Path -Parent $LeakJsonPath; if ($dir -and -not (Test-Path $dir)) { New-DirIfMissing -Path $dir }
  $leak | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $LeakJsonPath -Encoding utf8
  Write-JsonEvent 'leak-check' @{ lvcompareCount=$leak.lvcompare.count; labviewCount=$leak.labview.count; path=$LeakJsonPath }
}

if ($Summary) {
  $line = "Compare Outcome: exit=$exitCode diff=$([bool]($exitCode -eq 1)) seconds=$duration"
  Write-Host $line -ForegroundColor Yellow
  if ($env:GITHUB_STEP_SUMMARY) {
    try {
      $lines = @('## Compare Outcome')
      $lines += ("- Exit: {0}" -f $exitCode)
      $lines += ("- Diff: {0}" -f ([bool]($exitCode -eq 1)))
      $lines += ("- Duration: {0}s" -f $duration)
      $lines += ("- Capture: {0}" -f $capPath)
      $lines += ("- Report (staging): {0}" -f (Test-Path $reportPathStaging))
      Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8
    } catch { Write-Warning ("Invoke-LVCompare: failed step summary append: {0}" -f $_.Exception.Message) }
  }
}

exit $exitCode
