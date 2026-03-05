#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][bool]$ExpectedActive,
  [string]$RepoRoot,
  [string]$IconEditorRoot,
  [int[]]$Versions,
  [int[]]$Bitness,
  [string]$Operation = 'BuildPackage'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $scriptDirectory 'IconEditorDevMode.psm1'
Import-Module $modulePath -Force

$targetsOverride = $null
try {
  $targetsOverride = Get-IconEditorDevModePolicyEntry -RepoRoot $RepoRoot -Operation $Operation
} catch {
  $targetsOverride = $null
}

function Get-AssertDefaultTargets {
  param([string]$OperationName)
  $normalized = if ($OperationName) { $OperationName.ToLowerInvariant() } else { 'buildpackage' }
  switch ($normalized) {
    'compare' { return @{ Versions = @(2025); Bitness = @(64) } }
    default   { return @{ Versions = @(2021); Bitness = @(32, 64) } }
  }
}

$defaultTargets = Get-AssertDefaultTargets -OperationName $Operation
[array]$overrideVersions = @()
[array]$overrideBitness  = @()
if ($targetsOverride) {
  $overrideVersions = @($targetsOverride.Versions)
  $overrideBitness  = @($targetsOverride.Bitness)
}
$versionFallback = if ($overrideVersions.Count -gt 0) { $overrideVersions } else { @($defaultTargets.Versions) }
$bitnessFallback = if ($overrideBitness.Count -gt 0) { $overrideBitness } else { @($defaultTargets.Bitness) }
[array]$effectiveVersions = @()
[array]$effectiveBitness  = @()

function Convert-AssertValues {
  param([int[]]$Values, [int[]]$Fallback)
  $result = @()
  if ($Values) {
    foreach ($value in $Values) {
      if ($null -ne $value) { $result += [int]$value }
    }
  }
  if (($result.Count -eq 0) -and $Fallback) {
    foreach ($value in $Fallback) {
      if ($null -ne $value) { $result += [int]$value }
    }
  }
  return $result
}

[array]$effectiveVersions = Convert-AssertValues -Values $Versions -Fallback $versionFallback
[array]$effectiveBitness  = Convert-AssertValues -Values $Bitness -Fallback $bitnessFallback

$invokeParams = @{
  RepoRoot = $RepoRoot
  IconEditorRoot = $IconEditorRoot
  Versions = $effectiveVersions
  Bitness  = $effectiveBitness
}

$result = Test-IconEditorDevelopmentMode @invokeParams
$entries = $result.Entries
$present = $entries | Where-Object { $_.Present }

if ($present.Count -eq 0) {
  $expectText = ($effectiveVersions | ForEach-Object {
      foreach ($bit in $effectiveBitness) { "LabVIEW $_ ($bit-bit)" }
    }) -join ', '
  Write-Error ("No LabVIEW installations were detected for development mode verification. Expected to find: {0}." -f $expectText)
  exit 1
}

$targetState = if ($ExpectedActive) { 'enabled' } else { 'disabled' }
Write-Host ("Verifying icon editor development mode is {0}..." -f $targetState)

$failed = @()
foreach ($entry in $present) {
  $status = if ($entry.ContainsIconEditorPath) { 'contains icon editor path' } else { 'does not contain icon editor path' }
  Write-Host ("- LabVIEW {0} ({1}-bit): {2}" -f $entry.Version, $entry.Bitness, $status)
  $isMatch = ($entry.ContainsIconEditorPath -eq $ExpectedActive)
  if (-not $isMatch) {
    $failed += $entry
  }
}

if ($failed.Count -gt 0) {
  $failText = $failed | ForEach-Object {
    "LabVIEW {0} ({1}-bit)" -f $_.Version, $_.Bitness
  }
  throw ("Icon editor development mode expected '{0}' but mismatched targets: {1}" -f $targetState, ($failText -join ', '))
}

Write-Host "Icon editor development mode verification succeeded."
$result

