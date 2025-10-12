#Requires -Version 7.0
<#
.SYNOPSIS
  Validates LVCompare preflight conditions and (optionally) VI input presence.

.DESCRIPTION
  Ensures the canonical LVCompare path is present on Windows, reports version/bitness,
  and optionally validates that LV_BASE_VI / LV_HEAD_VI are set, exist, and are distinct.
  Emits a concise summary to GITHUB_STEP_SUMMARY when available and requested.

.PARAMETER RequireInputs
  When set, require LV_BASE_VI and LV_HEAD_VI to be valid, existing files and not identical.

.PARAMETER AppendStepSummary
  When set, append a summary block to $env:GITHUB_STEP_SUMMARY.

.OUTPUTS
  Writes human-readable diagnostics to stdout; exits with non-zero code on failure.
#>
[CmdletBinding()]
param(
  [switch]$RequireInputs,
  [switch]$AppendStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force

function Get-ExeBitness([string]$Path){
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Seek(0x3C,[System.IO.SeekOrigin]::Begin) | Out-Null
    $e_lfanew = $br.ReadInt32()
    $fs.Seek($e_lfanew + 4,[System.IO.SeekOrigin]::Begin) | Out-Null
    $machine = $br.ReadUInt16()
    switch ($machine) {
      0x014c { return 'x86' }
      0x8664 { return 'x64' }
      default { return ('0x{0:X4}' -f $machine) }
    }
  } finally { $fs.Dispose() }
}

$ok = $true
$notes = @()
$errors = @()

if (-not $IsWindows) {
  $errors += 'Unsupported OS: LVCompare preflight requires Windows.'
  $ok = $false
} else {
  $canonical = Resolve-LVComparePath
  if (-not $canonical) {
    $errors += 'LVCompare.exe not found at canonical path under Program Files.'
    $ok = $false
  } else {
    $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($canonical)
    $bits = Get-ExeBitness -Path $canonical
    $osBits = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $notes += ('Path: {0}' -f $canonical)
    $notes += ('Version: {0}' -f ($ver.FileVersion ?? 'unknown'))
    $notes += ('Bitness: {0} (OS: {1})' -f $bits, $osBits)
    if ($env:LVCOMPARE_PATH -and (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH -ErrorAction SilentlyContinue)) {
      $ovr = (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH).Path
      if ($ovr -ne $canonical) {
        $errors += ('Non-canonical LVCompare override in LVCOMPARE_PATH: {0}' -f $ovr)
        $errors += ('Expected canonical: {0}' -f $canonical)
        $ok = $false
      }
    }
  }
}

if ($RequireInputs) {
  $b = $env:LV_BASE_VI; $h = $env:LV_HEAD_VI
  if ([string]::IsNullOrWhiteSpace($b) -or [string]::IsNullOrWhiteSpace($h)) {
    $errors += 'LV_BASE_VI and/or LV_HEAD_VI not set.'
    $ok = $false
  } else {
    $bExist = Test-Path -LiteralPath $b -PathType Leaf
    $hExist = Test-Path -LiteralPath $h -PathType Leaf
    if (-not $bExist) { $errors += ('Base VI missing: {0}' -f $b); $ok = $false }
    if (-not $hExist) { $errors += ('Head VI missing: {0}' -f $h); $ok = $false }
    if ($bExist -and $hExist) {
      try {
        $bReal = (Resolve-Path -LiteralPath $b).Path
        $hReal = (Resolve-Path -LiteralPath $h).Path
      } catch { $bReal = $b; $hReal = $h }
      if ($bReal -eq $hReal) { $errors += 'Base and Head VI refer to the same file.'; $ok = $false }
      if ([IO.Path]::GetExtension($bReal).ToLowerInvariant() -ne '.vi') { $notes += ('Base extension unusual: {0}' -f $bReal) }
      if ([IO.Path]::GetExtension($hReal).ToLowerInvariant() -ne '.vi') { $notes += ('Head extension unusual: {0}' -f $hReal) }
    }
  }
}

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  $lines = @('### LVCompare Preflight','')
  $status = if ($ok) { 'ok' } else { 'fail' }
  $lines += ('- Status: {0}' -f $status)
  foreach ($n in $notes)  { $lines += ('- {0}' -f $n) }
  foreach ($e in $errors) { $lines += ('- error: {0}' -f $e) }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if (-not $ok) { exit 1 } else { exit 0 }

