#Requires -Version 7.0
<#
.SYNOPSIS
  Attaches Docker runtime manager metadata to fixture-drift session-index.json.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'results/fixture-drift',
  [string]$SessionIndexPath = '',
  [string]$ContextPath = '',
  [string]$RequiredLabel = 'self-hosted-docker',
  [bool]$HasRequiredLabel = $false,
  [string]$RunnerLabelsCsv = '',
  [string]$ManagerStatus = '',
  [string]$ManagerSummaryPath = '',
  [string]$WindowsImageDigest = '',
  [string]$LinuxImageDigest = '',
  [string]$StartContext = '',
  [string]$FinalContext = '',
  [switch]$IgnoreMissingSessionIndex
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

$resultsResolved = Resolve-AbsolutePath -Path $ResultsDir
$sessionPathResolved = if ([string]::IsNullOrWhiteSpace($SessionIndexPath)) {
  Join-Path $resultsResolved 'session-index.json'
} else {
  Resolve-AbsolutePath -Path $SessionIndexPath
}
$contextPathResolved = if ([string]::IsNullOrWhiteSpace($ContextPath)) {
  Join-Path $resultsResolved 'docker-runtime-manager-context.json'
} else {
  Resolve-AbsolutePath -Path $ContextPath
}

if (-not (Test-Path -LiteralPath $sessionPathResolved -PathType Leaf)) {
  if ($IgnoreMissingSessionIndex) {
    Write-Host ("::warning::session-index.json not found at {0}; docker manager metadata was not attached." -f $sessionPathResolved)
    return
  }
  throw ("session-index.json not found: {0}" -f $sessionPathResolved)
}

$labels = @()
if (-not [string]::IsNullOrWhiteSpace($RunnerLabelsCsv)) {
  $labels = @($RunnerLabelsCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$index = Get-Content -LiteralPath $sessionPathResolved -Raw | ConvertFrom-Json -Depth 30
if (-not $index.PSObject.Properties['runContext'] -or $null -eq $index.runContext) {
  $index | Add-Member -MemberType NoteProperty -Name 'runContext' -Value ([ordered]@{}) -Force
}

$index.runContext.dockerRuntimeManager = [ordered]@{
  status = [string]$ManagerStatus
  summaryPath = [string]$ManagerSummaryPath
  windowsImageDigest = [string]$WindowsImageDigest
  linuxImageDigest = [string]$LinuxImageDigest
  startContext = [string]$StartContext
  finalContext = [string]$FinalContext
  contextArtifactPath = if (Test-Path -LiteralPath $contextPathResolved -PathType Leaf) { $contextPathResolved } else { '' }
}
$index.runContext.runnerLabelContract = [ordered]@{
  requiredLabel = [string]$RequiredLabel
  hasRequiredLabel = [bool]$HasRequiredLabel
  labels = @($labels)
}

($index | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $sessionPathResolved -Encoding utf8
Write-Output $sessionPathResolved
