<#
.SYNOPSIS
  Compatibility wrapper for Warmup-LabVIEWRuntime.ps1 (deprecated entry point).

.DESCRIPTION
  For backward compatibility, this script forwards to tools/Warmup-LabVIEWRuntime.ps1
  with a subset of parameters. New automation should call Warmup-LabVIEWRuntime.ps1
  directly.

.PARAMETER LabVIEWExePath
  Path to LabVIEW.exe (forwarded).

.PARAMETER MinimumSupportedLVVersion
  Version used to derive LabVIEW path (forwarded).

.PARAMETER SupportedBitness
  Bitness (forwarded).

.PARAMETER TimeoutSeconds
  Startup timeout (forwarded).

.PARAMETER IdleWaitSeconds
  Idle gate after detection (forwarded).

.PARAMETER JsonLogPath
  NDJSON event log path (forwarded).

.PARAMETER KillOnTimeout
  Forcibly terminate on timeout (forwarded).

.PARAMETER DryRun
  Plan only (forwarded).
#>
[CmdletBinding()]
param(
  [string]$LabVIEWPath,
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [int]$TimeoutSeconds = 30,
  [int]$IdleWaitSeconds = 2,
  [string]$JsonLogPath,
  [switch]$KillOnTimeout,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtime = Join-Path (Split-Path -Parent $PSCommandPath) 'Warmup-LabVIEWRuntime.ps1'
if (-not (Test-Path -LiteralPath $runtime -PathType Leaf)) {
  Write-Error "Warmup-LabVIEWRuntime.ps1 not found next to this script"
  exit 1
}

# Normalize bitness (fallback to env or default 64)
if ([string]::IsNullOrWhiteSpace($SupportedBitness)) {
  if ($env:LABVIEW_BITNESS) {
    $SupportedBitness = $env:LABVIEW_BITNESS
  } elseif ($env:MINIMUM_SUPPORTED_LV_BITNESS) {
    $SupportedBitness = $env:MINIMUM_SUPPORTED_LV_BITNESS
  } else {
    $SupportedBitness = '64'
  }
}
$SupportedBitness = $SupportedBitness.Trim()
if ($SupportedBitness -notin @('32','64')) {
  if ($SupportedBitness -match '32') {
    $SupportedBitness = '32'
  } elseif ($SupportedBitness -match '64') {
    $SupportedBitness = '64'
  } else {
    $SupportedBitness = '64'
  }
}

Write-Host '[deprecated] Warmup-LabVIEW.ps1 forwarding to Warmup-LabVIEWRuntime.ps1' -ForegroundColor DarkYellow

& $runtime `
  -LabVIEWPath $LabVIEWPath `
  -MinimumSupportedLVVersion $MinimumSupportedLVVersion `
  -SupportedBitness $SupportedBitness `
  -TimeoutSeconds $TimeoutSeconds `
  -IdleWaitSeconds $IdleWaitSeconds `
  -JsonLogPath $JsonLogPath `
  -KillOnTimeout:$KillOnTimeout.IsPresent `
  -DryRun:$DryRun.IsPresent

$exitCodeVar = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
$exitCode = if ($exitCodeVar) { $exitCodeVar.Value } else { 0 }
exit ([int]$exitCode)
