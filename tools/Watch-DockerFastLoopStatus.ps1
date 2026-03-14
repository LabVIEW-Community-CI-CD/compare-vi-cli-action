#Requires -Version 7.0
<#
.SYNOPSIS
  Watches semi-live Docker fast-loop status and prints concise progress.
#>
[CmdletBinding()]
param(
  [string]$StatusPath = 'tests/results/local-parity/docker-runtime-fastloop-status.json',
  [int]$PollSeconds = 2,
  [int]$TimeoutSeconds = 900
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

function Get-ReadinessHostPlaneReport {
  param([Parameter(Mandatory)][AllowNull()]$Readiness)

  if ($Readiness.PSObject.Properties['hostPlane']) {
    return $Readiness.hostPlane
  }

  if ($Readiness.PSObject.Properties['source'] -and $Readiness.source -and $Readiness.source.PSObject.Properties['hostPlaneReportPath']) {
    $hostPlanePath = [string]$Readiness.source.hostPlaneReportPath
    if (-not [string]::IsNullOrWhiteSpace($hostPlanePath) -and (Test-Path -LiteralPath $hostPlanePath -PathType Leaf)) {
      return (Get-Content -LiteralPath $hostPlanePath -Raw | ConvertFrom-Json -Depth 16)
    }
  }

  return $null
}

function Get-ReadinessHostPlaneSummaryProvenance {
  param([Parameter(Mandatory)][AllowNull()]$Readiness)

  $path = ''
  $status = ''
  $sha256 = ''
  $reason = ''
  $declared = $false

  if ($Readiness.PSObject.Properties['hostPlaneSummary'] -and $Readiness.hostPlaneSummary) {
    if ($Readiness.hostPlaneSummary.PSObject.Properties['path']) {
      $path = [string]$Readiness.hostPlaneSummary.path
      $declared = -not [string]::IsNullOrWhiteSpace($path)
    }
    if ($Readiness.hostPlaneSummary.PSObject.Properties['status']) {
      $status = [string]$Readiness.hostPlaneSummary.status
    }
    if ($Readiness.hostPlaneSummary.PSObject.Properties['sha256']) {
      $sha256 = [string]$Readiness.hostPlaneSummary.sha256
    }
    if ($Readiness.hostPlaneSummary.PSObject.Properties['reason']) {
      $reason = [string]$Readiness.hostPlaneSummary.reason
    }
  }

  if ([string]::IsNullOrWhiteSpace($path) -and $Readiness.PSObject.Properties['source'] -and $Readiness.source -and $Readiness.source.PSObject.Properties['hostPlaneSummaryPath']) {
    $path = [string]$Readiness.source.hostPlaneSummaryPath
    $declared = -not [string]::IsNullOrWhiteSpace($path)
  }

  if (-not [string]::IsNullOrWhiteSpace($path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    if ([string]::IsNullOrWhiteSpace($status)) {
      $status = 'missing'
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
      $reason = 'host-plane-summary-missing'
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($path)) {
    [void](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
  }

  return [pscustomobject]@{
    path = $path
    status = $status
    sha256 = $sha256
    reason = $reason
    declared = $declared
  }
}

function Write-HostPlaneSummaryConsole {
  param([Parameter(Mandatory)][AllowNull()]$Summary)

  if (-not $Summary -or [string]::IsNullOrWhiteSpace([string]$Summary.path)) {
    return
  }

  $summaryParts = New-Object System.Collections.Generic.List[string]
  [void]$summaryParts.Add([string]$Summary.path)
  if (-not [string]::IsNullOrWhiteSpace([string]$Summary.status)) {
    [void]$summaryParts.Add(("status={0}" -f [string]$Summary.status))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Summary.sha256)) {
    [void]$summaryParts.Add(("sha256={0}" -f [string]$Summary.sha256))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Summary.reason)) {
    [void]$summaryParts.Add(("reason={0}" -f [string]$Summary.reason))
  }
  Write-Host ("[host-plane-split][summary] {0}" -f ([string]::Join(' ', @($summaryParts.ToArray())))) -ForegroundColor DarkCyan
}

$resolvedStatusPath = Resolve-AbsolutePath -Path $StatusPath
$deadline = (Get-Date).AddSeconds([math]::Max(5, $TimeoutSeconds))
$lastStamp = ''

while ((Get-Date) -lt $deadline) {
  if (-not (Test-Path -LiteralPath $resolvedStatusPath -PathType Leaf)) {
    Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
    continue
  }

  try {
    $status = Get-Content -LiteralPath $resolvedStatusPath -Raw | ConvertFrom-Json -Depth 10
  } catch {
    Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
    continue
  }

  if (-not $status) {
    Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
    continue
  }

  $stamp = [string]$status.generatedAt
  if ($stamp -ne $lastStamp) {
    $lastStamp = $stamp
    $statusPrefix = Get-DockerFastLoopLogPrefix -ContextObject $status
    $phase = [string]$status.phase
    $runStatus = [string]$status.status
    $current = if ([string]::IsNullOrWhiteSpace([string]$status.currentStep)) { '-' } else { [string]$status.currentStep }
    $completed = [int]$status.completedSteps
    $total = [int]$status.totalSteps
    $percent = [double]$status.percentComplete
    $telemetry = if ($status.PSObject.Properties['telemetry']) { $status.telemetry } else { $null }
    $eta = if ($telemetry -and $telemetry.PSObject.Properties['etaSeconds']) { [double]$telemetry.etaSeconds } else { 0.0 }
    $recommendation = if ($telemetry -and $telemetry.PSObject.Properties['pushRecommendation']) { [string]$telemetry.pushRecommendation } else { 'hold' }

    $line = "{0}[status] phase={1} status={2} step={3} progress={4}/{5} ({6}%) eta={7}s recommendation={8}" -f `
      $statusPrefix, $phase, $runStatus, $current, $completed, $total, $percent, $eta, $recommendation
    if ($runStatus -eq 'success' -and $phase -eq 'completed') {
      Write-Host $line -ForegroundColor Green
    } elseif ($runStatus -eq 'failure' -and $phase -eq 'completed') {
      Write-Host $line -ForegroundColor Red
    } else {
      Write-Host $line -ForegroundColor Cyan
    }
  }

  if ([string]$status.phase -eq 'completed') {
    $resultsRoot = ''
    if ($status.PSObject.Properties['summaryPath']) {
      $summaryPathValue = [string]$status.summaryPath
      if (-not [string]::IsNullOrWhiteSpace($summaryPathValue)) {
        $resultsRoot = Split-Path -Parent $summaryPathValue
      }
    }
    if ([string]::IsNullOrWhiteSpace($resultsRoot)) {
      $resultsRoot = Split-Path -Parent $resolvedStatusPath
    }
    $readinessPath = Join-Path $resultsRoot 'docker-runtime-fastloop-readiness.json'
    if (Test-Path -LiteralPath $readinessPath -PathType Leaf) {
      $readiness = $null
      try {
        $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 10
      } catch {
        Write-Warning ("Failed to parse readiness envelope: {0}" -f $_.Exception.Message)
      }
      if ($readiness) {
        $readinessPrefix = Get-DockerFastLoopLogPrefix -ContextObject $readiness
        $verdict = if ($readiness.PSObject.Properties['verdict']) { [string]$readiness.verdict } else { 'unknown' }
        $recommendation = if ($readiness.PSObject.Properties['recommendation']) { [string]$readiness.recommendation } else { 'unknown' }
        Write-Host ("{0}[readiness] verdict={1} recommendation={2} path={3}" -f $readinessPrefix, $verdict, $recommendation, $readinessPath) -ForegroundColor Cyan
        $hostPlane = Get-ReadinessHostPlaneReport -Readiness $readiness
        if ($hostPlane) {
          Write-LabVIEW2026HostPlaneConsole -Report $hostPlane
        }
        $hostPlaneSummary = Get-ReadinessHostPlaneSummaryProvenance -Readiness $readiness
        Write-HostPlaneSummaryConsole -Summary $hostPlaneSummary
        if ($hostPlaneSummary.declared -and [string]$hostPlaneSummary.status -ne 'ok') {
          throw ("Declared host-plane summary artifact not readable: {0}" -f [string]$hostPlaneSummary.path)
        }
        Write-DockerFastLoopDifferentiatedDiagnostics -Readiness $readiness -ResultsRoot $resultsRoot | Out-Null
      }
    }
    if ([string]$status.status -ne 'success') {
      throw ("Docker fast-loop completed with status '{0}'. See: {1}" -f ([string]$status.status), $resolvedStatusPath)
    }
    Write-Output $resolvedStatusPath
    exit 0
  }

  Start-Sleep -Seconds ([math]::Max(1, $PollSeconds))
}

throw ("Timed out waiting for docker fast-loop status: {0}" -f $resolvedStatusPath)
