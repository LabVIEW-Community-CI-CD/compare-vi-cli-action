# CompareLoop Module Guide

This document describes the `CompareLoop` PowerShell module that encapsulates the enhanced integration compare control loop originally prototyped in `scripts/Integration-ControlLoop.ps1`.

## Overview

`Invoke-IntegrationCompareLoop` repeatedly runs NI LVCompare (or an injected executor) against a pair of LabVIEW VI files (Base/Head) to observe stability, latency, and diff churn during development or CI guard scenarios.

Key capabilities:

- Polling or event-driven (FileSystemWatcher) triggering
- Canonical LVCompare path enforcement (optional bypass for tests)
- Diff / error counting and rich per-iteration records
- Optional skip when unchanged (`-SkipIfUnchanged`)
- Optional fail-fast on first diff (`-FailOnDiff`) or on unexpected errors
- Percentile latency metrics (p50, p90, p99) & coarse histogram
- Adaptive polling backoff (`-AdaptiveInterval`) with min/max bounds
- Diff summary generation (Text / Markdown / HTML) + optional file output
- Re-baseline helper: detect extended clean streaks and optionally treat head as new base timestamp reference
- Dependency injection of compare executor for deterministic testing (bypass real CLI)

## Exported Functions

| Function | Purpose |
|----------|---------|
| `Invoke-IntegrationCompareLoop` | Run the compare loop with rich configuration options |
| `Test-CanonicalCli` | Validate canonical LVCompare install path exists |
| `Format-LoopDuration` | Utility formatting (ms vs seconds) |

## Parameter Reference (`Invoke-IntegrationCompareLoop`)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `Base` | string | (none) | Path to base VI (required unless `-SkipValidation -PassThroughPaths`) |
| `Head` | string | (none) | Path to head VI |
| `IntervalSeconds` | double | 5 | Polling delay (sleep or event wait timeout). Supports fractional seconds (converted to sec+ms). |
| `MaxIterations` | int | 0 | 0 = infinite until diff/ctrl+c/condition |
| `SkipIfUnchanged` | switch | off | Skip iteration if neither file timestamp changed (polling mode only) |
| `JsonLog` | string | (none) | Path for line-delimited JSON iteration records (not yet re‑implemented in module) |
| `LvCompareArgs` | string | `-nobdcosm -nofppos -noattr` | Additional CLI flags (tokenized respecting quotes) |
| `FailOnDiff` | switch | off | Break loop on first diff |
| `Quiet` | switch | off | Suppress verbose console output (module leaves formatting to caller) |
| `CompareExecutor` | scriptblock | (null) | DI: receives `-CliPath -Base -Head -Args` returns exit code (int) |
| `BypassCliValidation` | switch | off | Skip canonical existence check (tests, pre-validated env) |
| `SkipValidation` | switch | off | Bypass file presence checks (unit tests) |
| `PassThroughPaths` | switch | off | Do not resolve paths (unit tests / synthetic) |
| `UseEventDriven` | switch | off | Enable FileSystemWatcher event triggering + debounce |
| `DebounceMilliseconds` | int | 250 | Debounce consolidation window for events |
| `DiffSummaryFormat` | enum | `None` | Summary when diffs > 0. Allowed values: `None`, `Text`, `Markdown`, `Html` |
| `DiffSummaryPath` | string | (none) | Output path for diff summary text/markdown/html |
| `AdaptiveInterval` | switch | off | Enable exponential backoff on quiet iterations |
| `MinIntervalSeconds` | double | 1 | Lower bound for adaptive interval (fractional supported) |
| `MaxIntervalSeconds` | double | 30 | Upper bound for adaptive interval (fractional supported) |
| `BackoffFactor` | double | 2.0 | Growth factor for interval backoff |
| `RebaselineAfterCleanCount` | int | 0 | Threshold streak of clean (no diff/error) iterations to mark candidate |
| `ApplyRebaseline` | switch | off | When set, updates internal timestamp baseline when streak reached |
| `HistogramBins` | int | 5 | Number of bins for latency histogram (>=1) |
| `MetricsSnapshotEvery` | int | 0 | Emit per-iteration metrics snapshot every N iterations (0 disables) |
| `MetricsSnapshotPath` | string | (none) | Destination file for NDJSON (one JSON object per line) snapshots |
| `QuantileStrategy` | enum | `Exact` | Allowed: `Exact`, `StreamingP2`, `Hybrid`. See [Quantile Accuracy Guide](QUANTILE_ACCURACY.md) for tuning guidance. |
| `HybridExactThreshold` | int | 500 | Iteration count threshold where Hybrid would switch to streaming (future) |
| `CustomPercentiles` | string | (none) | Comma/space list of percentile values (0-100 exclusive) for dynamic metric keys (e.g. `"50,75,90,97.5,99.9"`) |
| `RunSummaryJsonPath` | string | (none) | If set, writes a final consolidated JSON object (schema `compare-loop-run-summary-v1`) after loop completion |

## Return Object Schema

The function returns a single PSCustomObject with fields:

```powershell
[Succeeded]               # bool: no error iterations encountered
[Iterations]              # total iterations executed
[DiffCount]               # number of diff iterations
[ErrorCount]              # number of error iterations (exit code not 0/1)
[AverageSeconds]          # mean duration of non-skipped iterations
[TotalSeconds]            # wall clock total loop time
[Records]                 # array of iteration records (see below)
[BasePath] / [HeadPath]   # resolved (or pass-through) paths
[Args]                    # original args string
[Mode]                    # 'Polling' or 'Event'
[Percentiles]             # object { p50,p90,p99 } or $null
[Histogram]               # array of bins with Start/End/Count or $null
[DiffSummary]             # rendered summary text/markdown/html or $null
[RebaselineCandidate]     # object { TriggerIteration, CleanStreak } or $null
[RebaselineApplied]       # bool whether rebaseline was performed
```

Iteration record example:

```powershell
@{
  iteration = 3
  diff = $false
  exitCode = 0
  status = 'OK'
  durationSeconds = 0.178
  skipped = $false
  skipReason = $null
  baseChanged = $false
  headChanged = $true
}
```

## Event-Driven Mode

When `-UseEventDriven` is set the loop:

1. Creates `FileSystemWatcher` instances for the containing directories of Base/Head.
2. Waits up to `IntervalSeconds` for an event (Changed/Created/Renamed).
3. Debounces additional events for `DebounceMilliseconds`.
4. Runs a compare only if one or more events were received; otherwise records a skipped iteration with `skipReason = 'no-change-event'`.

Fallback: if watcher initialization fails, it logs a warning (unless `-Quiet`) and reverts to polling mode.

## Adaptive Interval Strategy

With `-AdaptiveInterval`:

- Active iteration (diff, error, or not skipped) resets interval to `max(MinIntervalSeconds, IntervalSeconds)`.
- Quiet skipped iteration (no change) increases interval: `interval = min(MaxIntervalSeconds, ceil(interval * BackoffFactor))`.
- Sleep uses the evolving interval.

This reduces load when VIs are idle while remaining responsive when changes resume.

## Latency Metrics, Percentiles & Histogram Schema

Percentiles (p50, p90, p99) are computed over the set of non-skipped iteration durations (seconds, rounded to 3 decimals). Linear interpolation is used:

```text
rank = (p/100) * (N-1)
lo = floor(rank); hi = ceiling(rank)
value = samples[lo] * (1 - (rank-lo)) + samples[hi] * (rank-lo)
```

Histogram construction (linear binning):

1. Collect all non-zero duration samples into an array (`durSamples`).
2. Determine integer-ish bounds:
   - `min = floor(min(durSamples))`
   - `max = ceiling(max(durSamples))`; if `max <= min` then `max = min + 1` to avoid zero width.
3. Bin count: configurable via `-HistogramBins` (default 5).
4. Bin width: `(max - min) / bins`; if width <= 0 then width = 1.
5. Create bin objects:

  ```powershell
  [pscustomobject]@{ Index=0; Start=<double>; End=<double>; Count=0 }
  ```

1. For each duration `v` compute tentative index: `idx = floor((v - min) / width)` with upper clamp `bins-1`.
2. Increment `Count` for the resolved bin.

Properties emitted per bin:

| Field  | Meaning                                  |
|--------|-------------------------------------------|
| Index  | 0-based bin index                        |
| Start  | Inclusive lower bound (rounded to 3 dp)  |
| End    | Exclusive upper bound (rounded to 3 dp)  |
| Count  | Sample count placed in the bin           |

Notes:

- Skip-only runs emit `$null` for both `Percentiles` and `Histogram`.
- A single-sample run produces a histogram with one bin non-zero and percentiles all equal to that sample.
- Bin configuration is intentionally static for deterministic test assertions; future enhancement could introduce `-HistogramBins`.

Example (durations 0.021s, 0.055s, 0.090s, 0.015s, 0.060s) with 5 bins:

```text
Histogram (5 bins):
Index Start  End    Count
0     0      1      5
```

Because all samples < 1 second, min=0, max=1, width=0.2; all values fall into index 0 with this coarse resolution.

Percentiles might be (example values):

```text
p50=0.055; p90≈0.09; p99≈0.09
```

Rationale: coarse grouping eliminates noise yet still flags pathological slow spikes (if durations cross second boundaries).

## Re-Baseline Helper

Purpose: identify a sustained period of stability and optionally treat the head timestamp as a new base reference (does NOT copy files).

Behavior:

- Track consecutive clean iterations (no diff, no error, not skipped) in `cleanStreak`.
- When `cleanStreak >= RebaselineAfterCleanCount`:
  - Set `RebaselineCandidate` metadata.
  - If `-ApplyRebaseline` present, update `prevBaseTime` to current head timestamp (affects subsequent `baseChanged` detection) and set `RebaselineApplied = $true`.

This acts as a signal mechanism for external automation to consider copying or promoting head → base outside the loop.

## Diff Summary Generation

When one or more diffs occurred and `DiffSummaryFormat` != `None`, a simple summary is constructed. Example (Markdown):

```markdown
### VI Compare Diff Summary

*Base:* `C:\repos\main\ControlLoop.vi`  
*Head:* `C:\repos\feature\ControlLoop.vi`  
**Diff Iterations:** 4  
**Total Iterations:** 12
```

If `DiffSummaryPath` is provided the summary is written to that file (overwriting).

### HTML Summary Details

When `-DiffSummaryFormat Html` is selected the renderer produces a minimal, safe fragment (not a full HTML document) with the following structure:

```html
<h3>VI Compare Diff Summary</h3>
<ul>
  <li><strong>Base:</strong> C:\path\to\VI1.vi</li>
  <li><strong>Head:</strong> C:\path\to\VI2.vi</li>
  <li><strong>Diff Iterations:</strong> 4</li>
  <li><strong>Total Iterations:</strong> 12</li>
</ul>
```

Key characteristics:

1. Fragment Only: No `<html>`, `<head>`, or `<body>` wrapper so it can be embedded directly (e.g. into a larger report, GitHub Actions job summary, or a dashboard panel).
2. Deterministic Order: List items always appear in the order Base, Head, Diff Iterations, Total Iterations for stable test assertions and easy parsing.
3. HTML Encoding: All dynamic path/content values are HTML‑encoded (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&quot;`, `'` → `&#39;`). This prevents markup breakage or script injection if file paths contain special characters. (Verified by dedicated Pester tests covering ampersand encoding.)
4. Conditional Emission: The summary is generated only if `DiffCount > 0`. Runs with zero diffs leave `DiffSummary` = `$null` and do not write a file even if `DiffSummaryPath` was provided (tests assert the absence). This avoids misleading empty reports.
5. Overwrite Behavior: When `DiffSummaryPath` is specified an existing file is replaced atomically for the final run state.

Embedding example (GitHub Actions step) – write the fragment then append to the workflow summary:

```powershell
$result = Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 25 -IntervalSeconds 0.5 `
  -DiffSummaryFormat Html -DiffSummaryPath diff-summary.html -SkipValidation -PassThroughPaths -Quiet
if ($result.DiffSummary) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $result.DiffSummary }
```

Lightweight parsing example (PowerShell) to extract the diff count:

```powershell
$html = $result.DiffSummary
if ($html -match '<li><strong>Diff Iterations:</strong> (\d+)</li>') {
  $diffs = [int]$Matches[1]
  "Diff iterations: $diffs"
}
```

Testing Notes:

- Encoding is validated in `CompareLoop.HtmlDiffSummary.Tests.ps1` (ampersand case). Additional characters (`<`, `>` etc.) are implicitly covered by using the platform encoder.
- The absence case (no diffs) asserts both in‑memory `$null` and that no file is written when a path is provided.
- Fragment approach keeps future extension simple (e.g. adding latency stats) without breaking existing embeddings, but consumers should treat the content as opaque HTML rather than rely on inner text ordering beyond the documented list sequence.

## Dependency Injection Pattern

Provide a mock executor:

```powershell
$alwaysDiff = { param($CliPath,$Base,$Head,$Args) 1 }
Invoke-IntegrationCompareLoop -Base a -Head b -MaxIterations 3 -CompareExecutor $alwaysDiff -SkipValidation -PassThroughPaths -Quiet
```

Use cases:

- Unit tests (Pester) to cover diff/error branches
- Performance simulations without invoking LVCompare

## Unit Testing Flags

| Flag | Impact |
|------|--------|
| `-SkipValidation` | Skips file existence checks |
| `-PassThroughPaths` | Avoids `Resolve-Path`; allows synthetic labels |
| `-BypassCliValidation` | Skips canonical path presence check |

These should NOT be used in production automation.

## Exit Code Mapping

| Exit Code | Interpretation |
|-----------|---------------|
| 0 | No diff |
| 1 | Diff detected |
| Other | Error (counted; `status = 'ERROR'`) |
| -999 | Internal sentinel when process invocation fails before setting `$LASTEXITCODE` |

## Example: Event-Driven Markdown Summary with Adaptive Backoff

```powershell
Invoke-IntegrationCompareLoop `
  -Base 'C:\repos\main\ControlLoop.vi' `
  -Head 'C:\repos\feature\ControlLoop.vi' `
  -UseEventDriven `
  -DebounceMilliseconds 400 `
  -AdaptiveInterval -MinIntervalSeconds 1 -MaxIntervalSeconds 20 -BackoffFactor 1.8 `
  -DiffSummaryFormat Markdown -DiffSummaryPath diff-summary.md `
  -LvCompareArgs '-nobdcosm -nofppos -noattr' `
  -FailOnDiff
```

## Metrics Snapshots (NDJSON)

When `-MetricsSnapshotEvery N` and `-MetricsSnapshotPath <file>` are provided, the loop appends a compact JSON object every N iterations (line-delimited NDJSON).

### Snapshot Schema v2 (current)

Version `metrics-snapshot-v2` adds dynamic percentile support and optional histogram enrichment while retaining legacy top-level `p50/p90/p99` for backward compatibility.

```jsonc
{
  "schema": "metrics-snapshot-v2",
  "iteration": 12,
  "timestamp": "2025-01-15T12:34:56.789Z", // ISO 8601
  "diffCount": 2,
  "errorCount": 0,
  "totalSeconds": 2.417,        // cumulative wall time
  "averageSeconds": 0.201,       // running average (totalSeconds/iteration)
  "p50": 0.190,                  // legacy fixed percentiles remain
  "p90": 0.240,
  "p99": 0.260,
  "quantileStrategy": "Exact",  // Exact | StreamingReservoir | Hybrid
  "requestedPercentiles": [50,75,90,99], // echo of input list or default [50,90,99]
  "percentiles": {               // dynamic object; keys derived from requested list
    "p50": 0.190,
    "p75": 0.215,
    "p90": 0.240,
    "p99": 0.260
  },
  "histogram": [                 // present only when -IncludeSnapshotHistogram specified
    { "index": 0, "start": 0.15, "end": 0.19, "count": 3 },
    { "index": 1, "start": 0.19, "end": 0.23, "count": 7 },
    { "index": 2, "start": 0.23, "end": 0.27, "count": 2 }
  ]
}
```

Percentile label formatting:

- Each requested percentile value becomes `p{value}` with decimal points replaced by `_` (e.g. `97.5` → `p97_5`).
- Duplicate labels (after formatting) are ignored on insertion to keep object keys stable.

Backward compatibility:

- Top-level `p50/p90/p99` remain to avoid breaking existing parsers.
- If no samples have positive duration yet, dynamic `percentiles` may be omitted; consumers should treat this as "no data collected" rather than an error.

### Deprecated Schema v1

Older `metrics-snapshot-v1` objects (without `percentiles`, `requestedPercentiles`, `histogram`) may still exist in historical logs. New code should target v2.

Notes:

- Only iterations with a positive duration contribute to percentile calculations.
- `quantileStrategy` reflects the active percentile computation mode (Exact/StreamingReservoir/Hybrid).
- Streaming reservoir + hybrid modes approximate distribution with bounded memory and (for Hybrid) switch after an exact warm-up threshold.

## Final Run Summary JSON

When `-RunSummaryJsonPath <file>` is specified, the loop emits a single JSON document at completion capturing aggregate metrics and final distribution statistics.

### Schema: `compare-loop-run-summary-v1`

```jsonc
{
  "schema": "compare-loop-run-summary-v1",
  "timestamp": "2025-01-15T12:34:56.789Z",
  "iterations": 150,
  "diffCount": 4,
  "errorCount": 0,
  "averageSeconds": 0.187,
  "totalSeconds": 28.112,
  "quantileStrategy": "Exact",
  "requestedPercentiles": [50,75,90,97.5,99.9],
  "percentiles": {
    "p50": 0.180,
    "p75": 0.195,
    "p90": 0.230,
    "p97_5": 0.255,
    "p99_9": 0.290
  },
  "histogram": [
    { "Index": 0, "Start": 0, "End": 1, "Count": 150 }
  ],
  "mode": "Polling",
  "basePath": "C:/path/VI1.vi",
  "headPath": "C:/path/VI2.vi",
  "rebaselineApplied": false,
  "rebaselineCandidate": null
}
```

Notes:

- `requestedPercentiles` echoes the parsed/validated input list or defaults to `[50,90,99]` when omitted.
- `percentiles` object mirrors dynamic labeling rules (decimal → underscore) used in snapshots.
- `histogram` is identical to the return object's histogram, not recomputed separately.
- Consumers should tolerate additional fields in future minor schema evolutions; rely on `schema` value for version gating.

Example invocation:

```powershell
Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 200 -IntervalSeconds 0 `
  -CustomPercentiles '50,75,90,97.5,99.9' -HistogramBins 10 -RunSummaryJsonPath run-summary.json -Quiet
```

Parsing example (PowerShell):

```powershell
$summary = Get-Content run-summary.json -Raw | ConvertFrom-Json
"Final p90: $($summary.percentiles.p90) seconds"
```

## Future Enhancements (Open for Contribution)

- Streaming percentile implementation (P² algorithm) and Hybrid switching
- Rich HTML diff report integration hook
- Retry logic on transient CLI failures
- Webhook emission on diff events
- Alternative histogram modes (e.g., exponential buckets)
- Optional multi-file batch compare pipeline
- Memory retention controls (max stored records) for long runs

## Troubleshooting

| Symptom | Possible Cause | Mitigation |
|---------|----------------|------------|
| ValidationFailed return | Base/Head path incorrect | Verify paths or use `-SkipValidation` only in tests |
| ERROR iterations with unexpected exit codes | LVCompare internal errors | Inspect CLI logs / consider retry enhancement |
| Event mode never triggers | No filesystem events or watcher blocked | Fallback to polling (remove `-UseEventDriven`) |
| Percentiles null | No iterations executed (all skipped) | Ensure changes or disable `-SkipIfUnchanged` |
| Rebaseline never triggers | Threshold too high or diffs resetting streak | Lower `RebaselineAfterCleanCount` |

## License

This module is distributed under the root repository license (see `LICENSE`).

---
*Generated documentation for internal developer reference.*
