#Requires -Version 7.0
<#
.SYNOPSIS
  Export phase variables into the current environment (and GITHUB_ENV when available).
.PARAMETER Path
  Manifest path (default: tests/results/_phase/vars.json).
.PARAMETER Prefix
  Prefix to prepend to variable names when exporting (default: PH_).
.PARAMETER Strict
  Fail immediately on validation issues.
#>
[CmdletBinding()]
param(
  [string]$Path = 'tests/results/_phase/vars.json',
  [string]$Prefix = 'PH_',
  [switch]$Strict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'Validate-PhaseVars.ps1'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
  throw "Validate-PhaseVars.ps1 not found alongside this script."
}

$doc = & $validator -Path $Path -Strict:$Strict
if (-not $doc) { return }

$envFile = $env:GITHUB_ENV
foreach ($entry in $doc.variables.GetEnumerator()) {
  $name = if ($Prefix) { $Prefix + $entry.Key } else { $entry.Key }
  $value = [string]$entry.Value
  Set-Item -Path "Env:$name" -Value $value
  if ($envFile) {
    ("{0}={1}" -f $name, $value) | Out-File -FilePath $envFile -Append -Encoding utf8
  }
}

Write-Host ("Exported {0} phase variable(s) with prefix '{1}'." -f $doc.variables.Count, $Prefix)
