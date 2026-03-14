#Requires -Version 7.0
<#
.SYNOPSIS
  Reads Docker fast-loop readiness artifacts and prints differentiated history diagnostics.
#>
[CmdletBinding()]
param(
  [string]$ResultsRoot = 'tests/results/local-parity',
  [string]$ReadinessPath = '',
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DockerFastLoopDiagnostics.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LabVIEW2026HostPlaneDiagnostics.psm1') -Force

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Resolve-ReadinessPath {
  param(
    [string]$ResultsRoot,
    [string]$ReadinessPath
  )

  if (-not [string]::IsNullOrWhiteSpace($ReadinessPath)) {
    return (Resolve-AbsolutePath -Path $ReadinessPath)
  }

  $resolvedResultsRoot = Resolve-AbsolutePath -Path $ResultsRoot
  return (Join-Path $resolvedResultsRoot 'docker-runtime-fastloop-readiness.json')
}

$readinessResolved = Resolve-ReadinessPath -ResultsRoot $ResultsRoot -ReadinessPath $ReadinessPath
if (-not (Test-Path -LiteralPath $readinessResolved -PathType Leaf)) {
  throw ("Docker fast-loop readiness file not found: {0}" -f $readinessResolved)
}

$readiness = Get-Content -LiteralPath $readinessResolved -Raw | ConvertFrom-Json -Depth 16
$sourceResultsRoot = ''
if ($readiness -and $readiness.PSObject.Properties['source'] -and $readiness.source -and $readiness.source.PSObject.Properties['resultsRoot']) {
  $sourceResultsRoot = [string]$readiness.source.resultsRoot
}
$effectiveResultsRoot = if (-not [string]::IsNullOrWhiteSpace($sourceResultsRoot)) {
  $sourceResultsRoot
} else {
  Split-Path -Parent $readinessResolved
}

$hostPlane = $null
if ($readiness.PSObject.Properties['hostPlane']) {
  $hostPlane = $readiness.hostPlane
}
if ($null -eq $hostPlane -and $readiness -and $readiness.PSObject.Properties['source'] -and $readiness.source -and $readiness.source.PSObject.Properties['hostPlaneReportPath']) {
  $hostPlanePath = [string]$readiness.source.hostPlaneReportPath
  if (-not [string]::IsNullOrWhiteSpace($hostPlanePath) -and (Test-Path -LiteralPath $hostPlanePath -PathType Leaf)) {
    $hostPlane = Get-Content -LiteralPath $hostPlanePath -Raw | ConvertFrom-Json -Depth 16
  }
}

if ($hostPlane) {
  Write-LabVIEW2026HostPlaneConsole -Report $hostPlane
}
Write-DockerFastLoopDockerDesktopPlaneDiagnostics -ContextObject $readiness | Out-Null
$diagnostics = @(Write-DockerFastLoopDifferentiatedDiagnostics -Readiness $readiness -ResultsRoot $effectiveResultsRoot)
if ($PassThru) {
  Write-Output $diagnostics
} else {
  Write-Output $readinessResolved
}
