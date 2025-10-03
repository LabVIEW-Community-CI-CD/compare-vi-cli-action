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

# Honor suppression env flags if switches not explicitly passed
if (-not $PSBoundParameters.ContainsKey('NoStepSummary') -and $env:LOOP_NO_STEP_SUMMARY -match '^(1|true)$') { $NoStepSummary = $true }
if (-not $PSBoundParameters.ContainsKey('NoConsoleSummary') -and $env:LOOP_NO_CONSOLE_SUMMARY -match '^(1|true)$') { $NoConsoleSummary = $true }

$simulate = $false
if ($env:LOOP_SIMULATE -match '^(1|true)$') { $simulate = $true }

if (-not $Base -or -not $Head) { Write-Error 'Base/Head not provided (set LV_BASE_VI & LV_HEAD_VI or pass -Base/-Head).'; exit 1 }

# Preflight: identical leaf names in different directories trigger LVCompare modal prompting; proactively guard to maintain deterministic automation.
try {
  $baseFull = if ($Base) { (Resolve-Path -LiteralPath $Base -ErrorAction Stop).Path } else { $null }
  $headFull = if ($Head) { (Resolve-Path -LiteralPath $Head -ErrorAction Stop).Path } else { $null }
  if ($baseFull -and $headFull -and ($baseFull -ne $headFull)) {
    $baseLeaf = Split-Path -Leaf $baseFull
    $headLeaf = Split-Path -Leaf $headFull
    if ($baseLeaf -ieq $headLeaf) {
      $conflictMsg = "Identical VI filename conflict: '$baseLeaf' in distinct directories. LVCompare cannot compare two different-path VIs with same name without user dialog. Base=$baseFull Head=$headFull"
      Write-JsonEvent 'identicalLeafConflict' (@{ base=$baseFull; head=$headFull; leaf=$baseLeaf })
      Write-Error $conflictMsg
      exit 1
    }
  }
  # Guard: identical absolute paths (Base==Head) produce no meaningful diff and historically caused redundant launches.
  # Default behavior: abort early unless explicitly allowed (LOOP_ALLOW_IDENTICAL_PATHS=1) so CI surfaces misconfiguration.
  $allowIdentical = $false; if ($env:LOOP_ALLOW_IDENTICAL_PATHS -match '^(1|true)$') { $allowIdentical = $true }
  if ($baseFull -and $headFull -and ($baseFull -eq $headFull) -and -not $allowIdentical) {
    Write-JsonEvent 'identicalPathAbort' (@{ path=$baseFull })
    Write-Error "Identical Base and Head path provided ($baseFull). Set LOOP_ALLOW_IDENTICAL_PATHS=1 to permit short-circuit runs or supply distinct VIs."
    exit 1
  }
} catch {
  # Resolution failures fall through; module will handle validation later
}

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
$script:CompareInvocationCount = 0
$script:StrayLvCompareTotalKilled = 0
$script:MultiInstanceOccurrenceCount = 0
$script:MultiInstanceMaxConcurrent = 0
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
  $origSimExec = $exec
  $exec = { param($CliPath,$Base,$Head,$ExecArgs) $script:CompareInvocationCount++; & $origSimExec $CliPath $Base $Head $ExecArgs }
}

# Optional LabVIEW auto-close wrapping
$closeLabVIEW = $false
if ($env:LOOP_CLOSE_LABVIEW -match '^(1|true)$') { $closeLabVIEW = $true }
$closeGraceMs = ($env:LOOP_CLOSE_LABVIEW_GRACE_MS -as [int]); if (-not $closeGraceMs -or $closeGraceMs -lt 0) { $closeGraceMs = 5000 }
$forceKillLabVIEW = $false
if ($env:LOOP_CLOSE_LABVIEW_FORCE -match '^(1|true)$') { $forceKillLabVIEW = $true }

# If no executor defined yet (real CLI path) but auto-close requested, create a baseline executor first so we can uniformly wrap
if (-not $exec) {
  # Baseline real executor defers to canonical invocation semantics used by module internal default
  $exec = {
    param($CliPath,$Base,$Head,$ExecArgs)
    $script:CompareInvocationCount++
    $psi = New-Object System.Diagnostics.ProcessStartInfo
  # Enforce 64-bit LVCompare assumption: ignore any accidental 32-bit path variants by normalizing to canonical path if provided
  $canonical = 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
  if ($CliPath -and (Test-Path $CliPath) -and ($CliPath -ne $canonical) -and (Test-Path $canonical)) { $psi.FileName = $canonical } else { $psi.FileName = $CliPath }
    $psi.UseShellExecute = $false
    $psi.ArgumentList.Add($Base)
    $psi.ArgumentList.Add($Head)
    if ($ExecArgs) { foreach ($a in $ExecArgs) { $psi.ArgumentList.Add($a) } }
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
      $p.WaitForExit()
      return $p.ExitCode
    } finally {
      try { $p.Close() } catch {}
      try { $p.Dispose() } catch {}
    }
  }
}

if ($closeLabVIEW) {
  $innerExec = $exec
  # Capture needed outer variables into locals to avoid reliance on $using: in closure (not remoting scenario)
  $localCloseLabVIEW = $closeLabVIEW
  $localForceKillLabVIEW = $forceKillLabVIEW
  $localCloseGraceMs = $closeGraceMs
  $exec = {
    param($CliPath,$Base,$Head,$ExecArgs)
    # Execute inner executor first
    $exitCode = & $innerExec $CliPath $Base $Head $ExecArgs
    $attempted = 0; $closed = 0; $killed = 0
    $forceKilled = 0
    $strayLvCompareKilled = 0; $strayLvCompareDetected = 0
    try {
      $procs = Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue
      if ($procs) {
        foreach ($p in $procs) {
          $attempted++
          try {
            $didClose = $false
            if ($p -and ($p | Get-Member -Name 'CloseMainWindow' -ErrorAction SilentlyContinue)) {
              $didClose = $p.CloseMainWindow()
            }
            if ($didClose) {
              if (-not ($p.WaitForExit($localCloseGraceMs))) { $p.Kill(); $killed++ } else { $closed++ }
            } else {
              # Fallback to Kill when CloseMainWindow not available or returns false
              $p.Kill(); $killed++
            }
          } catch { $killed++ } finally { try { $p.Close() } catch {}; try { $p.Dispose() } catch {} }
        }
      }
    } catch {
      # swallow; logging handled via JSON event below
    }
  if ($localCloseLabVIEW -and $localForceKillLabVIEW) {
      # Aggressive taskkill fallback to ensure no dialogs block subsequent iterations
      try {
        $tk = Start-Process -FilePath 'taskkill.exe' -ArgumentList '/F','/IM','LabVIEW.exe','/T' -NoNewWindow -PassThru -ErrorAction Stop
        $tk.WaitForExit(); if ($tk.ExitCode -eq 0) { $forceKilled = 1 }
      } catch { }
    }
    # Detect stray 32-bit LVCompare processes (Machine=I386) and kill them to avoid modal dialog side-effects
    $alive64 = 0
    try {
      $lvcs = Get-Process -Name 'LVCompare' -ErrorAction SilentlyContinue
      foreach ($l in $lvcs) {
        try {
          $strayLvCompareDetected++
          # Inspect image headers quickly (best-effort). Access MainModule may fail under restricted perms.
          $path = $null
          try { $path = $l.MainModule.FileName } catch {}
          if ($path -and (Test-Path $path)) {
            $fs = [System.IO.File]::Open($path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
            try {
              $fs.Seek(0x3C,[System.IO.SeekOrigin]::Begin) | Out-Null
              $pe = New-Object System.IO.BinaryReader($fs)
              $offset = $pe.ReadInt32(); $fs.Seek($offset+4,[System.IO.SeekOrigin]::Begin) | Out-Null
              $machine = $pe.ReadUInt16()
              if ($machine -eq 0x014C) { # 32-bit stray
                $l.Kill(); $strayLvCompareKilled++
              } elseif ($machine -eq 0x8664) { # 64-bit survivor
                $alive64++
              }
            } finally { try { $fs.Close() } catch {}; try { $fs.Dispose() } catch {} }
          }
        } catch {
          # Ignore individual inspection failures
        } finally { try { $l.Close() } catch {}; try { $l.Dispose() } catch {} }
      }
    } catch {}
    if ($strayLvCompareKilled -gt 0) {
      # Emit event only when at least one stray 32-bit instance was actually terminated
      Write-JsonEvent 'lvcompareStrayKill' (@{ detected=$strayLvCompareDetected; killed=$strayLvCompareKilled })
    }
    if ($alive64 -gt 1) {
      # Track multi-instance occurrences (only counting healthy 64-bit simultaneous instances)
      try {
        $script:MultiInstanceOccurrenceCount++
        if ($alive64 -gt $script:MultiInstanceMaxConcurrent) { $script:MultiInstanceMaxConcurrent = $alive64 }
      } catch {}
      Write-JsonEvent 'lvcompareMultiInstance' (@{ concurrent=$alive64 })
    }
    try { $script:StrayLvCompareTotalKilled += $strayLvCompareKilled } catch { }
    if ($localCloseLabVIEW) { Write-JsonEvent 'labviewCloseAttempt' (@{ attempted=$attempted; closed=$closed; killed=$killed; forceKill=$localForceKillLabVIEW; forceKillSuccess=$forceKilled; graceMs=$localCloseGraceMs }) }
    return $exitCode
  }
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
Write-Detail ("Invocation parameters (pre-run):") 'Info'
Write-Detail (($invokeParams.Keys | Sort-Object | ForEach-Object { "  $_ = $($invokeParams[$_])" }) -join [Environment]::NewLine) 'Info'
Write-Detail ("VI1: $Base | VI2: $Head | Iterations: $MaxIterations | IntervalSeconds: $IntervalSeconds | DiffSummaryFormat: $DiffSummaryFormat | FailOnDiff=$FailOnDiff") 'Info'
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

$result = Invoke-IntegrationCompareLoop @invokeParams
Write-JsonEvent 'result' (@{ iterations=$result.Iterations; diffs=$result.DiffCount; errors=$result.ErrorCount; succeeded=$result.Succeeded; basePath=$result.BasePath; headPath=$result.HeadPath })

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
$summaryLines += "VI1: $($result.BasePath)"
$summaryLines += "VI2: $($result.HeadPath)"
$summaryLines += "Iterations: $($result.Iterations) (Diffs=$($result.DiffCount) Errors=$($result.ErrorCount))"
if ($result.Percentiles) { $summaryLines += "Latency p50/p90/p99: $($result.Percentiles.p50)/$($result.Percentiles.p90)/$($result.Percentiles.p99) s" }
if ($result.DiffSummary) { $summaryLines += 'Diff summary fragment emitted.' }
if ($RunSummaryJsonPath -and (Test-Path $RunSummaryJsonPath)) { $summaryLines += "Run summary JSON: $RunSummaryJsonPath" }
if ($MetricsSnapshotEvery -gt 0 -and (Test-Path $MetricsSnapshotPath)) { $summaryLines += "Snapshots NDJSON: $MetricsSnapshotPath" }
if ($closeLabVIEW) { $summaryLines += "Auto-close LabVIEW enabled (grace=${closeGraceMs}ms forceKill=$forceKillLabVIEW)" }
if ($script:StrayLvCompareTotalKilled -gt 0) { $summaryLines += "Stray 32-bit LVCompare killed (cumulative): $script:StrayLvCompareTotalKilled" }
if ($script:MultiInstanceOccurrenceCount -gt 0) { $summaryLines += "Multiple LVCompare instances observed: Occurrences=$script:MultiInstanceOccurrenceCount MaxConcurrent=$script:MultiInstanceMaxConcurrent" }

# Emit invocation count summary (integrity check for duplicate LVCompare spawning)
Write-JsonEvent 'compareInvocationSummary' (@{ invocations=$script:CompareInvocationCount; iterations=$result.Iterations })
if ($script:CompareInvocationCount -gt $result.Iterations) {
  $summaryLines += "Warning: Invocation count ($script:CompareInvocationCount) exceeds iteration count ($($result.Iterations)) — potential duplicate spawns detected." 
}

# Contextual troubleshooting hints (lightweight, deterministic ordering)
$hints = @()
if ($result.ErrorCount -gt 0) { $hints += 'Errors encountered: inspect earlier stderr/JSON events; non 0/1 exit codes from LVCompare count as errors.' }
elseif ($result.DiffCount -eq 0 -and $result.Iterations -gt 0 -and $FailOnDiff) { $hints += 'No diffs found; FailOnDiff enabled so loop would have stopped early if a diff occurred.' }
if ($result.Iterations -lt 3 -and $result.Percentiles) { $hints += 'Low iteration count may make percentile metrics noisy; increase MaxIterations for stable latency statistics.' }
if (-not $simulate -and -not $closeLabVIEW) { $hints += 'Consider enabling LOOP_CLOSE_LABVIEW=1 to mitigate residual LabVIEW state in long soaks.' }
if ($simulate) { $hints += 'Simulation mode active (LOOP_SIMULATE=1); latency numbers are synthetic.' }
if ($hints.Count -gt 0) { $summaryLines += '--- Troubleshooting Hints ---'; $summaryLines += $hints }
if (-not $NoConsoleSummary) { $summaryLines | ForEach-Object { Write-Detail $_ } } else { Write-Detail 'Console summary suppressed (-NoConsoleSummary).' 'Debug' }

# Append diff summary fragment to GitHub step summary if running in Actions
if (-not $NoStepSummary -and $env:GITHUB_STEP_SUMMARY -and $result.DiffSummary) {
  try { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $result.DiffSummary; Write-JsonEvent 'stepSummaryAppended' @{ path=$env:GITHUB_STEP_SUMMARY } } catch { Write-Warning "Failed to append to GITHUB_STEP_SUMMARY: $($_.Exception.Message)" }
} elseif ($result.DiffSummary) {
  Write-Detail 'Step summary append skipped (suppressed or not in Actions).' 'Debug'
}

# Exit code semantics: 0 when succeeded (even if diffs unless FailOnDiff terminated early), 1 if any errors encountered
if (-not $result.Succeeded) { exit 1 }
if ($DiffExitCode -and $result.DiffCount -gt 0 -and $result.ErrorCount -eq 0) { exit $DiffExitCode }
exit 0
