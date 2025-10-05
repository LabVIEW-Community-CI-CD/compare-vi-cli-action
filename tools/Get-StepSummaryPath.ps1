#Requires -Version 7.0
<#!
.SYNOPSIS
  Resolve a safe path for writing the GitHub Actions step summary.
.DESCRIPTION
  Returns $env:GITHUB_STEP_SUMMARY when available. Otherwise returns a
  fallback file path (under $env:RUNNER_TEMP when set, else ./step-summary.md).
  Ensures the parent directory exists.
.PARAMETER FallbackFile
  Filename to use for fallback. Default: step-summary.md
.OUTPUTS
  String path to the summary file.
#>
[CmdletBinding()] param(
  [string] $FallbackFile = 'step-summary.md'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$path = $env:GITHUB_STEP_SUMMARY
if ([string]::IsNullOrWhiteSpace($path)) {
  $base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { (Get-Location).Path }
  $path = Join-Path $base $FallbackFile
}
$dir = Split-Path -Parent $path
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
Write-Output $path

