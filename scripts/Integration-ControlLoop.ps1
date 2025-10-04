<#
.SYNOPSIS
  Watches two LabVIEW VI files (base/head) and repeatedly invokes LVCompare until stopped.
.DESCRIPTION
  This is a development scaffold for exercising real CLI comparisons in a tight loop.
  Intended for manual, local, self-hosted usage to observe diff stability, timing, and noise.

  Key Policies (mirrors repo conventions):
    - Enforces canonical LVCompare path only: C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
    - Requires both Base and Head VI paths to exist
    - Records timing metrics per compare and rolling aggregates
    - Supports optional change-detection (skip run when neither VI timestamp changed)
    - Emits a compact console table + optional JSON log per iteration

  Exit Codes:
    0 = Loop terminated normally (Ctrl+C or max iterations reached)
    1 = Pre-run validation failure
    2 = Internal compare error (non diff exit code from CLI)

  NOTE: This script purposefully does NOT fail the loop on diff exit code (1) unless -FailOnDiff is specified.
        Instead it records the diff outcome so you can observe natural churn while editing the Head VI.

.PARAMETER Base
  Path to the baseline (reference) VI.
.PARAMETER Head
  Path to the modified VI under development.
.PARAMETER IntervalSeconds
  Delay between successful compare iterations (default 5).
.PARAMETER MaxIterations
  Optional cap on iterations; omit or 0 for infinite until Ctrl+C.
.PARAMETER SkipIfUnchanged
  When set, compares only if either VI's LastWriteTime changed since previous iteration.
.PARAMETER JsonLog
  Optional path to append JSON lines (one object per iteration) for later analysis.
.PARAMETER LvCompareArgs
  Optional string of extra LVCompare flags (space-delimited; quoting supported) e.g. "-nobdcosm -nofppos -noattr".
.PARAMETER FailOnDiff
  When set, terminate the loop on the first detected diff (exit code 0 for clean termination or 2 on CLI error).
.PARAMETER Quiet
  Suppress per-iteration table output (only summary + errors).
.PARAMETER CompareExecutor
  (Testing/DI) ScriptBlock that receives -CliPath -Base -Head -Args and returns an exit code (int) instead of invoking the real CLI.
.PARAMETER BypassCliValidation
  Skip canonical path check (used in unit-style tests or when CLI presence already assured externally).

.EXAMPLE
  pwsh -File ./scripts/Integration-ControlLoop.ps1 -Base 'C:\repos\main\ControlLoop.vi' -Head 'C:\repos\feature\ControlLoop.vi' -LvCompareArgs "-nobdcosm -nofppos -noattr" -SkipIfUnchanged -IntervalSeconds 3

.EXAMPLE
  # Run until a diff occurs, failing immediately
  pwsh -File ./scripts/Integration-ControlLoop.ps1 -Base $env:LV_BASE_VI -Head $env:LV_HEAD_VI -FailOnDiff

#>
param(
  [Parameter(Mandatory)][string]$Base,
  [Parameter(Mandatory)][string]$Head,
  [int]$IntervalSeconds = 5,
  [int]$MaxIterations = 0,
  [switch]$SkipIfUnchanged,
  [string]$JsonLog,
  [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
  [switch]$FailOnDiff,
  [switch]$Quiet,
  [scriptblock]$CompareExecutor,
  [switch]$BypassCliValidation,
  [switch]$UseEventDriven,
  [int]$DebounceMilliseconds = 250,
  [ValidateSet('None','Text','Markdown','Html')][string]$DiffSummaryFormat = 'None',
  [string]$DiffSummaryPath,
  [switch]$AdaptiveInterval,
  [int]$MinIntervalSeconds = 1,
  [int]$MaxIntervalSeconds = 30,
  [double]$BackoffFactor = 2.0,
  [int]$RebaselineAfterCleanCount,
  [switch]$ApplyRebaseline
  , [string]$CustomPercentiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'

function Test-CanonicalCli {
  if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
    throw "LVCompare.exe not found at canonical path: $canonical"
  }
  return $canonical
}

function Format-Duration([double]$seconds) {
  if ($seconds -lt 1) { return ('{0} ms' -f [math]::Round($seconds*1000,1)) }
  return ('{0:N3} s' -f $seconds)
}

function Invoke-ControlLoopScript {
  [CmdletBinding()]param(
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$Head,
    [int]$IntervalSeconds = 5,
    [int]$MaxIterations = 0,
    [switch]$SkipIfUnchanged,
    [string]$JsonLog,
    [string]$LvCompareArgs = '-nobdcosm -nofppos -noattr',
    [switch]$FailOnDiff,
    [switch]$Quiet,
    [scriptblock]$CompareExecutor,
    [switch]$BypassCliValidation,
    [switch]$UseEventDriven,
    [int]$DebounceMilliseconds = 250,
    [ValidateSet('None','Text','Markdown','Html')][string]$DiffSummaryFormat = 'None',
    [string]$DiffSummaryPath,
    [switch]$AdaptiveInterval,
    [int]$MinIntervalSeconds = 1,
    [int]$MaxIntervalSeconds = 30,
    [double]$BackoffFactor = 2.0,
    [int]$RebaselineAfterCleanCount,
    [switch]$ApplyRebaseline
    , [string]$CustomPercentiles
  )

  # Import module and delegate to its entrypoint to avoid function name collisions when dot-sourced
  if (-not (Get-Module -Name CompareLoop)) {
    $modulePath = Join-Path (Split-Path -Parent $PSCommandPath) '..' 'module' 'CompareLoop' 'CompareLoop.psd1'
    if (Test-Path -LiteralPath $modulePath) { Import-Module $modulePath -Force }
  }
  if (-not (Get-Command Invoke-IntegrationCompareLoop -ErrorAction SilentlyContinue)) {
    throw 'CompareLoop module not available; cannot execute loop.'
  }
  $invokeParams = @{}
  foreach ($k in @('Base','Head','IntervalSeconds','MaxIterations','SkipIfUnchanged','JsonLog','LvCompareArgs','FailOnDiff','Quiet','CompareExecutor','BypassCliValidation','UseEventDriven','DebounceMilliseconds','DiffSummaryFormat','DiffSummaryPath','AdaptiveInterval','MinIntervalSeconds','MaxIntervalSeconds','BackoffFactor','RebaselineAfterCleanCount','ApplyRebaseline','CustomPercentiles')) {
    if ($PSBoundParameters.ContainsKey($k)) { $invokeParams[$k] = $PSBoundParameters[$k] }
  }
  return & Invoke-IntegrationCompareLoop @invokeParams
}

# If executed as a script (not dot-sourced), run with bound parameters
if ($MyInvocation.InvocationName -ne '.') {
  $result = Invoke-ControlLoopScript @PSBoundParameters
  if (-not $Quiet) {
    Write-Host ("Iterations : {0}" -f $result.Iterations)
    Write-Host ("Diffs      : {0}" -f $result.DiffCount)
    Write-Host ("Errors     : {0}" -f $result.ErrorCount)
    Write-Host ("Avg Time   : {0:N3} s" -f $result.AverageSeconds)
    Write-Host ("Total Time : {0:N3} s" -f $result.TotalSeconds)
    if ($result.Mode) { Write-Host ("Mode       : {0}" -f $result.Mode) }
    if ($result.Percentiles) { Write-Host ("p50/p90/p99: {0}/{1}/{2} s" -f $result.Percentiles.p50,$result.Percentiles.p90,$result.Percentiles.p99) }
    if ($result.RebaselineApplied) { Write-Host "Rebaseline Applied at iteration $($result.RebaselineCandidate.TriggerIteration)" -ForegroundColor Yellow }
    if ($result.DiffSummary) { Write-Host "Diff Summary Generated (format $DiffSummaryFormat)" -ForegroundColor Yellow }
  }
}
