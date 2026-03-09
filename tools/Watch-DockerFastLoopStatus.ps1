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

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
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
    $eta = if ($status.telemetry -and $status.telemetry.PSObject.Properties['etaSeconds']) { [double]$status.telemetry.etaSeconds } else { 0.0 }
    $recommendation = if ($status.telemetry -and $status.telemetry.PSObject.Properties['pushRecommendation']) { [string]$status.telemetry.pushRecommendation } else { 'hold' }

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
      try {
        $readiness = Get-Content -LiteralPath $readinessPath -Raw | ConvertFrom-Json -Depth 10
        if ($readiness) {
          $readinessPrefix = Get-DockerFastLoopLogPrefix -ContextObject $readiness
          $verdict = if ($readiness.PSObject.Properties['verdict']) { [string]$readiness.verdict } else { 'unknown' }
          $recommendation = if ($readiness.PSObject.Properties['recommendation']) { [string]$readiness.recommendation } else { 'unknown' }
          Write-Host ("{0}[readiness] verdict={1} recommendation={2} path={3}" -f $readinessPrefix, $verdict, $recommendation, $readinessPath) -ForegroundColor Cyan
          Write-DockerFastLoopDifferentiatedDiagnostics -Readiness $readiness -ResultsRoot $resultsRoot | Out-Null
        }
      } catch {
        Write-Warning ("Failed to parse readiness envelope: {0}" -f $_.Exception.Message)
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
