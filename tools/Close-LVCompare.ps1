<#
.SYNOPSIS
  Runs LVCompare.exe against a pair of VIs using an explicit LabVIEW executable path (default: LabVIEW 2025 64-bit) and ensures the compare process exits.

.DESCRIPTION
  Mirrors the environment-first pattern used by Close-LabVIEW.ps1. The script resolves the LVCompare
  CLI path (default canonical install), derives the LabVIEW executable path from parameters or environment
  variables, then launches LVCompare.exe with deterministic switches (`-nobdcosm -nofppos -noattr`). It waits
  for the process to exit within the requested timeout, optionally killing the process on timeout, and emits
  a small result object summarising the invocation.

.PARAMETER LabVIEWExePath
  Full path to the LabVIEW executable to hand off to LVCompare via `-lvpath`. When omitted, the script
  derives the value from `LOOP_LABVIEW_PATH`, `LABVIEW_PATH`, `LABVIEW_EXE`, or constructs a canonical
  install path based on `MinimumSupportedLVVersion` (default 2025) and `SupportedBitness` (default 64-bit).

.PARAMETER MinimumSupportedLVVersion
  LabVIEW version used when deriving `LabVIEWExePath` (for example: 2025, 2025Q3). Defaults to the first
  value among `LOOP_LABVIEW_VERSION`, `LABVIEW_VERSION`, `MINIMUM_SUPPORTED_LV_VERSION`, or 2025.

.PARAMETER SupportedBitness
  LabVIEW bitness used when deriving `LabVIEWExePath`. Defaults to the first populated value among
  `LOOP_LABVIEW_BITNESS`, `LABVIEW_BITNESS`, `MINIMUM_SUPPORTED_LV_BITNESS`, or 64.

.PARAMETER LVComparePath
  Full path to LVCompare.exe. Defaults to the first populated value among `LVCOMPARE_PATH`,
  `LV_COMPARE_PATH`, or the canonical path `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`.

.PARAMETER BaseVi
  Base VI to pass to LVCompare. Defaults to `LV_BASE_VI`, then repo-root `VI1.vi`.

.PARAMETER HeadVi
  Head VI to pass to LVCompare. Defaults to `LV_HEAD_VI`, then repo-root `VI2.vi`.

.PARAMETER AdditionalArguments
  Extra arguments appended to the LVCompare invocation (after the default switches).

.PARAMETER TimeoutSeconds
  Maximum wait time for LVCompare.exe to exit. Defaults to 60 seconds.

.PARAMETER KillOnTimeout
  When supplied, terminates the LVCompare process if it is still running after the timeout window.
  Without this flag the script emits an error and leaves the process untouched.

.PARAMETER SkipDefaultFlags
  Disables automatic inclusion of `-nobdcosm -nofppos -noattr`.

.OUTPUTS
  Writes a PSCustomObject describing the invocation (`exitCode`, `lvComparePath`, `labVIEWPath`, `arguments`, `elapsedSeconds`).
  The PowerShell `$LASTEXITCODE` is set to the LVCompare process exit code (or 1 on error).
#>
[CmdletBinding()]
param(
  [string]$LabVIEWExePath,
  [string]$MinimumSupportedLVVersion,
  [ValidateSet('32','64')]
  [string]$SupportedBitness,
  [string]$LVComparePath,
  [string]$BaseVi,
  [string]$HeadVi,
  [string[]]$AdditionalArguments,
  [int]$TimeoutSeconds = 60,
  [switch]$KillOnTimeout,
  [switch]$SkipDefaultFlags
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FirstValue {
  param([string[]]$Values)
  foreach ($value in $Values) {
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
  }
  return $null
}

try {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
} catch {
  $repoRoot = (Get-Location).Path
}

$defaultLvComparePath = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
$defaultVersion = '2025'
$defaultBitness = '64'

$LVComparePath = Get-FirstValue @(
  $LVComparePath,
  $env:LVCOMPARE_PATH,
  $env:LV_COMPARE_PATH,
  $defaultLvComparePath
)
if (-not (Test-Path -LiteralPath $LVComparePath -PathType Leaf)) {
  throw "LVCompare.exe not found at '$LVComparePath'. Provide -LVComparePath or set LVCOMPARE_PATH."
}

$MinimumSupportedLVVersion = Get-FirstValue @(
  $MinimumSupportedLVVersion,
  $env:LOOP_LABVIEW_VERSION,
  $env:LABVIEW_VERSION,
  $env:MINIMUM_SUPPORTED_LV_VERSION,
  $defaultVersion
)
$SupportedBitness = Get-FirstValue @(
  $SupportedBitness,
  $env:LOOP_LABVIEW_BITNESS,
  $env:LABVIEW_BITNESS,
  $env:MINIMUM_SUPPORTED_LV_BITNESS,
  $defaultBitness
)
if (-not $SupportedBitness) { $SupportedBitness = $defaultBitness }

$LabVIEWExePath = Get-FirstValue @(
  $LabVIEWExePath,
  $env:LOOP_LABVIEW_PATH,
  $env:LABVIEW_PATH,
  $env:LABVIEW_EXE,
  $env:LV_LABVIEW_PATH,
  $env:LV_LABVIEW_EXE
)
if (-not $LabVIEWExePath) {
  $parent = if ($SupportedBitness -eq '32') {
    ${env:ProgramFiles(x86)}
  } else {
    ${env:ProgramFiles}
  }
  if (-not $parent) {
    throw "Unable to resolve Program Files directory for bitness '$SupportedBitness'."
  }
  $LabVIEWExePath = Join-Path $parent ("National Instruments\LabVIEW $MinimumSupportedLVVersion\LabVIEW.exe")
}
if (-not (Test-Path -LiteralPath $LabVIEWExePath -PathType Leaf)) {
  throw "LabVIEW executable not found at '$LabVIEWExePath'. Provide -LabVIEWExePath or set LABVIEW_PATH to avoid using a default that may launch the wrong version."
}

$BaseVi = Get-FirstValue @(
  $BaseVi,
  $env:LV_BASE_VI,
  (Join-Path $repoRoot 'VI1.vi')
)
$HeadVi = Get-FirstValue @(
  $HeadVi,
  $env:LV_HEAD_VI,
  (Join-Path $repoRoot 'VI2.vi')
)

if (-not (Test-Path -LiteralPath $BaseVi -PathType Leaf)) { throw "Base VI not found: $BaseVi" }
if (-not (Test-Path -LiteralPath $HeadVi -PathType Leaf)) { throw "Head VI not found: $HeadVi" }

$arguments = @($BaseVi, $HeadVi, '-lvpath', $LabVIEWExePath)
if (-not $SkipDefaultFlags) {
  $arguments += @('-nobdcosm','-nofppos','-noattr')
}
if ($AdditionalArguments) { $arguments += $AdditionalArguments }

Write-Host ("[Close-LVCompare] LVCompare: {0}" -f $LVComparePath) -ForegroundColor DarkGray
Write-Host ("[Close-LVCompare] LabVIEW : {0}" -f $LabVIEWExePath) -ForegroundColor DarkGray
Write-Host ("[Close-LVCompare] Base/Head: {0} ⇔ {1}" -f $BaseVi, $HeadVi) -ForegroundColor DarkGray

$process = $null
$completed = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
  $process = Start-Process -FilePath $LVComparePath -ArgumentList $arguments -PassThru -WindowStyle Hidden
  $completed = $process.WaitForExit([Math]::Max(1,$TimeoutSeconds) * 1000)
  if (-not $completed) {
    if ($KillOnTimeout) {
      try {
        $process.Kill($true)
      } catch {
        Write-Warning "Failed to terminate LVCompare process (PID $($process.Id)) after timeout: $($_.Exception.Message)"
      }
    }
    throw "LVCompare.exe (PID $($process.Id)) did not exit within $TimeoutSeconds second(s)."
  }
  $exitCode = $process.ExitCode
} finally {
  $sw.Stop()
}

try {
  $remaining = @(Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue)
  if ($remaining.Count -gt 0) {
    Write-Warning ("Remaining LVCompare.exe process(es) detected after run: {0}" -f ($remaining.Id -join ','))
  }
} catch {}

$result = [pscustomobject]@{
  exitCode       = $exitCode
  lvComparePath  = $LVComparePath
  labVIEWPath    = $LabVIEWExePath
  baseVi         = $BaseVi
  headVi         = $HeadVi
  arguments      = $arguments
  elapsedSeconds = [Math]::Round($sw.Elapsed.TotalSeconds,3)
}

$result
exit $exitCode
