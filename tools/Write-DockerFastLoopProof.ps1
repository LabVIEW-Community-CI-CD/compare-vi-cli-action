#Requires -Version 7.0
<#
.SYNOPSIS
  Writes a deterministic proof artifact for Docker fast-loop gate runs.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ReadinessPath,
  [string]$SummaryPath = '',
  [string]$StatusPath = '',
  [string]$OutputPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DockerFastLoopDiagnostics.psm1') -Force

function Resolve-AbsolutePath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Get-FileHashOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-JsonOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16)
  } catch {
    return $null
  }
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  Ensure-ParentDirectory -Path $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
  }
  Add-Content -LiteralPath $Path -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

$readinessResolved = Resolve-AbsolutePath -Path $ReadinessPath
if (-not (Test-Path -LiteralPath $readinessResolved -PathType Leaf)) {
  throw ("Readiness file not found: {0}" -f $readinessResolved)
}

$summaryResolved = if ([string]::IsNullOrWhiteSpace($SummaryPath)) { '' } else { Resolve-AbsolutePath -Path $SummaryPath }
$statusResolved = if ([string]::IsNullOrWhiteSpace($StatusPath)) { '' } else { Resolve-AbsolutePath -Path $StatusPath }

$readiness = Read-JsonOrNull -Path $readinessResolved
if (-not $readiness) {
  throw ("Unable to parse readiness json: {0}" -f $readinessResolved)
}

if ([string]::IsNullOrWhiteSpace($summaryResolved) -and $readiness.PSObject.Properties['source'] -and $readiness.source.PSObject.Properties['summaryPath']) {
  $candidateSummary = [string]$readiness.source.summaryPath
  if (-not [string]::IsNullOrWhiteSpace($candidateSummary)) {
    $summaryResolved = Resolve-AbsolutePath -Path $candidateSummary
  }
}
if ([string]::IsNullOrWhiteSpace($statusResolved) -and $readiness.PSObject.Properties['source'] -and $readiness.source.PSObject.Properties['statusPath']) {
  $candidateStatus = [string]$readiness.source.statusPath
  if (-not [string]::IsNullOrWhiteSpace($candidateStatus)) {
    $statusResolved = Resolve-AbsolutePath -Path $candidateStatus
  }
}

$root = Split-Path -Parent $readinessResolved
$outputResolved = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $proofDir = Join-Path $root '..\_agent\gates'
  $timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
  Resolve-AbsolutePath -Path (Join-Path $proofDir ("docker-fast-loop-proof-{0}.json" -f $timestamp))
} else {
  Resolve-AbsolutePath -Path $OutputPath
}
Ensure-ParentDirectory -Path $outputResolved

$summary = Read-JsonOrNull -Path $summaryResolved
$diffStepCount = if ($readiness.PSObject.Properties['diffStepCount']) {
  [int]$readiness.diffStepCount
} elseif ($summary -and $summary.PSObject.Properties['diffStepCount']) {
  [int]$summary.diffStepCount
} else {
  0
}
$diffEvidenceSteps = if ($readiness.PSObject.Properties['diffEvidenceSteps']) {
  [int]$readiness.diffEvidenceSteps
} elseif ($summary -and $summary.PSObject.Properties['diffEvidenceSteps']) {
  [int]$summary.diffEvidenceSteps
} else {
  0
}
$diffLaneCount = if ($readiness.PSObject.Properties['diffLaneCount']) {
  [int]$readiness.diffLaneCount
} elseif ($summary -and $summary.PSObject.Properties['diffLaneCount']) {
  [int]$summary.diffLaneCount
} else {
  0
}
$extractedReportCount = if ($readiness.PSObject.Properties['extractedReportCount']) {
  [int]$readiness.extractedReportCount
} elseif ($summary -and $summary.PSObject.Properties['extractedReportCount']) {
  [int]$summary.extractedReportCount
} else {
  0
}
$containerExportFailureCount = if ($readiness.PSObject.Properties['containerExportFailureCount']) {
  [int]$readiness.containerExportFailureCount
} elseif ($summary -and $summary.PSObject.Properties['containerExportFailureCount']) {
  [int]$summary.containerExportFailureCount
} else {
  0
}
$runtimeFailureCount = if ($readiness.PSObject.Properties['runtimeFailureCount']) {
  [int]$readiness.runtimeFailureCount
} elseif ($summary -and $summary.PSObject.Properties['runtimeFailureCount']) {
  [int]$summary.runtimeFailureCount
} else {
  0
}
$toolFailureCount = if ($readiness.PSObject.Properties['toolFailureCount']) {
  [int]$readiness.toolFailureCount
} elseif ($summary -and $summary.PSObject.Properties['toolFailureCount']) {
  [int]$summary.toolFailureCount
} else {
  0
}
$hardStopTriggered = if ($readiness.PSObject.Properties['hardStopTriggered']) {
  [bool]$readiness.hardStopTriggered
} elseif ($summary -and $summary.PSObject.Properties['hardStopTriggered']) {
  [bool]$summary.hardStopTriggered
} else {
  $false
}
$hardStopReason = if ($readiness.PSObject.Properties['hardStopReason']) {
  [string]$readiness.hardStopReason
} elseif ($summary -and $summary.PSObject.Properties['hardStopReason']) {
  [string]$summary.hardStopReason
} else {
  ''
}
$runtimeManager = if ($readiness.PSObject.Properties['runtimeManager']) {
  $readiness.runtimeManager
} elseif ($summary -and $summary.PSObject.Properties['runtimeManager']) {
  $summary.runtimeManager
} else {
  $null
}
$runtimeManagerTransitionCount = if ($readiness.PSObject.Properties['runtimeManagerTransitionCount']) {
  [int]$readiness.runtimeManagerTransitionCount
} elseif ($summary -and $summary.PSObject.Properties['runtimeManagerTransitionCount']) {
  [int]$summary.runtimeManagerTransitionCount
} elseif ($runtimeManager -and $runtimeManager.PSObject.Properties['transitionCount']) {
  [int]$runtimeManager.transitionCount
} else {
  0
}
$runtimeManagerDaemonUnavailableCount = if ($readiness.PSObject.Properties['runtimeManagerDaemonUnavailableCount']) {
  [int]$readiness.runtimeManagerDaemonUnavailableCount
} elseif ($summary -and $summary.PSObject.Properties['runtimeManagerDaemonUnavailableCount']) {
  [int]$summary.runtimeManagerDaemonUnavailableCount
} elseif ($runtimeManager -and $runtimeManager.PSObject.Properties['daemonUnavailableCount']) {
  [int]$runtimeManager.daemonUnavailableCount
} else {
  0
}
$runtimeManagerParseDefectCount = if ($readiness.PSObject.Properties['runtimeManagerParseDefectCount']) {
  [int]$readiness.runtimeManagerParseDefectCount
} elseif ($summary -and $summary.PSObject.Properties['runtimeManagerParseDefectCount']) {
  [int]$summary.runtimeManagerParseDefectCount
} elseif ($runtimeManager -and $runtimeManager.PSObject.Properties['parseDefectCount']) {
  [int]$runtimeManager.parseDefectCount
} else {
  0
}
$hostPlaneReportPath = if ($readiness.PSObject.Properties['source'] -and $readiness.source -and $readiness.source.PSObject.Properties['hostPlaneReportPath']) {
  [string]$readiness.source.hostPlaneReportPath
} else {
  ''
}
$hostPlane = if ($readiness.PSObject.Properties['hostPlane']) {
  $readiness.hostPlane
} elseif (-not [string]::IsNullOrWhiteSpace($hostPlaneReportPath)) {
  Read-JsonOrNull -Path $hostPlaneReportPath
} else {
  $null
}
$hostPlanes = if ($readiness.PSObject.Properties['hostPlanes']) {
  $readiness.hostPlanes
} elseif ($hostPlane -and $hostPlane.PSObject.Properties['native'] -and $hostPlane.native -and $hostPlane.native.PSObject.Properties['planes']) {
  $hostPlane.native.planes
} else {
  $null
}
$hostExecutionPolicy = if ($readiness.PSObject.Properties['hostExecutionPolicy']) {
  $readiness.hostExecutionPolicy
} elseif ($hostPlane -and $hostPlane.PSObject.Properties['executionPolicy']) {
  $hostPlane.executionPolicy
} else {
  $null
}

$proof = [ordered]@{
  schema = 'vi-history/docker-fast-loop-proof@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  loopLabel = Get-DockerFastLoopLabel -ContextObject $readiness
  verdict = if ($readiness.PSObject.Properties['verdict']) { [string]$readiness.verdict } else { 'unknown' }
  recommendation = if ($readiness.PSObject.Properties['recommendation']) { [string]$readiness.recommendation } else { 'unknown' }
  diffStepCount = [int]$diffStepCount
  diffEvidenceSteps = [int]$diffEvidenceSteps
  diffLaneCount = [int]$diffLaneCount
  extractedReportCount = [int]$extractedReportCount
  containerExportFailureCount = [int]$containerExportFailureCount
  runtimeFailureCount = [int]$runtimeFailureCount
  toolFailureCount = [int]$toolFailureCount
  hardStopTriggered = [bool]$hardStopTriggered
  hardStopReason = $hardStopReason
  runtimeManagerTransitionCount = [int]$runtimeManagerTransitionCount
  runtimeManagerDaemonUnavailableCount = [int]$runtimeManagerDaemonUnavailableCount
  runtimeManagerParseDefectCount = [int]$runtimeManagerParseDefectCount
  runtimeManager = $runtimeManager
  readinessPath = $readinessResolved
  summaryPath = $summaryResolved
  statusPath = $statusResolved
  hostPlaneReportPath = $hostPlaneReportPath
  hashes = [ordered]@{
    readinessSha256 = Get-FileHashOrNull -Path $readinessResolved
    summarySha256 = Get-FileHashOrNull -Path $summaryResolved
    statusSha256 = Get-FileHashOrNull -Path $statusResolved
  }
  laneLifecycle = if ($readiness.PSObject.Properties['laneLifecycle']) { $readiness.laneLifecycle } elseif ($summary -and $summary.PSObject.Properties['laneLifecycle']) { $summary.laneLifecycle } else { $null }
  lanes = if ($readiness.PSObject.Properties['lanes']) { $readiness.lanes } else { $null }
  hostPlane = $hostPlane
  hostPlanes = $hostPlanes
  hostExecutionPolicy = $hostExecutionPolicy
}

$proof | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $outputResolved -Encoding utf8
$loopPrefix = Get-DockerFastLoopLogPrefix -ContextObject $proof
Write-Host ("{0}[proof] {1}" -f $loopPrefix, $outputResolved)
Write-GitHubOutput -Key 'docker-fast-loop-proof-path' -Value $outputResolved -Path $GitHubOutputPath
Write-Output $outputResolved
