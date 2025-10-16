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
  Number of iterations to execute (0 = infinite until Ctrl+C). Default: $env:LOOP_MAX_ITERATIONS or 1.

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

.PARAMETER JsonLogPath
  When provided (or via env LOOP_JSON_LOG) each high-level event is appended as one line of JSON (NDJSON) with a timestamp and type.

.PARAMETER NoStepSummary
  Suppress appending diff summary fragment to $GITHUB_STEP_SUMMARY (or set env LOOP_NO_STEP_SUMMARY=1).

.PARAMETER NoConsoleSummary
  Suppress the human-readable console summary block (or set env LOOP_NO_CONSOLE_SUMMARY=1). JSON logging unaffected.

.PARAMETER DiffExitCode
  When provided (or env LOOP_DIFF_EXIT_CODE) use this exit code if the loop succeeds and diffs were detected (ErrorCount=0, DiffCount>0). Default behavior leaves exit code 0.

.PARAMETER JsonLogMaxBytes
  Max file size in bytes before rotation (env LOOP_JSON_LOG_MAX_BYTES). If exceeded a numbered roll is performed.

.PARAMETER JsonLogMaxRolls
  Maximum number of rotated log files to retain (env LOOP_JSON_LOG_MAX_ROLLS). Oldest removed after exceeding.

.PARAMETER JsonLogMaxAgeSeconds
  Max age in seconds before forcing a rotation on next write regardless of size (env LOOP_JSON_LOG_MAX_AGE_SECONDS).

.PARAMETER FinalStatusJsonPath
  Emit machine-readable final status JSON document (env LOOP_FINAL_STATUS_JSON) containing core metrics & schema.

.OUTPUTS
  Writes key result fields and optionally diff summary to stdout. Exit code 0 when Succeeded, 1 otherwise.

.EXAMPLES
  # Minimal (env must supply LV_BASE_VI & LV_HEAD_VI)
  pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1

  # Simulated diff soak with snapshots
  $env:LV_BASE_VI='VI1.vi'; $env:LV_HEAD_VI='VI2.vi'
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
  [string]$DiffSummaryFormat = $( if ($env:LOOP_DIFF_SUMMARY_FORMAT) { $env:LOOP_DIFF_SUMMARY_FORMAT } else { 'None' } ),
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
  , [ValidateSet('Quiet','Normal','Verbose','Debug')][string]$LogVerbosity = $( if ($env:LOOP_LOG_VERBOSITY) { $env:LOOP_LOG_VERBOSITY } else { 'Normal' } )
  , [string]$JsonLogPath = $env:LOOP_JSON_LOG
  , [switch]$NoStepSummary
  , [switch]$NoConsoleSummary
  , [int]$DiffExitCode = ($env:LOOP_DIFF_EXIT_CODE -as [int])
  , [int]$JsonLogMaxBytes = ($env:LOOP_JSON_LOG_MAX_BYTES -as [int])
  , [int]$JsonLogMaxRolls = ($env:LOOP_JSON_LOG_MAX_ROLLS -as [int])
  , [int]$JsonLogMaxAgeSeconds = ($env:LOOP_JSON_LOG_MAX_AGE_SECONDS -as [int])
  , [string]$FinalStatusJsonPath = $env:LOOP_FINAL_STATUS_JSON
  , [switch]$RenderReport
)

# Defaults / fallbacks
if (-not $MaxIterations) { $MaxIterations = 1 }
if ($null -eq $IntervalSeconds) { $IntervalSeconds = 0 }
if (-not $HistogramBins) { $HistogramBins = 0 }

try {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
} catch {
  $repoRoot = (Get-Location).Path
}

# Initialize switches from env when not explicitly passed
if (-not $PSBoundParameters.ContainsKey('FailOnDiff')) {
  if ($env:LOOP_FAIL_ON_DIFF) { if ($env:LOOP_FAIL_ON_DIFF -match '^(1|true)$') { $FailOnDiff = $true } }
  else { $FailOnDiff = $true }
}
if (-not $PSBoundParameters.ContainsKey('AdaptiveInterval')) {
  if ($env:LOOP_ADAPTIVE -and $env:LOOP_ADAPTIVE -match '^(1|true)$') { $AdaptiveInterval = $true }
}

# Honor suppression env flags if switches not explicitly passed
if (-not $PSBoundParameters.ContainsKey('NoStepSummary') -and $env:LOOP_NO_STEP_SUMMARY -match '^(1|true)$') { $NoStepSummary = $true }
if (-not $PSBoundParameters.ContainsKey('NoConsoleSummary') -and $env:LOOP_NO_CONSOLE_SUMMARY -match '^(1|true)$') { $NoConsoleSummary = $true }

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
if (-not $PSBoundParameters.ContainsKey('RenderReport') -and $DiffSummaryFormat -ne 'None') { $RenderReport = $true }

Import-Module (Join-Path $PSScriptRoot '../module/CompareLoop/CompareLoop.psd1') -Force

$preClean = $false
if ($env:LOOP_PRE_CLEAN -match '^(1|true)$') { $preClean = $true }
if ($preClean) {
  try {
    . (Join-Path $PSScriptRoot 'Ensure-LVCompareClean.ps1')
    $k1 = Stop-LVCompareProcesses -Quiet
    $k2 = Stop-LabVIEWProcesses -Quiet
    if ($k1 -gt 0 -or $k2 -gt 0) { Write-Host "Pre-cleaned LVCompare=$k1, LabVIEW=$k2 stray process(es)." -ForegroundColor DarkYellow }
  } catch {
    Write-Host "Pre-clean attempt failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
  }
}

$exec = $null
if ($CustomExecutor) { $exec = $CustomExecutor }
elseif ($simulate) {
  # Allow explicit simulation of exit code 0 (previous logic treated 0 as unset due to -not test)
  $exitCode = ($env:LOOP_SIMULATE_EXIT_CODE -as [int])
  if ([string]::IsNullOrWhiteSpace($env:LOOP_SIMULATE_EXIT_CODE)) { $exitCode = 1 }
  $delayMs = ($env:LOOP_SIMULATE_DELAY_MS -as [int]); if (-not $delayMs) { $delayMs = 5 }
  $localDelay = $delayMs; if (-not $localDelay) { $localDelay = 5 }
  $localExit = $exitCode
  # Lexical closure: variables from outer scope ($localDelay,$localExit) are captured automatically
  $exec = { param($CliPath,$Base,$Head,$ExecArgs) Start-Sleep -Milliseconds $localDelay; return $localExit }
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
if ($RenderReport) { $invokeParams.RenderReport = $true }

function Write-Detail {
  param([string]$Message,[string]$Level='Info')
  switch ($LogVerbosity) {
    'Quiet'   { if ($Level -eq 'Error') { Write-Host $Message } }
    'Normal'  { if ($Level -notin @('Debug','Trace')) { Write-Host $Message } }
    'Verbose' { if ($Level -ne 'Trace') { Write-Host $Message } }
    'Debug'   { Write-Host $Message }
  }
}

function Write-JsonEvent {
  param([string]$Type,[hashtable]$Data)
  if (-not $JsonLogPath) { return }
  $schemaVersion = 'loop-script-events-v1'
  $payload = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    type = $Type
    level = 'info'
    schema = $schemaVersion
  }
  if ($Data) { foreach ($k in $Data.Keys) { $payload[$k] = $Data[$k] } }
  Ensure-JsonLog -Path $JsonLogPath
  try { ($payload | ConvertTo-Json -Compress) | Add-Content -Path $JsonLogPath } catch { Write-Detail "Failed JSON log append: $($_.Exception.Message)" 'Error' }
}

function Invoke-LabVIEWCloser {
  param([string]$Context = 'post-loop')

  $closeScript = Join-Path $repoRoot 'tools' 'Close-LabVIEW.ps1'
  if (-not (Test-Path -LiteralPath $closeScript -PathType Leaf)) {
    Write-Detail "LabVIEW close skipped (script missing at $closeScript)." 'Debug'
    Write-JsonEvent 'labviewClose' @{ status='skipped'; reason='script-missing'; context=$Context; path=$closeScript }
    return
  }

  $version = @(
    $env:LOOP_LABVIEW_VERSION,
    $env:LABVIEW_VERSION,
    $env:MINIMUM_SUPPORTED_LV_VERSION
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $version) { $version = '2025' }

  $bitness = @(
    $env:LOOP_LABVIEW_BITNESS,
    $env:LABVIEW_BITNESS,
    $env:MINIMUM_SUPPORTED_LV_BITNESS
  ) | Where-Object { $_ } | Select-Object -First 1
  if (-not $bitness) { $bitness = '64' }

  Write-Detail "Invoking Close-LabVIEW.ps1 (version=$version, bitness=$bitness, context=$Context)." 'Debug'
  try {
    & $closeScript -MinimumSupportedLVVersion $version -SupportedBitness $bitness
    $exitCode = $LASTEXITCODE
    Write-JsonEvent 'labviewClose' @{
      status   = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
      exitCode = $exitCode
      version  = $version
      bitness  = $bitness
      context  = $Context
    }
    if ($exitCode -ne 0) {
      Write-Detail "Close-LabVIEW.ps1 exited with code $exitCode." 'Error'
    }
  } catch {
    Write-JsonEvent 'labviewClose' @{
      status  = 'exception'
      message = $_.Exception.Message
      version = $version
      bitness = $bitness
      context = $Context
    }
    Write-Detail "Close-LabVIEW.ps1 threw: $($_.Exception.Message)" 'Error'
  }
}

function Ensure-JsonLog {
  param([string]$Path)
  if (-not $Path) { return }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  if (-not (Test-Path $Path)) {
    New-Item -ItemType File -Path $Path | Out-Null
    # meta create event (cannot call Write-JsonEvent recursively before file exists safely)
    ($([ordered]@{ timestamp=(Get-Date).ToString('o'); type='meta'; action='create'; target=$Path; schema='loop-script-events-v1' }) | ConvertTo-Json -Compress) | Add-Content -Path $Path
    return
  }
  $needsRotate = $false
  if ($JsonLogMaxBytes -and (Get-Item $Path).Length -gt $JsonLogMaxBytes) { $needsRotate = $true }
  if ($JsonLogMaxAgeSeconds -and $JsonLogMaxAgeSeconds -gt 0) {
    $ageSec = (New-TimeSpan -Start (Get-Item $Path).CreationTimeUtc -End (Get-Date).ToUniversalTime()).TotalSeconds
    if ($ageSec -ge $JsonLogMaxAgeSeconds) { $needsRotate = $true }
  }
  if ($needsRotate) { Rotate-JsonLog -Path $Path }
}

function Rotate-JsonLog {
  param([string]$Path)
  try {
    $base = Split-Path -Leaf $Path
    $dir = Split-Path -Parent $Path
    $rolls = Get-ChildItem -Path $dir -Filter "$base.*.roll" -ErrorAction SilentlyContinue | Sort-Object Name
    $next = if ($rolls) { ([int]($rolls[-1].Name.Split('.')[-2]) + 1) } else { 1 }
    $rolled = Join-Path $dir "$base.$next.roll"
    Move-Item -Path $Path -Destination $rolled -Force
    New-Item -ItemType File -Path $Path | Out-Null
    ($([ordered]@{ timestamp=(Get-Date).ToString('o'); type='meta'; action='rotate'; from=$rolled; to=$Path; schema='loop-script-events-v1' }) | ConvertTo-Json -Compress) | Add-Content -Path $Path
    if ($JsonLogMaxRolls -and $JsonLogMaxRolls -gt 0) {
      $all = Get-ChildItem -Path $dir -Filter "$base.*.roll" | Sort-Object { $_.Name -replace '.*\\.(\d+)\.roll','$1' -as [int] }
      if ($all.Count -gt $JsonLogMaxRolls) {
        $remove = $all | Select-Object -First ($all.Count - $JsonLogMaxRolls)
        foreach ($r in $remove) { Remove-Item -Path $r.FullName -Force -ErrorAction SilentlyContinue }
      }
    }
  } catch {
    Write-Detail "Log rotation failed: $($_.Exception.Message)" 'Error'
  }
}

Write-Detail ("Resolved LogVerbosity=$LogVerbosity DryRun=$($DryRun.IsPresent) Simulate=$simulate") 'Debug'
Write-Detail ("Invocation parameters (pre-run):" )
Write-Detail (($invokeParams.Keys | Sort-Object | ForEach-Object { "  $_ = $($invokeParams[$_])" }) -join [Environment]::NewLine) 'Debug'
Write-JsonEvent 'plan' (@{ simulate=$simulate; dryRun=$DryRun.IsPresent; maxIterations=$MaxIterations; interval=$IntervalSeconds; diffSummaryFormat=$DiffSummaryFormat })

if ($DryRun) {
  Write-Detail 'Dry run requested; skipping Invoke-IntegrationCompareLoop execution.'
  # Show inferred file outputs
  if ($DiffSummaryPath) { Write-Detail "Would write diff summary to: $DiffSummaryPath" }
  if ($MetricsSnapshotEvery -gt 0) { Write-Detail "Would emit snapshots to: $MetricsSnapshotPath every $MetricsSnapshotEvery iteration(s)" }
  if ($RunSummaryJsonPath) { Write-Detail "Would write run summary JSON to: $RunSummaryJsonPath" }
  Write-JsonEvent 'dryRun' @{ diffSummaryPath=$DiffSummaryPath; snapshots=$MetricsSnapshotPath; runSummary=$RunSummaryJsonPath }
  exit 0
}

try {
  $result = Invoke-IntegrationCompareLoop @invokeParams
} catch {
  Invoke-LabVIEWCloser -Context 'invoke-exception'
  throw
}
Write-JsonEvent 'result' (@{ iterations=$result.Iterations; diffs=$result.DiffCount; errors=$result.ErrorCount; succeeded=$result.Succeeded })

# Final status JSON emission (independent of run summary JSON produced by loop if that param was set)
if ($FinalStatusJsonPath) {
  try {
    $obj = [ordered]@{
      schema = 'loop-final-status-v1'
      timestamp = (Get-Date).ToString('o')
      iterations = $result.Iterations
      diffs = $result.DiffCount
      errors = $result.ErrorCount
      succeeded = $result.Succeeded
      averageSeconds = $result.AverageSeconds
      totalSeconds = $result.TotalSeconds
      percentiles = $result.Percentiles
      histogram = $result.Histogram
      diffSummaryEmitted = [bool]$result.DiffSummary
      basePath = $result.BasePath
      headPath = $result.HeadPath
    }
    $json = $obj | ConvertTo-Json -Depth 5
    $finalDir = Split-Path -Parent $FinalStatusJsonPath
    if ($finalDir -and -not (Test-Path $finalDir)) { New-Item -ItemType Directory -Path $finalDir | Out-Null }
    Set-Content -Path $FinalStatusJsonPath -Value $json
    Write-Detail "Final status JSON: $FinalStatusJsonPath" 'Debug'
    Write-JsonEvent 'finalStatusEmitted' @{ path=$FinalStatusJsonPath }
  } catch {
    Write-Detail "Failed to write FinalStatusJsonPath: $($_.Exception.Message)" 'Error'
  }
}

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
if (-not $NoConsoleSummary) { $summaryLines | ForEach-Object { Write-Detail $_ } } else { Write-Detail 'Console summary suppressed (-NoConsoleSummary).' 'Debug' }

# Append diff summary fragment to GitHub step summary if running in Actions
if (-not $NoStepSummary -and $env:GITHUB_STEP_SUMMARY -and $result.DiffSummary) {
  try { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $result.DiffSummary; Write-JsonEvent 'stepSummaryAppended' @{ path=$env:GITHUB_STEP_SUMMARY } } catch { Write-Warning "Failed to append to GITHUB_STEP_SUMMARY: $($_.Exception.Message)" }
} elseif ($result.DiffSummary) {
  Write-Detail 'Step summary append skipped (suppressed or not in Actions).' 'Debug'
}

Invoke-LabVIEWCloser -Context 'post-loop'

# Exit code semantics: 0 when succeeded (even if diffs unless FailOnDiff terminated early), 1 if any errors encountered
if (-not $result.Succeeded) { exit 1 }
if ($DiffExitCode -and $result.DiffCount -gt 0 -and $result.ErrorCount -eq 0) { exit $DiffExitCode }
exit 0
\
