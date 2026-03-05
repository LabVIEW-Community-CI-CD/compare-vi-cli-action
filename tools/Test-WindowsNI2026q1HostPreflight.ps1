#Requires -Version 7.0
<#
.SYNOPSIS
  Deterministic host preflight for NI LabVIEW 2026 q1 Windows container image.

.DESCRIPTION
  Executes the Docker runtime manager in windows-only mode, bootstraps
  `nationalinstruments/labview:2026q1-windows` when missing, and emits a
  machine-readable artifact under tests/results/local-parity by default.
#>
[CmdletBinding()]
param(
  [string]$Image = 'nationalinstruments/labview:2026q1-windows',
  [string]$ResultsDir = 'tests/results/local-parity',
  [string]$OutputJsonPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

$repoRoot = Resolve-AbsolutePath -Path (Join-Path $PSScriptRoot '..')
$managerScript = Join-Path $repoRoot 'tools' 'Invoke-DockerRuntimeManager.ps1'
if (-not (Test-Path -LiteralPath $managerScript -PathType Leaf)) {
  throw ("Invoke-DockerRuntimeManager.ps1 not found: {0}" -f $managerScript)
}

$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir
if (-not (Test-Path -LiteralPath $resultsDirResolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null
}

$jsonPathResolved = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsDirResolved 'windows-ni-2026q1-host-preflight.json'
} else {
  Resolve-AbsolutePath -Path $OutputJsonPath
}

& $managerScript `
  -ProbeScope 'windows' `
  -WindowsImage $Image `
  -BootstrapWindowsImage:$true `
  -BootstrapLinuxImage:$false `
  -RestoreContext 'desktop-windows' `
  -OutputJsonPath $jsonPathResolved `
  -GitHubOutputPath $GitHubOutputPath `
  -StepSummaryPath $StepSummaryPath

Write-Output $jsonPathResolved
