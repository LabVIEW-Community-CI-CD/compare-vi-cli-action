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
  [switch]$AppendStepSummary,
  [switch]$RequireX64 = $true,
  [string]$MinVersion
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
  # Allow x64 override when explicitly requested
  $onlyX64 = $false
  if ($env:LVCI_ONLY_X64) { try { $onlyX64 = ($env:LVCI_ONLY_X64.Trim() -match '^(?i:1|true|yes|on)$') } catch { $onlyX64 = $false } }
  if ($env:LVCOMPARE_PATH -and (Test-Path -LiteralPath $env:LVCOMPARE_PATH -PathType Leaf)) {
    try { $ovrPath = (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH -ErrorAction Stop).Path } catch { $ovrPath = $env:LVCOMPARE_PATH }
    if ($onlyX64 -and $ovrPath) {
      try { $ovrBits = Get-ExeBitness -Path $ovrPath } catch { $ovrBits = $null }
      if ($ovrBits -eq 'x64' -and $ovrPath -ne $canonical) { $canonical = $ovrPath }
    }
  }
  if (-not $canonical) {
    $errors += 'LVCompare.exe not found at canonical path under Program Files.'
    $ok = $false
  } else {
    $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($canonical)
    $bits = Get-ExeBitness -Path $canonical
    $osBits = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $notes += ('Path: {0}' -f $canonical)
    $notes += ('LVCompare Version: {0}' -f ($ver.FileVersion ?? 'unknown'))
    $notes += ('Bitness: {0} (OS: {1})' -f $bits, $osBits)

    if ($RequireX64 -and $osBits -eq 'x64' -and $bits -ne 'x64') {
      $errors += 'LVCompare bitness mismatch: x86 CLI on x64 OS is not allowed by policy.'
      $ok = $false
    }

    if ($MinVersion) {
      $minVer = $null
      try { $minVer = [version]$MinVersion } catch { $minVer = $null }
      if ($minVer) {
        $cliVer = $null
        try { $cliVer = [version]($ver.FileVersion) } catch { $cliVer = $null }

        if ($cliVer) {
          if ($cliVer -lt $minVer) {
            $errors += ('LVCompare version {0} is older than required minimum {1}.' -f $cliVer, $minVer)
            $ok = $false
          }
        } else {
          # Fallback to LabVIEW.exe version when LVCompare version is unavailable
          $lvExe = $env:LABVIEW_EXE
          if (-not ($lvExe) -or -not (Test-Path -LiteralPath $lvExe -PathType Leaf)) {
            $searchRoots = @()
            if ($env:ProgramFiles) { $searchRoots += (Join-Path $env:ProgramFiles 'National Instruments') }
            $pf86 = ${env:ProgramFiles(x86)}
            if ($pf86) { $searchRoots += (Join-Path $pf86 'National Instruments') }
            $cands = @()
            foreach ($root in $searchRoots) {
              try { $cands += (Get-ChildItem -Path $root -Filter 'LabVIEW.exe' -File -Recurse -ErrorAction SilentlyContinue) } catch {}
            }
            if ($cands.Count -gt 0) {
              $lvExe = ($cands | Sort-Object {[version]$_.VersionInfo.FileVersion} -Descending | Select-Object -First 1).FullName
            }
          }
          if ($lvExe -and (Test-Path -LiteralPath $lvExe -PathType Leaf)) {
            $lvInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($lvExe)
            $notes += ('LabVIEW Path: {0}' -f $lvExe)
            $notes += ('LabVIEW Version: {0}' -f ($lvInfo.FileVersion ?? 'unknown'))
            try {
              $lvVer = [version]($lvInfo.FileVersion)
              if ($lvVer -lt $minVer) {
                $errors += ('LabVIEW version {0} is older than required minimum {1}.' -f $lvVer, $minVer)
                $ok = $false
              }
            } catch {
              $notes += 'Version check skipped (unable to parse LabVIEW version).'
            }
          } else {
            $notes += 'Version check skipped (LabVIEW.exe not found and LVCompare version unavailable).'
          }
        }
      } else {
        $notes += ('MinVersion parameter not a valid version: {0}' -f $MinVersion)
      }
    }
    if ($env:LVCOMPARE_PATH -and (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH -ErrorAction SilentlyContinue)) {
      $ovr = (Resolve-Path -LiteralPath $env:LVCOMPARE_PATH).Path
      if ($ovr -ne $canonical) {
        if ($onlyX64) {
          try { $ovrBits2 = Get-ExeBitness -Path $ovr } catch { $ovrBits2 = $null }
          if ($ovrBits2 -eq 'x64' -and $bits -eq 'x64') {
            $notes += ('LVCompare override accepted (x64): {0}' -f $ovr)
          } else {
            $errors += ('LVCompare override rejected (bitness mismatch): {0}' -f $ovr)
            $errors += ('Expected x64 canonical: {0}' -f $canonical)
            $ok = $false
          }
        } else {
          $errors += ('Non-canonical LVCompare override in LVCOMPARE_PATH: {0}' -f $ovr)
          $errors += ('Expected canonical: {0}' -f $canonical)
          $ok = $false
        }
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
if ($env:LVCI_COMPARE_MODE -and [string]::Equals($env:LVCI_COMPARE_MODE, 'labview-cli', [System.StringComparison]::OrdinalIgnoreCase)) {
  if ($env:LABVIEW_CLI_PATH) {
    if (Test-Path -LiteralPath $env:LABVIEW_CLI_PATH -PathType Leaf) {
      try {
        $resolvedCli = (Resolve-Path -LiteralPath $env:LABVIEW_CLI_PATH -ErrorAction Stop).Path
        $notes += ('LabVIEW CLI Path: {0}' -f $resolvedCli)
      } catch {
        $notes += ('LabVIEW CLI Path: {0}' -f $env:LABVIEW_CLI_PATH)
      }
    } else {
      $errors += ('LabVIEW CLI not found at LABVIEW_CLI_PATH: {0}' -f $env:LABVIEW_CLI_PATH)
      $ok = $false
    }
  } else {
    $notes += 'LABVIEW_CLI_PATH not set; falling back to default LabVIEWCLI.exe discovery.'
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

foreach ($n in $notes) {
  Write-Host ('::notice::{0}' -f $n)
}
foreach ($e in $errors) {
  Write-Error $e
}

if (-not $ok) { exit 1 } else { exit 0 }
