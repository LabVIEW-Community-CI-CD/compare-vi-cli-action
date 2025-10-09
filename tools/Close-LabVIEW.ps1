<# 
.SYNOPSIS
  Gracefully closes a running LabVIEW instance using g-cli.

.DESCRIPTION
  Invokes g-cli's QuitLabVIEW command for the requested LabVIEW version
  and bitness. Defaults are sourced from environment variables when the
  parameters are not provided explicitly.

.PARAMETER MinimumSupportedLVVersion
  LabVIEW version to target (for example: 2025, 2023Q3). Falls back to the
  first populated value among LOOP_LABVIEW_VERSION, LABVIEW_VERSION,
  MINIMUM_SUPPORTED_LV_VERSION and defaults to 2025 when none are provided.

.PARAMETER SupportedBitness
  Bitness of the LabVIEW instance (32 or 64). Defaults to the first populated
  value among LOOP_LABVIEW_BITNESS, LABVIEW_BITNESS, MINIMUM_SUPPORTED_LV_BITNESS,
  finally 64 if none are provided.
#>
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [ValidateSet('32','64')]
  [string]$SupportedBitness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$defaultLabVIEWVersion = '2025'
$defaultLabVIEWBitness = '64'

if (-not $MinimumSupportedLVVersion) {
  $MinimumSupportedLVVersion = @(
    $env:LOOP_LABVIEW_VERSION,
    $env:LABVIEW_VERSION,
    $env:MINIMUM_SUPPORTED_LV_VERSION
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $MinimumSupportedLVVersion) {
    $MinimumSupportedLVVersion = $defaultLabVIEWVersion
  }
}

if (-not $SupportedBitness) {
  $SupportedBitness = @(
    $env:LOOP_LABVIEW_BITNESS,
    $env:LABVIEW_BITNESS,
    $env:MINIMUM_SUPPORTED_LV_BITNESS
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $SupportedBitness) { $SupportedBitness = $defaultLabVIEWBitness }
}

if (-not (Get-Command -Name 'g-cli' -ErrorAction SilentlyContinue)) {
  Write-Warning 'Close-LabVIEW.ps1 skipped: g-cli executable not found on PATH.'
  return
}

$arguments = @('--lv-ver', $MinimumSupportedLVVersion)
if ($SupportedBitness) { $arguments += @('--arch', $SupportedBitness) }
$arguments += 'QuitLabVIEW'

Write-Host ("[Close-LabVIEW] Invoking g-cli for LabVIEW {0} ({1}-bit)" -f $MinimumSupportedLVVersion, $SupportedBitness) -ForegroundColor DarkGray

try {
  & 'g-cli' @arguments
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    throw "g-cli exited with code $code"
  }
  Write-Host "[Close-LabVIEW] LabVIEW shutdown command completed successfully." -ForegroundColor DarkGreen
} catch {
  Write-Error ("Close-LabVIEW.ps1 failed: {0}" -f $_.Exception.Message)
  exit 1
}
