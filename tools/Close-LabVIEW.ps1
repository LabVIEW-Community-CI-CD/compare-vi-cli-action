<#
.SYNOPSIS
  Entry point to close LabVIEW using either LabVIEW CLI or g-cli (auto, labview-cli, or g-cli).

.DESCRIPTION
  Prefers the selected mode (or auto selection) to gracefully shut down LabVIEW
  in a non-interactive way. Performs quick policy checks (version/bitness) when
  using LabVIEW CLI. Fails fast with clear exit codes.

.PARAMETER MinimumSupportedLVVersion
  LabVIEW version to target (e.g., 2025, 2023Q3). Defaults to the first populated value
  among LOOP_LABVIEW_VERSION, LABVIEW_VERSION, MINIMUM_SUPPORTED_LV_VERSION; falls back to 2025.

.PARAMETER SupportedBitness
  Bitness (32 or 64). Defaults from LOOP_LABVIEW_BITNESS, LABVIEW_BITNESS,
  MINIMUM_SUPPORTED_LV_BITNESS; falls back to 64.

.PARAMETER CloseMode
  One of: auto | labview-cli | g-cli. Default: auto (prefers g-cli when available, else labview-cli).

.PARAMETER TimeoutSeconds
  Max seconds to wait for the close command to complete (default: 30).

.PARAMETER ForceKillAfterSeconds
  Optional best-effort kill window after a graceful close attempt times out (default: 0 = disabled).

.EXITCODES
  0 closed/ok; 2 not-running; 3 timeout; 4 tool-missing; 5 policy-mismatch; 1 other error.
#>
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [ValidateSet('32','64')]
  [string]$SupportedBitness,
  [ValidateSet('auto','labview-cli','g-cli')]
  [string]$CloseMode,
  [int]$TimeoutSeconds,
  [int]$ForceKillAfterSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EnvOr([string]$name,[string]$fallback){
  $v = $null; try { $v = [Environment]::GetEnvironmentVariable($name) } catch {}
  if ($null -ne $v -and "$v" -ne '') { return "$v" } else { return $fallback }
}

$defaultLabVIEWVersion = '2025'
$defaultLabVIEWBitness = '64'
$CloseMode = if ($CloseMode) { $CloseMode } else { (Get-EnvOr 'CLOSE_MODE' 'auto') }
$TimeoutSeconds = if ($TimeoutSeconds -gt 0) { $TimeoutSeconds } else { ([int](Get-EnvOr 'CLOSE_TIMEOUT_SECONDS' '30')) }
$ForceKillAfterSeconds = if ($ForceKillAfterSeconds -ge 0) { $ForceKillAfterSeconds } else { ([int](Get-EnvOr 'CLOSE_FORCEKILL_SECONDS' '0')) }

if (-not $MinimumSupportedLVVersion) {
  $MinimumSupportedLVVersion = @(
    $env:LOOP_LABVIEW_VERSION,
    $env:LABVIEW_VERSION,
    $env:MINIMUM_SUPPORTED_LV_VERSION
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $MinimumSupportedLVVersion) { $MinimumSupportedLVVersion = $defaultLabVIEWVersion }
}
if (-not $SupportedBitness) {
  $SupportedBitness = @(
    $env:LOOP_LABVIEW_BITNESS,
    $env:LABVIEW_BITNESS,
    $env:MINIMUM_SUPPORTED_LV_BITNESS
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $SupportedBitness) { $SupportedBitness = $defaultLabVIEWBitness }
}

function Resolve-GCliPath {
  if ($env:GCLI_PATH -and (Test-Path -LiteralPath $env:GCLI_PATH -PathType Leaf)) { return (Resolve-Path -LiteralPath $env:GCLI_PATH).Path }
  foreach ($name in @('g-cli','gcli','g-cli.exe','gcli.exe')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
  }
  return $null
}

function Resolve-LabVIEWCliPath {
  if ($env:LABVIEW_CLI_PATH -and (Test-Path -LiteralPath $env:LABVIEW_CLI_PATH -PathType Leaf)) { return (Resolve-Path -LiteralPath $env:LABVIEW_CLI_PATH).Path }
  $roots = @()
  if ($env:ProgramFiles)    { $roots += (Join-Path $env:ProgramFiles 'National Instruments') }
  if ($env:ProgramFiles(x86)) { $roots += (Join-Path $env:ProgramFiles(x86) 'National Instruments') }
  foreach ($r in $roots) {
    try {
      $dirs = Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'LabVIEW*' }
      foreach ($d in $dirs) {
        $p = Join-Path $d.FullName 'LabVIEWCLI.exe'
        if (Test-Path -LiteralPath $p -PathType Leaf) { return (Resolve-Path -LiteralPath $p).Path }
      }
    } catch {}
  }
  return $null
}

function Wait-ForExitOrTimeout([System.Diagnostics.Process]$proc,[int]$seconds){
  if ($seconds -le 0) { $seconds = 30 }
  return $proc.WaitForExit($seconds * 1000)
}

# Quick not-running detection
$running = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
if (-not $running -or $running.Count -eq 0) {
  Write-Host '[Close-LabVIEW] LabVIEW is not running.' -ForegroundColor DarkGray
  exit 2
}

function Close-With-GCli {
  param([string]$Version,[string]$Arch,[int]$Timeout,[int]$ForceKillSec)
  $g = Resolve-GCliPath
  if (-not $g) { return @{ ok=$false; code=4; msg='g-cli not found' } }
  $args = @('--lv-ver', $Version)
  if ($Arch) { $args += @('--arch', $Arch) }
  $args += 'QuitLabVIEW'
  Write-Host ("[Close-LabVIEW] g-cli {0} ({1}-bit)" -f $Version, $Arch) -ForegroundColor DarkGray
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $g
  foreach ($a in $args) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::new(); $p.StartInfo = $psi; $null = $p.Start()
  $ok = Wait-ForExitOrTimeout $p $Timeout
  if (-not $ok) {
    if ($ForceKillSec -gt 0) {
      Start-Sleep -Seconds $ForceKillSec
      try { Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    }
    return @{ ok=$false; code=3; msg='g-cli timeout' }
  }
  $exit = $p.ExitCode
  if ($exit -ne 0) { return @{ ok=$false; code=1; msg=("g-cli exit {0}" -f $exit) } }
  return @{ ok=$true; code=0; msg='ok' }
}

function Close-With-LabVIEWCli {
  param([string]$Version,[string]$Arch,[int]$Timeout,[int]$ForceKillSec)
  $cli = Resolve-LabVIEWCliPath
  if (-not $cli) { return @{ ok=$false; code=4; msg='LabVIEWCLI.exe not found' } }
  # Policy/version checks (best-effort)
  try { pwsh -File (Join-Path $PSScriptRoot 'Validate-LVComparePreflight.ps1') -AppendStepSummary -MinVersion '2025.0.0.0' | Out-Null } catch {}
  # No official quit verb documented here; return policy-mismatch until implemented explicitly
  return @{ ok=$false; code=5; msg='labview-cli close not implemented; prefer g-cli for quit' }
}

# Mode selection (auto prefers g-cli; fallback labview-cli)
$result = $null
switch ($CloseMode) {
  'g-cli'       { $result = Close-With-GCli -Version $MinimumSupportedLVVersion -Arch $SupportedBitness -Timeout $TimeoutSeconds -ForceKillSec $ForceKillAfterSeconds }
  'labview-cli' { $result = Close-With-LabVIEWCli -Version $MinimumSupportedLVVersion -Arch $SupportedBitness -Timeout $TimeoutSeconds -ForceKillSec $ForceKillAfterSeconds }
  default {
    $result = Close-With-GCli -Version $MinimumSupportedLVVersion -Arch $SupportedBitness -Timeout $TimeoutSeconds -ForceKillSec $ForceKillAfterSeconds
    if (-not $result.ok -and $result.code -eq 4) {
      $result = Close-With-LabVIEWCli -Version $MinimumSupportedLVVersion -Arch $SupportedBitness -Timeout $TimeoutSeconds -ForceKillSec $ForceKillAfterSeconds
    }
  }
}

if ($result.ok) {
  Write-Host '[Close-LabVIEW] Completed successfully.' -ForegroundColor DarkGreen
  exit 0
} else {
  switch ($result.code) {
    3 { Write-Error '[Close-LabVIEW] Timeout waiting for close to finish.'; exit 3 }
    4 { Write-Error ("[Close-LabVIEW] Tool missing: {0}" -f $result.msg); exit 4 }
    5 { Write-Error ("[Close-LabVIEW] Policy mismatch or unsupported operation: {0}" -f $result.msg); exit 5 }
    default { Write-Error ("[Close-LabVIEW] Failed: {0}" -f $result.msg); exit 1 }
  }
}
