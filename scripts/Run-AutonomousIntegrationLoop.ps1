<#
.SYNOPSIS
  Autonomous integration compare loop runner for CI or local soak.

.DESCRIPTION
  Wraps Invoke-IntegrationCompareLoop providing environment driven defaults so it can
  be launched with zero parameters in a prepared environment. Intended for:
    * Long running CI soak jobs gathering latency/diff telemetry.
    * Developer guard loops (optionally fail on first diff).
    * HTML / Markdown / Text diff summary emission.

  The script is resilient: validates required inputs, surfaces a concise summary to stdout,
  and (optionally) writes snapshot & run summary JSON artifacts.

.PARAMETER Base
  Path to base VI (or label when using -SkipValidation -PassThroughPaths for dry runs).
  Default: $env:LV_BASE_VI

.PARAMETER Head
  Path to head VI (or label). Default: $env:LV_HEAD_VI

.PARAMETER MaxIterations
  Number of iterations to execute (0 = infinite until Ctrl+C). Default: $env:LOOP_MAX_ITERATIONS or 50.

.PARAMETER IntervalSeconds
  Delay between iterations (can be fractional). Default: $env:LOOP_INTERVAL_SECONDS or 0.

.PARAMETER DiffSummaryFormat
  None | Text | Markdown | Html. Default: $env:LOOP_DIFF_SUMMARY_FORMAT or None.

.PARAMETER DiffSummaryPath
  Path to write diff summary fragment (overwritten). Default: $env:LOOP_DIFF_SUMMARY_PATH or diff-summary.html/.md/.txt inferred from format when omitted.

.PARAMETER CustomPercentiles
  Comma/space list (exclusive 0..100) for additional percentile metrics. Default from $env:LOOP_CUSTOM_PERCENTILES.

.PARAMETER RunSummaryJsonPath
  Path for final run summary JSON. Default: $env:LOOP_RUN_SUMMARY_JSON or 'loop-run-summary.json' in current dir when set via env LOOP_EMIT_RUN_SUMMARY=1.

.PARAMETER MetricsSnapshotEvery
  Emit per-N iteration metrics snapshot lines when >0. Default: $env:LOOP_SNAPSHOT_EVERY.

.PARAMETER MetricsSnapshotPath
  File path for NDJSON snapshot emission. Default: $env:LOOP_SNAPSHOT_PATH or 'loop-snapshots.ndjson' when cadence >0 and path not provided.

.PARAMETER FailOnDiff
  Break loop on first diff. Default: $env:LOOP_FAIL_ON_DIFF = 'true'.

.PARAMETER AdaptiveInterval
  Enable backoff. Default: $env:LOOP_ADAPTIVE = 'false'.

.PARAMETER HistogramBins
  Bin count for latency histogram (0 disables). Default: $env:LOOP_HISTOGRAM_BINS.

.PARAMETER CustomExecutor
  Provide a scriptblock for dependency injection (testing / simulation). If omitted a real CLI invocation occurs.
  To force simulation via env set LOOP_SIMULATE=1.

.PARAMETER DryRun
  When set, validates environment/parameters, prints the resolved invocation plan, then exits without running the loop.

.PARAMETER LogVerbosity
  Controls internal script logging (not the loop's own data output). Values: Quiet | Normal | Verbose.
  Can be set via env LOOP_LOG_VERBOSITY. Quiet suppresses non-error informational lines; Verbose emits extra diagnostics.

.OUTPUTS
  Writes key result fields and optionally diff summary to stdout. Exit code 0 when Succeeded, 1 otherwise.

.EXAMPLES
  # Minimal (env must supply LV_BASE_VI & LV_HEAD_VI)
  pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1

  # Simulated diff soak with snapshots
  $env:LV_BASE_VI='Base.vi'; $env:LV_HEAD_VI='Head.vi'
  $env:LOOP_SIMULATE=1
  $env:LOOP_DIFF_SUMMARY_FORMAT='Html'
  $env:LOOP_MAX_ITERATIONS=25
  $env:LOOP_SNAPSHOT_EVERY=5
  pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1

.NOTES
  Set -Verbose for extra diagnostic output.
#>
[CmdletBinding()]
param(
  [string]$Base = $env:LV_BASE_VI,
  [string]$Head = $env:LV_HEAD_VI,
  [int]$MaxIterations = ($env:LOOP_MAX_ITERATIONS -as [int]),
  [double]$IntervalSeconds = ($env:LOOP_INTERVAL_SECONDS -as [double]),
  [ValidateSet('None','Text','Markdown','Html')]
  [string]$DiffSummaryFormat = (if ($env:LOOP_DIFF_SUMMARY_FORMAT) { $env:LOOP_DIFF_SUMMARY_FORMAT } else { 'None' }),
  [string]$DiffSummaryPath = $env:LOOP_DIFF_SUMMARY_PATH,
  [string]$CustomPercentiles = $env:LOOP_CUSTOM_PERCENTILES,
  [string]$RunSummaryJsonPath = $env:LOOP_RUN_SUMMARY_JSON,
  [int]$MetricsSnapshotEvery = ($env:LOOP_SNAPSHOT_EVERY -as [int]),
  [string]$MetricsSnapshotPath = $env:LOOP_SNAPSHOT_PATH,
  [switch]$FailOnDiff,
  [switch]$AdaptiveInterval,
  [int]$HistogramBins = ($env:LOOP_HISTOGRAM_BINS -as [int]),
  [scriptblock]$CustomExecutor
  , [switch]$DryRun
  , [ValidateSet('Quiet','Normal','Verbose')][string]$LogVerbosity = (if ($env:LOOP_LOG_VERBOSITY) { $env:LOOP_LOG_VERBOSITY } else { 'Normal' })
)

# Defaults / fallbacks
if (-not $MaxIterations) { $MaxIterations = 50 }
if ($null -eq $IntervalSeconds) { $IntervalSeconds = 0 }
if (-not $HistogramBins) { $HistogramBins = 0 }

# Initialize switches from env when not explicitly passed
if (-not $PSBoundParameters.ContainsKey('FailOnDiff')) {
  if ($env:LOOP_FAIL_ON_DIFF) { if ($env:LOOP_FAIL_ON_DIFF -match '^(1|true)$') { $FailOnDiff = $true } }
  else { $FailOnDiff = $true }
}
if (-not $PSBoundParameters.ContainsKey('AdaptiveInterval')) {
  if ($env:LOOP_ADAPTIVE -and $env:LOOP_ADAPTIVE -match '^(1|true)$') { $AdaptiveInterval = $true }
}

$simulate = $false
if ($env:LOOP_SIMULATE -match '^(1|true)$') { $simulate = $true }

if (-not $Base -or -not $Head) { Write-Error 'Base/Head not provided (set LV_BASE_VI & LV_HEAD_VI or pass -Base/-Head).'; exit 1 }

# Infer summary path if format chosen and no path provided
if (-not $DiffSummaryPath -and $DiffSummaryFormat -ne 'None') {
  $ext = switch ($DiffSummaryFormat) { 'Html' { 'html' } 'Markdown' { 'md' } default { 'txt' } }
  $DiffSummaryPath = "diff-summary.$ext"
}

# Infer snapshot path
if ($MetricsSnapshotEvery -gt 0 -and -not $MetricsSnapshotPath) { $MetricsSnapshotPath = 'loop-snapshots.ndjson' }

# Infer run summary path if env flag set
if (-not $RunSummaryJsonPath -and $env:LOOP_EMIT_RUN_SUMMARY -match '^(1|true)$') { $RunSummaryJsonPath = 'loop-run-summary.json' }

Import-Module (Join-Path $PSScriptRoot '../module/CompareLoop/CompareLoop.psd1') -Force

$exec = $null
if ($CustomExecutor) { $exec = $CustomExecutor }
elseif ($simulate) {
  $exitCode = ($env:LOOP_SIMULATE_EXIT_CODE -as [int]); if (-not $exitCode) { $exitCode = 1 }
  $delayMs = ($env:LOOP_SIMULATE_DELAY_MS -as [int]); if (-not $delayMs) { $delayMs = 5 }
  $exec = { param($CliPath,$Base,$Head,$ExecArgs) Start-Sleep -Milliseconds $using:delayMs; return $using:exitCode }
}

$invokeParams = @{
  Base = $Base
  Head = $Head
  MaxIterations = $MaxIterations
  IntervalSeconds = $IntervalSeconds
  DiffSummaryFormat = $DiffSummaryFormat
  DiffSummaryPath = $DiffSummaryPath
  FailOnDiff = $FailOnDiff
  HistogramBins = $HistogramBins
  Quiet = $true
}
if ($CustomPercentiles) { $invokeParams.CustomPercentiles = $CustomPercentiles }
if ($MetricsSnapshotEvery -gt 0) {
  $invokeParams.MetricsSnapshotEvery = $MetricsSnapshotEvery
  $invokeParams.MetricsSnapshotPath = $MetricsSnapshotPath
}
if ($RunSummaryJsonPath) { $invokeParams.RunSummaryJsonPath = $RunSummaryJsonPath }
if ($AdaptiveInterval) { $invokeParams.AdaptiveInterval = $true }
if ($exec) { $invokeParams.CompareExecutor = $exec; $invokeParams.SkipValidation = $true; $invokeParams.PassThroughPaths = $true; $invokeParams.BypassCliValidation = $true }

function Write-Detail {
  param([string]$Message,[string]$Level='Info')
  switch ($LogVerbosity) {
    'Quiet'   { if ($Level -eq 'Error') { Write-Host $Message } }
    'Normal'  { if ($Level -ne 'Debug') { Write-Host $Message } }
    'Verbose' { Write-Host $Message }
  }
}

Write-Detail ("Resolved LogVerbosity=$LogVerbosity DryRun=$($DryRun.IsPresent) Simulate=$simulate") 'Debug'
Write-Detail ("Invocation parameters (pre-run):" )
Write-Detail (($invokeParams.Keys | Sort-Object | ForEach-Object { "  $_ = $($invokeParams[$_])" }) -join [Environment]::NewLine) 'Debug'

if ($DryRun) {
  Write-Detail 'Dry run requested; skipping Invoke-IntegrationCompareLoop execution.'
  # Show inferred file outputs
  if ($DiffSummaryPath) { Write-Detail "Would write diff summary to: $DiffSummaryPath" }
  if ($MetricsSnapshotEvery -gt 0) { Write-Detail "Would emit snapshots to: $MetricsSnapshotPath every $MetricsSnapshotEvery iteration(s)" }
  if ($RunSummaryJsonPath) { Write-Detail "Would write run summary JSON to: $RunSummaryJsonPath" }
  exit 0
}

$result = Invoke-IntegrationCompareLoop @invokeParams

# Emit concise console summary
$summaryLines = @()
$summaryLines += '=== Integration Compare Loop Result ==='
$summaryLines += "Base: $($result.BasePath)"
$summaryLines += "Head: $($result.HeadPath)"
$summaryLines += "Iterations: $($result.Iterations) (Diffs=$($result.DiffCount) Errors=$($result.ErrorCount))"
if ($result.Percentiles) { $summaryLines += "Latency p50/p90/p99: $($result.Percentiles.p50)/$($result.Percentiles.p90)/$($result.Percentiles.p99) s" }
if ($result.DiffSummary) { $summaryLines += 'Diff summary fragment emitted.' }
if ($RunSummaryJsonPath -and (Test-Path $RunSummaryJsonPath)) { $summaryLines += "Run summary JSON: $RunSummaryJsonPath" }
if ($MetricsSnapshotEvery -gt 0 -and (Test-Path $MetricsSnapshotPath)) { $summaryLines += "Snapshots NDJSON: $MetricsSnapshotPath" }
$summaryLines | ForEach-Object { Write-Detail $_ }

# Append diff summary fragment to GitHub step summary if running in Actions
if ($env:GITHUB_STEP_SUMMARY -and $result.DiffSummary) {
  try { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $result.DiffSummary } catch { Write-Warning "Failed to append to GITHUB_STEP_SUMMARY: $($_.Exception.Message)" }
}

# Exit code semantics: 0 when succeeded (even if diffs unless FailOnDiff terminated early), 1 if any errors encountered
if (-not $result.Succeeded) { exit 1 } else { exit 0 }
