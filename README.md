# Compare VI (composite) GitHub Action

<!-- ci: bootstrap status checks -->

[![Validate](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml)
[![Smoke test](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml)
[![Test (mock)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/test-mock.yml)
[![Marketplace](https://img.shields.io/badge/GitHub%20Marketplace-Action-blue?logo=github)](https://github.com/marketplace/actions/compare-vi-cli-action)

## Purpose

This repository provides a **composite GitHub Action** for comparing two LabVIEW `.vi` files
using National Instruments' LVCompare CLI tool. It enables CI/CD workflows to detect
differences between LabVIEW virtual instruments, making it easy to integrate LabVIEW code
reviews and diff checks into automated GitHub Actions workflows.

The action wraps the `LVCompare.exe` command-line interface with intelligent path
resolution, flexible argument pass-through, and structured output formats suitable for
workflow branching and reporting. It supports both single-shot comparisons and
experimental loop mode for latency profiling and stability testing.

**Key Features:**

- **Simple Integration**: Drop-in action for self-hosted Windows runners with LabVIEW installed
- **Flexible Configuration**: Full pass-through of LVCompare CLI flags via `lvCompareArgs`
- **Structured Outputs**: Exit codes, diff status, timing metrics, and command audit trails
- **CI-Friendly**: Automatic step summaries, JSON artifacts, and configurable fail-on-diff behavior
- **Loop Mode (Experimental)**: Aggregate metrics, percentile latencies, and histogram generation for performance analysis

Validated with LabVIEW 2025 Q3 on self-hosted Windows runners. See also:
[`CHANGELOG.md`](./CHANGELOG.md) and the release workflow at
`.github/workflows/release.yml`.

> **Breaking Change (v0.5.0)**: Legacy artifact names `Base.vi` / `Head.vi` are no longer supported. Use `VI1.vi` / `VI2.vi` exclusively. Public action input names (`base`, `head`) and environment variables (`LV_BASE_VI`, `LV_HEAD_VI`) remain unchanged.
>
> Note: Any remaining mentions of `Base.vi` / `Head.vi` in this repository are retained strictly for historical or migration timeline context (e.g., CHANGELOG). They must not appear in new examples, workflows, or regenerated artifacts.

## Requirements

- Self-hosted Windows runner with LabVIEW 2025 Q3 installed and licensed
- `LVCompare.exe` installed at the **canonical path**: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- Only the canonical path is supported; paths via `PATH`, `LVCOMPARE_PATH`, or `lvComparePath` must resolve to this exact location

## Quick Start

### Basic Usage

```yaml
jobs:
  compare:
    runs-on: [self-hosted, Windows]
    steps:
      - uses: actions/checkout@v5
      - name: Compare VIs
        id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
        with:
          base: path/to/VI1.vi
          head: path/to/VI2.vi
          fail-on-diff: true

      - name: Act on result
        if: steps.compare.outputs.diff == 'true'
        shell: pwsh
        run: |
          Write-Host 'Differences detected.'
```

### Action Inputs

- `base` (required): Path to base `.vi` file
- `head` (required): Path to head `.vi` file
- `lvComparePath` (optional): Full path to `LVCompare.exe` if not on `PATH`
- `lvCompareArgs` (optional): Extra CLI flags for `LVCompare.exe` (space-delimited; quotes supported)
- `fail-on-diff` (optional, default `true`): Fail the job if differences are found
- `working-directory` (optional): Directory to run the command from; relative `base`/`head` are resolved from here
- `loop-enabled` (optional, default `false`): Enable experimental loop mode for performance testing

### Action Outputs

- `diff`: `true|false` whether differences were detected (0 = no diff, 1 = diff)
- `exitCode`: Raw exit code from the CLI
- `cliPath`: Resolved path to the executable
- `command`: Exact command line executed (quoted) for auditing
- `compareDurationSeconds`: Elapsed execution time (float, seconds)
- `compareDurationNanoseconds`: High-resolution elapsed time in nanoseconds
- `compareSummaryPath`: Path to JSON summary file (comparison metadata)
- `shortCircuitedIdentical`: `true|false` short‑circuit when `base` and `head` resolve identically (no process spawned)

Loop mode outputs (when `loop-enabled: true`): `iterations`, `diffCount`, `errorCount`,
`averageSeconds`, `totalSeconds`, `p50`, `p90`, `p99`, `quantileStrategy`,
`streamingWindowCount`, `loopResultPath`, `histogramPath`.

See [`docs/action-outputs.md`](./docs/action-outputs.md) for complete output documentation.

### Exit Codes and Behavior

- **Exit code mapping**: 0 = no diff, 1 = diff detected, any other code = failure
- **Identical path short-circuit**: If `base` and `head` resolve to the exact same absolute
  path, the action skips invoking LVCompare and emits
  `shortCircuitedIdentical=true`, `diff=false`, `exitCode=0`.
- **Same filename / different directories**: LVCompare cannot compare two different VIs
  with the *same leaf filename*. The action fails early with an explanatory error instead
  of triggering an IDE dialog.

### (Deprecated heading placeholder removed)

```yaml
  - name: Compare VIs
    id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
    with:
  base: VI1.vi
  head: VI1.vi  # Intentional identical path
      fail-on-diff: true

  - name: Handle identical-path short-circuit
    if: steps.compare.outputs.shortCircuitedIdentical == 'true'
    shell: pwsh
    run: |
      Write-Host 'Identical file comparison short-circuited; no diff expected.'

  - name: Handle real diff
    if: steps.compare.outputs.shortCircuitedIdentical != 'true' && steps.compare.outputs.diff == 'true'
    shell: pwsh
    run: |
      Write-Host 'Real differences detected.'
```

- **Always-emit outputs**: `diff`, `exitCode`, `cliPath`, `command` are always emitted
  even when the step fails, to support workflow branching and diagnostics.
- **Step summary**: A structured run report is appended to `$GITHUB_STEP_SUMMARY` with
  working directory, resolved paths, CLI path, command, exit code, and diff result.

## Advanced Configuration

### Working with lvCompareArgs

The `lvCompareArgs` input accepts space-delimited CLI flags with full quote support for paths containing spaces.

For comprehensive documentation on LVCompare CLI flags and Git integration, see [`docs/knowledgebase/LVCompare-Git-CLI-Guide_Windows-LabVIEW-2025Q3.md`](./docs/knowledgebase/LVCompare-Git-CLI-Guide_Windows-LabVIEW-2025Q3.md).

**Recommended noise filters** (reduce cosmetic diff churn):

```yaml
lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

- `-nobdcosm` - Ignore block diagram cosmetic changes (position/size/appearance)
- `-nofppos` - Ignore front panel object position/size changes
- `-noattr` - Ignore VI attribute changes

**LabVIEW version selection:**

```yaml
lvCompareArgs: '-lvpath "C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe"'
```

**Other common patterns:**

```yaml
# Path with spaces
lvCompareArgs: "--flag \"C:\\Path With Spaces\\out.txt\""

# Multiple flags
lvCompareArgs: "-nobdcosm -nofppos -noattr -lvpath \"C:\\Program Files\\National Instruments\\LabVIEW 2025\\LabVIEW.exe\""

# Environment-driven values
lvCompareArgs: "--log \"${{ runner.temp }}\\lvcompare.log\""
```

### Using working-directory

When your VIs are in a subdirectory, use `working-directory` to avoid repeating path prefixes:

```yaml
- name: Compare VIs
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    working-directory: my-labview-project
  base: src/VI1.vi
  head: src/VI2.vi
    lvCompareArgs: "-nobdcosm -nofppos -noattr"
```

### Path Resolution and UNC Paths

- The action resolves `base`/`head` to absolute paths before invoking LVCompare
- Relative paths are resolved from `working-directory` if set, otherwise from the repository root
- For long-path or UNC issues, consider:
  - Using shorter workspace-relative paths via `working-directory`
  - Mapping a drive on self-hosted runners for long UNC prefixes
  - Ensuring your LabVIEW/Windows environment supports long paths

## HTML Comparison Reports

For CI/CD pipelines and code reviews, you can generate HTML comparison reports using **LabVIEWCLI** (requires LabVIEW 2025 Q3 or later):

```powershell
# Generate single-file HTML report
LabVIEWCLI -OperationName CreateComparisonReport `
  -vi1 "path\to\VI1.vi" -vi2 "path\to\VI2.vi" `
  -reportType HTMLSingleFile -reportPath "CompareReport.html" `
  -nobdcosm -nofppos -noattr
```

**Benefits:**

- Self-contained HTML file suitable for artifact upload
- Visual diff output for code reviews
- Works with recommended noise filter flags
- Can be integrated into workflows for automated comparison reporting

See the knowledgebase guide for more details on HTML report generation.

HTML diff iteration summary (module)

The `CompareLoop` module can emit a concise diff iteration summary after a run when at
least one diff was observed via the `-DiffSummaryFormat` parameter. Supported formats:
`Text`, `Markdown`, `Html`.

When `Html` is selected a minimal fragment (no `<html>` wrapper) is produced:

```html
<h3>VI Compare Diff Summary</h3>
<ul>
  <li><strong>VI1:</strong> C:\path\to\VI1.vi</li>
  <li><strong>VI2:</strong> C:\path\to\VI2.vi</li>
  <li><strong>Diff Iterations:</strong> 4</li>
  <li><strong>Total Iterations:</strong> 12</li>
</ul>
```

Guarantees & behavior:

- Only created when `DiffCount > 0`; otherwise `DiffSummary` is `$null` and no file is written (even if `-DiffSummaryPath` supplied).
- All dynamic values (paths, counts) are HTML‑encoded (`&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, quotes, apostrophes) to prevent markup breakage.
- Deterministic ordering of list items for stable parsing.
- Safe to append directly to `$GITHUB_STEP_SUMMARY` for GitHub Actions job summaries.

Example (synthetic diff loop, embedding in Actions summary):

```powershell
Import-Module ./module/CompareLoop/CompareLoop.psd1 -Force
# Simulated executor returning diff (exit code 1)
$diffExec = { param($c,$b,$h,$a) 1 }
$r = Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 5 -IntervalSeconds 0 `
  -CompareExecutor $diffExec -SkipValidation -PassThroughPaths -BypassCliValidation `
  -DiffSummaryFormat Html -DiffSummaryPath diff-summary.html -Quiet
if ($r.DiffSummary) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $r.DiffSummary }
```

Quick regex extraction of diff count:

### Workflow Branching & Short-Circuit Examples

Below are practical GitHub Actions workflow patterns showing how to branch on:

1. Identical path short-circuit (`shortCircuitedIdentical`)
2. Real diff detection (`diff`)
3. Loop diff summary emission (when using the loop module separately)

Branching decision matrix:

| Scenario | `shortCircuitedIdentical` | `diff` | `exitCode` | Interpretation | Typical Next Step |
|----------|---------------------------|--------|-----------|----------------|-------------------|
| Identical paths (preflight short-circuit) | true | false | 0 | Comparison skipped (paths identical) | Log & skip diff-dependent steps |
| Different paths, no differences | false | false | 0 | Successful compare, no diff | Proceed with downstream build/test |
| Different paths, differences found | false | true | 1 | Successful compare, diff present | Produce/report diff artifacts, maybe fail if policy requires |
| CLI error / unexpected exit (e.g. missing file, non 0/1) | false | (not reliable) | >1 or <0 | Failure in LVCompare invocation | Surface logs, stop or mark job failed |
| Loop mode run (any iteration mix) | always false | (aggregate not exposed as `diff`) | 0 (loop script) | Loop orchestrated; per-iteration diffs summarized separately | Parse loop summary / diff fragment |

Loop mode note: The composite action sets `shortCircuitedIdentical=false` in loop mode
because comparisons are iterative and may involve varying paths or simulated executors;
identical-path short-circuit only applies to the single-run path.

Basic short-circuit vs real diff (single run):

```yaml
  - name: Compare VIs
    id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
    with:
  base: VI1.vi
  head: VI1.vi  # Intentional identical path
      fail-on-diff: true

  - name: Handle identical-path short-circuit
    if: steps.compare.outputs.shortCircuitedIdentical == 'true'
    shell: pwsh
    run: |
      Write-Host 'Identical file comparison short-circuited; no diff expected.'

  - name: Handle real diff
    if: steps.compare.outputs.shortCircuitedIdentical != 'true' && steps.compare.outputs.diff == 'true'
    shell: pwsh
    run: |
      Write-Host 'Real differences detected.'
```

Advanced (extracting diff iteration count from loop HTML fragment — when running the loop separately and appending its summary):

```powershell
if ($r.DiffSummary -match '<li><strong>Diff Iterations:</strong> (\d+)</li>') { [int]$Matches[1] }
```

See `docs/COMPARE_LOOP_MODULE.md` for deeper details including Markdown/Text formats.

Autonomous integration loop runner

A convenience script `scripts/Run-AutonomousIntegrationLoop.ps1` wraps
`Invoke-IntegrationCompareLoop` with environment-driven defaults so you can start a
soak / guard loop with zero parameters.

Key env variables (optional unless noted):

| Variable | Purpose | Default |
|----------|---------|---------|
| `LV_BASE_VI` | Base VI path (required unless passing -Base) | (none) |
| `LV_HEAD_VI` | Head VI path (required unless passing -Head) | (none) |
| `LOOP_MAX_ITERATIONS` | Iteration cap (0 = infinite) | 50 |
| `LOOP_INTERVAL_SECONDS` | Delay between iterations (fractional ok) | 0 |
| `LOOP_DIFF_SUMMARY_FORMAT` | `None`\|`Text`\|`Markdown`\|`Html` | None |
| `LOOP_DIFF_SUMMARY_PATH` | Output path (auto inferred by format if omitted) | diff-summary.ext |
| `LOOP_CUSTOM_PERCENTILES` | Custom percentile list (e.g. 50,75,90,97.5,99.9) | (none) |
| `LOOP_SNAPSHOT_EVERY` | Emit snapshot every N iterations | (disabled) |
| `LOOP_SNAPSHOT_PATH` | NDJSON snapshot file path | loop-snapshots.ndjson |
| `LOOP_EMIT_RUN_SUMMARY` | When 1/true emit final run summary JSON | off |
| `LOOP_RUN_SUMMARY_JSON` | Explicit run summary path | loop-run-summary.json |
| `LOOP_FAIL_ON_DIFF` | 1/true to stop after first diff | true |
| `LOOP_ADAPTIVE` | 1/true enable adaptive interval | false |
| `LOOP_HISTOGRAM_BINS` | Histogram bin count (0 disables) | 0 |
| `LOOP_SIMULATE` | 1/true use internal mock executor | false |
| `LOOP_SIMULATE_EXIT_CODE` | Exit code for simulated executor | 1 |
| `LOOP_SIMULATE_DELAY_MS` | Sleep per iteration (ms) during simulation | 5 |
| `LOOP_LOG_VERBOSITY` | `Quiet`\|`Normal`\|`Verbose` (script log detail) | Normal |
| `LOOP_JSON_LOG` | Path for NDJSON structured events | (disabled) |
| `LOOP_NO_STEP_SUMMARY` | 1/true to suppress step summary append | off |
| `LOOP_NO_CONSOLE_SUMMARY` | 1/true suppress console summary block | off |
| `LOOP_JSON_LOG_MAX_BYTES` | Rotate JSON log when size exceeds bytes | (disabled) |
| `LOOP_JSON_LOG_MAX_ROLLS` | Max rolled log files to retain | 5 |
| `LOOP_DIFF_EXIT_CODE` | Custom process exit code when diffs>0 & no errors | (unset) |
| `LOOP_JSON_LOG_MAX_AGE_SECONDS` | Rotate JSON log after this age (seconds) | (disabled) |
| `LOOP_FINAL_STATUS_JSON` | Path to emit final status JSON document | (disabled) |

Additional switches:

- `-DryRun`: Print resolved configuration (including inferred artifact paths) and exit without executing the loop.
- `-LogVerbosity Quiet|Normal|Verbose`: Override env value for logging detail (DryRun still returns 0 on success).
- `-NoStepSummary`: Prevent appending diff summary to `$GITHUB_STEP_SUMMARY` even if present.
- `-NoConsoleSummary`: Suppress printing the human-readable summary block (useful when only JSON logs are desired).
- `-JsonLogPath <file>`: Write structured NDJSON events (`plan`, `dryRun`, `result`, `stepSummaryAppended`).
- `-DiffExitCode <int>`: When set and the loop succeeds with one or more diffs, exit using this code instead of 0.
- Rotation: Set `LOOP_JSON_LOG_MAX_BYTES` and optionally `LOOP_JSON_LOG_MAX_ROLLS` (default 5) for rolling `*.roll` files.
- Time-based rotation: Set `LOOP_JSON_LOG_MAX_AGE_SECONDS` to force age-based rotation.
- Final status JSON: Provide `-FinalStatusJsonPath` or env `LOOP_FINAL_STATUS_JSON`
  to write a `loop-final-status-v1` JSON (separate from run summary JSON inside the
  loop module).

Quick simulated run (no real LVCompare required):

```powershell
$env:LV_BASE_VI = 'VI1.vi'
$env:LV_HEAD_VI = 'VI2.vi'
$env:LOOP_SIMULATE = '1'
$env:LOOP_DIFF_SUMMARY_FORMAT = 'Html'
$env:LOOP_MAX_ITERATIONS = '15'
$env:LOOP_SNAPSHOT_EVERY = '5'
$env:LOOP_JSON_LOG = 'loop-events.ndjson'
$env:LOOP_EMIT_RUN_SUMMARY = '1'
pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

Excerpt output:

```text
=== Integration Compare Loop Result ===
VI1: VI1.vi
VI2: VI2.vi
Iterations: 15 (Diffs=15 Errors=0)
Latency p50/p90/p99: 0.005/0.006/0.007 s
Diff summary fragment emitted.
Run summary JSON: loop-run-summary.json
Snapshots NDJSON: loop-snapshots.ndjson
```

Structured events sample (`loop-events.ndjson` first lines):

```jsonc
{"timestamp":"2025-10-01T12:00:00.100Z","type":"plan","simulate":true,"dryRun":false,"maxIterations":15,"interval":0,"diffSummaryFormat":"Html"}
{"timestamp":"2025-10-01T12:00:00.250Z","type":"result","iterations":15,"diffs":15,"errors":0,"succeeded":true}
```

Event schema versioning:

- Each event now includes `"schema":"loop-script-events-v1"`.
- Meta events:
  - `type=meta action=create` on new log creation
  - `type=meta action=rotate` when rotation occurs (fields: `from`, `to`)
- Backward compatibility: future minor additions will retain existing fields; consumers should ignore unknown properties.

JSON Schemas:

- `docs/schemas/loop-script-events-v1.schema.json`
- `docs/schemas/loop-final-status-v1.schema.json`

Final status example minimal structure:

```jsonc
{
  "schema": "loop-final-status-v1",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "iterations": 40,
  "diffs": 12,
  "errors": 0,
  "succeeded": true,
  "averageSeconds": 0.012,
  "totalSeconds": 0.55,
  "percentiles": { "p50": 0.010, "p90": 0.018, "p99": 0.024 },
  "histogram": [ { "Index":0, "Start":0, "End":1, "Count":40 } ],
  "diffSummaryEmitted": true,
  "basePath": "VI1.vi",
  "headPath": "VI2.vi"
}
```

GitHub Actions step example (simulated):

```yaml
  - name: Autonomous integration loop (simulated)
    shell: pwsh
    run: |
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
      $env:LOOP_SIMULATE = '1'
      $env:LOOP_MAX_ITERATIONS = '30'
      $env:LOOP_INTERVAL_SECONDS = '0'
      $env:LOOP_DIFF_SUMMARY_FORMAT = 'Markdown'
      $env:LOOP_EMIT_RUN_SUMMARY = '1'
      pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

If `GITHUB_STEP_SUMMARY` is present and a diff summary is generated it is appended automatically.

Timing metrics

- Each invocation now records wall-clock execution time and surfaces it via:
  - Action output `compareDurationSeconds` (was `durationSeconds` in earlier versions)
  - Action output `compareDurationNanoseconds` (high-resolution; derived from Stopwatch ticks)
  - Step summary line `Duration (s): <value>`
  - Step summary line `Duration (ns): <value>`
  - PR comment and artifact workflow job summary include a combined line: `<seconds>s (<milliseconds> ms)` for quick readability
  - HTML report field (if you render a report via `Render-CompareReport.ps1` passing `-CompareDurationSeconds` or legacy alias `-DurationSeconds`)

Artifact publishing workflow

A dedicated workflow (`.github/workflows/compare-artifacts.yml`) runs the local action, generates:

- `compare-summary.json` (JSON metadata: base, head, exit code, diff, timing)
- `compare-report.html` (HTML summary rendered via `Render-CompareReport.ps1`)

and uploads them as artifacts. It also appends a timing block to the job summary:

```text
### Compare VI Timing

- Seconds: <seconds>

- Nanoseconds: <nanoseconds>
- Combined: <seconds>s (<ms> ms)
```

Use this workflow to retain comparison evidence on every push or pull request without failing the build on differences (it sets `fail-on-diff: false`).

Integration readiness

Use the helper script to assess prerequisites before enabling integration tests:

```powershell
./scripts/Test-IntegrationEnvironment.ps1 -JsonPath tests/results/integration-env.json
```

Exit code 0 means ready; 1 indicates missing prerequisites (non-fatal for CI gating).

Troubleshooting unknown exit codes

- The action treats 0 as no diff and 1 as diff. Any other exit code fails fast.
- Outputs are still set for diagnostics: `exitCode`, `cliPath`, `command`, and `diff=false`.
- Check $GITHUB_STEP_SUMMARY for a concise run report.

Smoke test workflow

- A manual workflow is provided at `.github/workflows/smoke.yml`.
- Trigger it with “Run workflow” and supply `base`, `head`, and optional `lvComparePath`/`lvCompareArgs`.
- It runs the local action (`uses: ./`) on a self-hosted Windows runner and prints outputs.

Marketplace

- Listing: [GitHub Marketplace listing](https://github.com/marketplace/actions/compare-vi-cli-action)
- After publication, keep the badge/link updated to the final marketplace URL and ensure the README usage references the latest tag.

Notes

## Pester Test Dispatcher JSON Summary (Schema v1.7.1)

The repository ships a PowerShell test dispatcher (`Invoke-PesterTests.ps1`) that emits
a machine‑readable JSON summary (`pester-summary.json`) for every run. This enables
downstream tooling (dashboards, PR annotations, quality gates) to consume stable fields
without scraping console text.

Schema files:

- Baseline (core fields) [`docs/schemas/pester-summary-v1_1.schema.json`](./docs/schemas/pester-summary-v1_1.schema.json)
- Current (adds optional context blocks) [`docs/schemas/pester-summary-v1_2.schema.json`](./docs/schemas/pester-summary-v1_2.schema.json)
- Latest (adds optional discovery block) [`docs/schemas/pester-summary-v1_5.schema.json`](./docs/schemas/pester-summary-v1_5.schema.json)

Validation tests:

- Baseline absence of optional blocks: [`tests/PesterSummary.Schema.Tests.ps1`](./tests/PesterSummary.Schema.Tests.ps1)
- Context emission (when opt-in flag used): [`tests/PesterSummary.Context.Tests.ps1`](./tests/PesterSummary.Context.Tests.ps1)

### Core Fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string (const `1.7.1`) | Version identifier (semantic). Additive fields bump minor only. |
| `total` | int >=0 | Total discovered tests (failed + passed + errors + skipped). |
| `passed` | int >=0 | Count of tests whose `Result` was `Passed`. |
| `failed` | int >=0 | Assertion failures (Pester logical failures). |
| `errors` | int >=0 | Infrastructure / discovery / execution errors elevated to error state. |
| `skipped` | int >=0 | Skipped + not‑run tests aggregated. |
| `duration_s` | number >=0 | Wall‑clock run duration in seconds (2 decimal precision). |
| `timestamp` | string (ISO 8601) | Completion timestamp (UTC). |
| `pesterVersion` | string | Resolved Pester module version used. |
| `includeIntegration` | boolean | Whether Integration‑tagged tests were included. |
| `meanTest_ms` | number or null | Mean test duration (ms) when per‑test durations available; otherwise null. |
| `p95Test_ms` | number or null | 95th percentile test duration (ms) or null. |
| `maxTest_ms` | number or null | Maximum single test duration (ms) or null. |
| `timedOut` | boolean | True if a timeout guard stopped execution before completion. |
| `discoveryFailures` | int >=0 | Count of discovery failure pattern matches (e.g. script parse/loader failures). Promoted to `errors` if no other failures/errors present. |

Notes:

- Timing distribution (`meanTest_ms`, `p95Test_ms`, `maxTest_ms`) is computed only when
  detailed result objects are available. Missing data yields `null` values without
  omitting keys.
- A discovery failure (pattern: `Discovery in .* failed with:`) previously could yield a
  false green (0 tests). Logic now elevates such cases to `errors` and a non‑zero
  dispatcher exit code.
- The dispatcher never uses additional exit codes: 0 = clean (no failures), 1 = any failure/error/discovery anomaly/timeout.
- All dynamic numeric fields use plain JSON numbers (no string wrapping) to simplify ingestion by metrics pipelines.

### Versioning Policy

1. Additive fields -> minor version bump (e.g. 1.1.0 → 1.2.0).
2. Doc clarifications or non‑breaking constraint tightening -> patch bump (1.1.0 → 1.1.1).
3. Field removal / rename / semantic type change -> major (2.0.0) and deprecation window communicated ahead of time.
4. Older schema files remain immutable—never retro‑edit historical definitions.

### New in 1.2.0: Optional Context Blocks

Version 1.2.0 introduces three **optional** top-level objects emitted only when the
dispatcher is invoked with the new switch `-EmitContext`. They are omitted by default to
preserve the minimal footprint and backward compatibility with 1.1.0 consumers.

| Block | Sample Keys | Purpose |
|-------|-------------|---------|
| `environment` | `osDescription`, `powerShellVersion`, `pesterModulePath` | Host/runtime details for traceability & fleet variability studies. |
| `run` | `startedAt`, `endedAt`, `wallClockSeconds` | Precise run window & duration envelope (independent of per-test timing). |
| `selection` | `originalTestFileCount`, `selectedTestFileCount`, `maxTestFilesApplied` | Visibility into pre-execution file selection / capping heuristics. |

Emission rules:

- Blocks are either all present or all absent (single opt-in switch ensures atomic context capture).
- No existing core field semantics change; absence MUST NOT be interpreted as an error.
- Future context-related fields (e.g. shard IDs) will follow the same optional additive pattern (minor version bump only).

Invocation example (emit context):

```powershell
./Invoke-PesterTests.ps1 -EmitContext
```

Minimal (default) invocation still produces a schema-compliant document identical (save for `schemaVersion`) to prior 1.1.0 output.

### New in 1.3.0: Optional Timing Block

Version 1.3.0 adds a `timing` object (opt-in via `-EmitTimingDetail`) containing richer
per-test duration statistics while retaining legacy root fields (`meanTest_ms`,
`p95Test_ms`, `maxTest_ms`) for backward compatibility.

Timing block fields:

| Field | Meaning |
|-------|---------|
| `count` | Number of tests with measured durations. |
| `totalMs` | Sum of all test durations (ms). |
| `minMs` / `maxMs` | Extremes (ms). |
| `meanMs` | Arithmetic mean (ms). |
| `medianMs` / `p50Ms` | 50th percentile (identical values). |
| `p75Ms`, `p90Ms`, `p95Ms`, `p99Ms` | Percentile cut points (nearest-rank). |
| `stdDevMs` | Population standard deviation (ms). |

Emission rules:

- Only present when `-EmitTimingDetail` is passed.
- Null-able metrics (e.g., min/max) become null if `count=0`.
- Does not remove or alter legacy root timing summary fields.


Invocation example:

```powershell
./Invoke-PesterTests.ps1 -EmitTimingDetail
```

### New in 1.4.0: Stability (Flakiness) Scaffold

Version 1.4.0 introduces an opt-in `stability` block (flag: `-EmitStability`) laying
groundwork for future retry-based flaky detection. Until a retry engine is implemented
all metrics are placeholders derived from the single pass.

Fields:

| Field | Meaning |
|-------|---------|
| `supportsRetries` | Indicates whether dispatcher had a retry engine active (currently always false). |
| `retryAttempts` | Number of additional retry rounds executed (always 0 now). |
| `initialFailed` | Failed test count after initial execution. |
| `finalFailed` | Failed test count after (potential) retries (same as initial for now). |
| `recovered` | True if failures reduced to zero after retries (always false now). |
| `flakySuspects` | Reserved future list of test names that failed then passed on retry (empty). |
| `retriedTestFiles` | Reserved future list of test container files retried (empty). |

Invocation example:

```powershell
./Invoke-PesterTests.ps1 -EmitStability
```

### New in 1.5.0: Discovery Diagnostics Block

Opt-in (`-EmitDiscoveryDetail`) `discovery` object providing structured insight into
discovery failures (previously counted only).

| Field | Meaning |
|-------|---------|
| `failureCount` | Number of matches (mirrors root `discoveryFailures`). |
| `patterns` | Array of regex patterns used for detection. |
| `sampleLimit` | Max number of snippets captured. |
| `samples[]` | Array of `{ index, snippet }` objects (snippet truncated to 200 chars). |
| `truncated` | True if actual matches exceed captured samples. |

Invocation example:

```powershell
./Invoke-PesterTests.ps1 -EmitDiscoveryDetail
```

### New in 1.7.0: Aggregation Hints Block

Optional heuristic guidance to help downstream systems decide how to shard, bucket, or
optimize test reporting. Enabled with `-EmitAggregationHints`.

Structure:

```json
"aggregationHints": {
  "dominantTags": ["Slow", "Integration"],
  "fileBucketCounts": { "small": 25, "medium": 4, "large": 1 },
  "durationBuckets": { "subSecond": 90, "oneToFive": 12, "overFive": 3 },
  "suggestions": ["split-large-files", "isolate-slow-tests"],
  "strategy": "heuristic/v1"
}
```

Guidelines:

- `dominantTags`: Up to 5 most frequent tags (frequency-descending).
- `fileBucketCounts`: Test file size categories (<=5 small, 6–15 medium, >15 large).
- `durationBuckets`: Rough latency distribution of individual tests (<1s, 1–<5s, >=5s).
- `suggestions`: Advisory hints; current set may include `split-large-files`, `isolate-slow-tests`, `tag-more-tests`.
- `strategy`: Versioned heuristic identifier.


### New in 1.6.0: Outcome Classification Block

Opt-in (`-EmitOutcome`) `outcome` object providing a unified status classification
derived from existing counters and timeout/discovery signals.

| Field | Meaning |
|-------|---------|
| `overallStatus` | One of `Success`, `Failed`, `Partial`, `DiscoveryFailure`, `Timeout`. |
| `severityRank` | Numeric ordering (0=Success,1=Partial,2=Failed,3=DiscoveryFailure,4=Timeout). |
| `flags` | Array of symbolic condition flags (`TestFailures`, `Errors`, `SkippedTests`, `DiscoveryIssues`, `DiscoveryScanMatches`, `TimedOut`). |
| `counts` | Snapshot of root counters (total, passed, failed, errors, skipped, discoveryFailures). |
| `classificationStrategy` | Strategy identifier (currently `heuristic/v1`). |
| `exitCodeModel` | Modeled dispatcher exit code mapping (0 success / 1 failure states). |

Invocation example:

```powershell
./Invoke-PesterTests.ps1 -EmitOutcome
```

### New in 1.7.1: Aggregation Build Timing Metric

When aggregation hints are requested (`-EmitAggregationHints`), the dispatcher now emits
a root-level numeric field `aggregatorBuildMs` (milliseconds) measuring how long it took
to construct the `aggregationHints` block. This field is omitted entirely when
aggregation hints are not emitted (no null placeholder) to keep the default payload
lean.

Rationale:

- Provide early signal if heuristic generation becomes a performance bottleneck (guarded by dedicated performance tests).
- Enable external telemetry dashboards to correlate increased dispatcher wall time with aggregation generation costs.
- Maintain backward compatibility: absence still means feature not enabled, not zero cost.

Guarantees / Notes:

- Value is an integer millisecond duration from a high-resolution Stopwatch; extremely fast builds may report 0.
- Only present when `aggregationHints` object is present.
- Schema bump from 1.7.0 → 1.7.1 is additive; existing consumers that ignore unknown fields remain compatible.

### Planned Incremental Enrichment (Roadmap)

| Planned Version | Block | Purpose |
|-----------------|-------|---------|
| 1.2.0 | `environment`, `run`, `selection` | Context (OS, PS version, run window, file selection stats) – IMPLEMENTED (opt-in via `-EmitContext`). |
| 1.3.0 | `timing` (extended) | Rich percentile spread & optional per-test durations (flag‑gated) – IMPLEMENTED (opt-in via `-EmitTimingDetail`). |
| 1.4.0 | `stability` | Flakiness scaffolding (initial counts zero until retry engine introduced) – IMPLEMENTED (opt-in via `-EmitStability`). |
| 1.5.0 | `discovery` (expanded) | Detailed discovery diagnostics (patterns, snippets, scanned size) – IMPLEMENTED (opt-in via `-EmitDiscoveryDetail`). |
| 1.6.0 | `outcome` | Unified status classification (implemented; opt-in via `-EmitOutcome`). |
| 1.7.0 | `aggregationHints` | Heuristic grouping guidance (implemented; opt-in via `-EmitAggregationHints`). |
| 1.7.1 | `aggregatorBuildMs` | Aggregation build timing metric (only when hints emitted). |
| 1.8.0 | `extensions` | Vendor / custom injection surface (namespaced flexible data). |
| 1.9.0 | `meta` | Slim mode signalling, emittedFields manifest. |
| 2.0.0 | Breaking consolidation | Potential migration of `discoveryFailures` → `discovery.failures`, counts object grouping, explicit `schema` slug addition. |

All new blocks will be optional keys to preserve compatibility. Tests are added per
phase to assert (a) absence by default and (b) presence + type integrity when enabled
via new dispatcher switches.

### Consumption Guidance


- Treat unknown fields as ignorable (forward compatibility).
- Use `schemaVersion` for branching logic instead of key presence when performing strict validation.

- To gate CI: fail if `errors > 0` OR `failed > 0` OR (`discoveryFailures > 0` and `failed == 0`)
- When aggregating trends, prefer stable ratios: pass rate = `(passed)/(total)`; failure density = `(failed+errors)/total`.


### Example Minimal JSON (Default, No Context, No Timing, No Stability, No Discovery)

```jsonc
{
  "schemaVersion": "1.7.1",
  "total": 42,
  "passed": 42,
  "failed": 0,
  "errors": 0,
  "skipped": 0,
  "duration_s": 3.14,
  "timestamp": "2025-10-02T10:00:00.000Z",
  "pesterVersion": "5.7.1",
  "includeIntegration": false,
  "meanTest_ms": 75.12,
  "p95Test_ms": 130.44,
  "maxTest_ms": 180.02,
  "timedOut": false,
  "discoveryFailures": 0
}

### Example With Context, Timing, Stability, Discovery & Aggregation Hints

```jsonc
{
  "schemaVersion": "1.7.1",
  "total": 42,
  "passed": 42,
  "failed": 0,
  "errors": 0,
  "skipped": 0,
  "duration_s": 3.14,
  "timestamp": "2025-10-02T10:00:00.000Z",
  "pesterVersion": "5.7.1",
  "includeIntegration": false,
  "meanTest_ms": 75.12,
  "p95Test_ms": 130.44,
  "maxTest_ms": 180.02,
  "timedOut": false,
  "discoveryFailures": 0,
  "aggregatorBuildMs": 12,
  "timing": {
    "count": 42,
    "totalMs": 3150.5,
    "minMs": 5.12,
    "maxMs": 180.02,
    "meanMs": 75.12,
    "medianMs": 70.10,
    "stdDevMs": 12.55,
    "p50Ms": 70.10,
    "p75Ms": 90.44,
    "p90Ms": 120.33,
    "p95Ms": 130.44,
    "p99Ms": 178.91
  },
  "stability": {
    "supportsRetries": false,
    "retryAttempts": 0,
    "initialFailed": 0,
    "finalFailed": 0,
    "recovered": false,
    "flakySuspects": [],
    "retriedTestFiles": []
  },
  "discovery": {
    "failureCount": 1,
    "patterns": ["(?s)Discovery in .*? failed with:"],
    "sampleLimit": 5,
    "samples": [{ "index": 0, "snippet": "Discovery in C:/path/Test.Tests.ps1 failed with: <error>" }],
    "truncated": false
  },
  "environment": {
    "osDescription": "Microsoft Windows 11 Pro 10.0.22631",
    "powerShellVersion": "7.4.4",
    "pesterModulePath": "C:/Users/runneradmin/Documents/PowerShell/Modules/Pester/5.7.1/Pester.psd1"
  },
  "run": {
    "startedAt": "2025-10-02T10:00:00.000Z",
    "endedAt": "2025-10-02T10:00:03.140Z",
    "wallClockSeconds": 3.14
  },
  "selection": {
    "originalTestFileCount": 27,
    "selectedTestFileCount": 27,
    "maxTestFilesApplied": false
  },
  "aggregationHints": {
    "dominantTags": ["Slow", "Integration"],
    "fileBucketCounts": { "small": 25, "medium": 4, "large": 1 },
    "durationBuckets": { "subSecond": 90, "oneToFive": 12, "overFive": 3 },
    "suggestions": ["split-large-files", "isolate-slow-tests"],
    "strategy": "heuristic/v1"
  }
}
```

Notes:

- Paths / versions are illustrative.
- Consumers must treat unknown future fields as ignorable.
- Absence of `environment` (etc.) indicates the dispatcher was run without `-EmitContext`.

For questions or suggested fields open an issue with `area:schema` label.


- This action maps `LVCompare.exe` exit codes to a boolean `diff` (0 = no diff, 1 = diff). Any other exit code fails the step.
- **Canonical path policy**: Only `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe` is supported
- Any `lvComparePath` or `LVCOMPARE_PATH` value must resolve to this exact canonical path or the action will fail

Troubleshooting

- Ensure the runner user has the necessary LabVIEW licensing.
- Verify `LVCompare.exe` is installed at: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- If you set `LVCOMPARE_PATH` or `lvComparePath`, ensure they point to the canonical path
- Check composite action outputs (`diff`, `exitCode`, `cliPath`, `command`) and the CLI exit code for diagnostics.
- **For comprehensive CI/CD setup and troubleshooting**, see [Self-Hosted Runner CI/CD Setup Guide](./docs/SELFHOSTED_CI_SETUP.md)

### Dispatcher discovery failures & diagnostic environment toggles

The local Pester dispatcher (`Invoke-PesterTests.ps1`) performs a lightweight scan of
console output to detect **discovery-time failures** (e.g. parse / variable resolution
errors that prevent tests from loading). Historically a single integration test caused a
persistent false positive; instrumentation plus safer test authoring resolved it. This
section explains how to diagnose future issues and which environment variables influence
behavior.

Key principles:

1. A real discovery failure normally produces console text of the form: `Discovery in <path> failed with:`.
2. Nested dispatcher invocations (e.g., a test that launches another Pester run) can emit similar lines that are *not* actionable for the outer run. These are suppressed by default.
3. If discovery failures are detected and there are no normal test failures or errors, the dispatcher elevates the run to an error state (exit code 1) to avoid silent greens with 0 tests executed.

Environment variables (all optional):

| Variable | Default | Effect | When to use |
|----------|---------|--------|------------|
| `SUPPRESS_NESTED_DISCOVERY` | (any value except `0`) | Suppress discovery failure pattern matches originating from nested dispatcher contexts (multiple summary headers observed). | Leave enabled for CI stability; set to `0` only when intentionally diagnosing nested dispatcher scenarios. |
| `DEBUG_DISCOVERY_SCAN` | `0` | When `1`, emits `[debug-discovery]` lines for every regex match and writes a contextual `discovery-debug.log` (400‑char snippets with index & header counts) under `tests/results/`. | Turn on while investigating unexpected `discoveryFailures > 0` in the JSON summary. |
| `DISABLE_INTEGRATION_FILE_PREFILTER` | `0` | When integration tests are excluded (`-IncludeIntegration false`), the dispatcher pre-filters `*.Integration.Tests.ps1` files entirely. Set this var to `1` to disable the file-level filter (they will still be tag-excluded). | Rare – only for validating integration skip gating or reproducing prior edge cases. |
| `ENABLE_AGG_INT` | `0` | When `1`, enables the Aggregation Hints integration smoke test (requires canonical LVCompare path + `LV_BASE_VI` + `LV_HEAD_VI`). | Use on self-hosted runners to exercise aggregationHints in an end-to-end dispatcher run. |
| `COMPARISON_ACTION_DEBUG` | `0` | When `1`, the dispatcher echoes its bound parameters (`[debug]` block). | Debug parameter normalization issues. |

JSON summary linkage:

- Root field `discoveryFailures` reports the (post-suppression) count.
- Optional discovery diagnostics block (via `-EmitDiscoveryDetail`) can provide captured snippets when failures occur.

Best practices to avoid false positives:

- Ensure any variables used inside `-Skip:` expressions are initialized **before** the
  `It` block is parsed (declare at script top-level or use a `BeforeDiscovery` hook
  rather than `BeforeAll`). Uninitialized variables can cause discovery-time resolution
  errors surfaced as false positives.
- Avoid performing filesystem mutations (test file creation/deletion) at script
  top-level—keep them inside `BeforeAll`/`It` to prevent parse-time side effects.

Quick diagnostic workflow (local):

```powershell
$env:DEBUG_DISCOVERY_SCAN = '1'
pwsh -File ./Invoke-PesterTests.ps1 -EmitDiscoveryDetail | Tee-Object -Variable out | Out-Null
Get-Content tests/results/discovery-debug.log | Select-Object -First 5
```

If `discoveryFailures` returns to zero after moving variable initialization out of
`BeforeAll`, you've resolved a discovery-time reference issue. Re-enable suppression
defaults after diagnosis.


Tests

- Unit tests (no external CLI):
  - Run: `pwsh -File ./tools/Run-Pester.ps1`
  - Produces artifacts under `tests/results/` (NUnit XML and summary)
- Integration tests (requires canonical LVCompare path on self-hosted runner):
  - Run: `pwsh -File ./tools/Run-Pester.ps1 -IncludeIntegration`
  - Requires environment variables: `LV_BASE_VI` and `LV_HEAD_VI` pointing to test `.vi` files
  - See detailed prerequisites & skip behavior: [Integration Tests Guide](./docs/INTEGRATION_TESTS.md)
- Test design & stability patterns (nested dispatcher, function shadowing vs mocks): [Testing Patterns](./docs/TESTING_PATTERNS.md)
- JSON/NDJSON schema validation helper (Run Summary, Snapshot v2, Loop Events, Final Status): [Schema Helper](./docs/SCHEMA_HELPER.md)
- CI workflows:
  - `.github/workflows/test-pester.yml` - runs unit tests on GitHub-hosted Windows runners
  - `.github/workflows/pester-selfhosted.yml` - runs integration tests on self-hosted runners with real CLI
  - `.github/workflows/pester-diagnostics-nightly.yml` - nightly synthetic failure to validate enhanced diagnostics (non-blocking)
  - Use PR comments to trigger: `/run unit`, `/run mock`, `/run smoke`, `/run pester-selfhosted`
- **For end-to-end testing**, see [End-to-End Testing Guide](./docs/E2E_TESTING_GUIDE.md)

RunSummary renderer test restoration

- The original renderer tool tests were temporarily quarantined due to a discovery-time PowerShell parameter binding anomaly injecting a null `-Path`.
- Tests have been restored (`RunSummary.Tool.Restored.Tests.ps1`) using a safe pattern:
  all `$TestDrive` and dynamic file creation occurs inside `BeforeAll` or individual `It`
  blocks (never at script top-level during Pester discovery).
- A minimal reproduction script (`tools/Binding-MinRepro.ps1`) plus diagnostic test
  (`Binding.MinRepro.Tests.ps1`) are included for future investigations.
- If adding new renderer-related tests, avoid performing filesystem or `$TestDrive`
  operations outside of runtime blocks to prevent reintroducing the anomaly.

Continuous local dev loop (watch mode)

For rapid iteration you can run a file watcher that re-executes Pester when source or test files change:

```powershell
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart
```

Key options:

- `-Path` (default `.`): Root to watch recursively.
- `-Filter` (default `*.ps1`): File name filter.
- `-DebounceMilliseconds` (default 400): Quiet period after last change before a run.
- `-Tag` / `-ExcludeTag`: Limit test scope using Pester tags.
- `-TestPath` (default `tests`): Base test directory.
- `-RunAllOnStart`: Perform an initial full run.
- `-SingleRun`: Run once (honoring targeting) and exit (useful for scripting).
- `-Quiet`: Reduce output verbosity (summary only).
- `-ChangedOnly`: Skip a run if no directly changed or inferred test files were detected.
- `-InferTestsFromSource`: Attempt to map changed module/script files to corresponding `*.Tests.ps1` by basename.
- `-BeepOnFail`: Emit an audible console beep when a run has failures.
- `-DeltaJsonPath <file>`: Write a JSON artifact containing current stats, previous stats, deltas, and classification (`baseline|improved|worsened|unchanged`).
- `-ShowFailed`: After summary, list failing test names (up to `-MaxFailedList`).
- `-MaxFailedList <N>`: Cap the number of failing tests printed (default 10).
- `-DeltaHistoryPath <file>`: Append each delta JSON payload (same schema as
  `-DeltaJsonPath`) as one line of JSON (JSON Lines / NDJSON). Useful for run history
  graphs.
- `-MappingConfig <file>`: JSON file mapping source glob patterns to one or more test files (augmenting `-InferTestsFromSource`).
- `-OnlyFailed`: If the previous run had failing test files and no direct/inferred changes are detected this run, re-run only those failing test files.
- `-NotifyScript <file>`: Post-run hook script invoked with named parameters & WATCH_* environment variables (see below).
- `-RerunFailedAttempts <N>`: Automatically re-run failing test file containers up to N
  additional attempts (flaky mitigation). Classification becomes `improved` if failures
  clear on a retry.

Selective runs:

If any changed file path matches `\tests\*.Tests.ps1`, only those test files are executed; otherwise the full suite under `-TestPath` runs.

Exit behavior:

The watcher runs until interrupted (Ctrl+C). It installs Pester automatically if not found (CurrentUser scope).

Delta JSON schema example (`-DeltaJsonPath tests/results/delta.json`):

```jsonc
{
  "timestamp": "2025-10-01T15:15:27.123Z",
  "status": "FAIL",
  "stats": { "tests": 121, "failed": 6, "skipped": 15 },
  "previous": { "tests": 121, "failed": 7, "skipped": 15 },
  "delta": { "tests": 0, "failed": -1, "skipped": 0 },
  "classification": "improved",
  "flaky": { "enabled": true, "attempts": 2, "recoveredAfter": 1, "initialFailedFiles": 3 },
  "runSequence": 5
}
```

Field notes:

- `flaky` object is present only when `-RerunFailedAttempts > 0`.
- `recoveredAfter` is null if retries did not clear all failures.
- `initialFailedFiles` counts distinct failing *.Tests.ps1 files in the initial (pre-retry) attempt.
- `classification` is forced to `improved` if failures were cleared by a retry even if prior run comparison would be neutral.
- `initialFailedFileNames` (when present) lists the leaf filenames of the initially failing test files for quick glance diffing.

History logging (`-DeltaHistoryPath`):

Each completed run appends the exact JSON (single line) written to `-DeltaJsonPath`. Example JSON Lines file after three runs:

```jsonl
{"timestamp":"2025-10-01T15:15:27.123Z","status":"FAIL","stats":{"tests":121,"failed":6,"skipped":15},"previous":null,"delta":null,"classification":"baseline","flaky":null,"runSequence":1}
{"timestamp":"2025-10-01T15:16:03.987Z","status":"FAIL","stats":{"tests":121,"failed":5,"skipped":15},"previous":{"tests":121,"failed":6,"skipped":15},"delta":{"tests":0,"failed":-1,"skipped":0},"classification":"improved","flaky":null,"runSequence":2}
{"timestamp":"2025-10-01T15:17:10.111Z","status":"PASS","stats":{"tests":121,"failed":0,"skipped":15},"previous":{"tests":121,"failed":5,"skipped":15},"delta":{"tests":0,"failed":-5,"skipped":0},"classification":"improved","flaky":{"enabled":true,"attempts":2,"recoveredAfter":1,"initialFailedFiles":2},"runSequence":3}
```

You can ingest this with tools expecting newline-delimited JSON for generating trend charts (failures over time, recovery streaks, etc.).

Classification logic:

- `baseline`: First run (no previous stats)
- `improved`: Failed count decreased
- `worsened`: Failed count increased
- `unchanged`: Failed count unchanged

Typical usage patterns:

```powershell
# Full run on start, then only run when tests or inferred sources change
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly -InferTestsFromSource

# Emit delta JSON and audible alert on failures
pwsh -File ./tools/Watch-Pester.ps1 -DeltaJsonPath tests/results/delta.json -BeepOnFail

# Show top 5 failing tests each run (compact selective runs)
pwsh -File ./tools/Watch-Pester.ps1 -ShowFailed -MaxFailedList 5 -ChangedOnly

# Maintain a JSON run history & attempt flaky recovery (2 retries)
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart -DeltaJsonPath tests/results/delta.json -DeltaHistoryPath tests/results/delta-history.jsonl -RerunFailedAttempts 2

# Use mapping config + OnlyFailed fallback between edits
pwsh -File ./tools/Watch-Pester.ps1 -ChangedOnly -MappingConfig watch-mapping.json -OnlyFailed

# Invoke a desktop/toast notifier script when runs complete
pwsh -File ./tools/Watch-Pester.ps1 -NotifyScript tools/Notify-Demo.ps1 -ShowFailed -MaxFailedList 3
```

Heuristic source→test inference:

- A changed file under `module/<Name>/<Name>.psm1` or `scripts/<Name>.ps1` maps to `tests/<Name>.Tests.ps1` if present.
- If no mapping is found and `-ChangedOnly` is set, the run is skipped (fast no-op feedback).
- You can still force a full run manually (save a test file or omit `-ChangedOnly`).

Failed test listing (`-ShowFailed`):

- Extracts failing test objects from Pester result and prints up to `-MaxFailedList` entries.
- Uses trimmed relative path or describe block name (depending on the object metadata available).

Colorized status & sequencing:

- Each run prints a line: `Run #<n> PASS|FAIL in <seconds>s (Tests=<t> Failed=<f>) (Δ Tests=... Failed=...)`.
- Only appears after execution; delta portion omitted on first (baseline) run.

Notes & limitations:

- Inference is intentionally conservative; contribute mapping expansions if you have alternate naming schemes.
- The delta JSON overwrites the same file each run (append-mode history could be added later).
- Use `-DeltaHistoryPath` to enable append-mode history (JSON Lines) without overwriting.
- `-BeepOnFail` may be suppressed in non-interactive consoles.
- If Pester changes internal property names, the script falls back through multiple strategies to compute `tests`.

Mapping configuration (`-MappingConfig`):

Supplement the heuristic inference with an explicit JSON array file:

```jsonc
[
  {
    "sourcePattern": "module/CompareLoop/*.psm1",
    "tests": ["tests/CompareLoop.StreamingQuantiles.Tests.ps1", "tests/CompareLoop.StreamingReconcile.Tests.ps1"]
  },
  {
    "sourcePattern": "scripts/Render-CompareReport.ps1",
    "tests": ["tests/CompareVI.Tests.ps1"]
  }
]
```

See `watch-mapping.sample.json` in the repository root for a longer example including mapping the watcher script itself to dispatcher tests.

Rules:

- Patterns are simple globs converted to regex (`*` → `.*`, `?` → `.`) and matched against repository-relative normalized paths (`/` separators).
- When a changed file matches `sourcePattern`, all listed `tests` are added to the targeted test file set (if they exist).
- Mapping augments (does not replace) heuristic `-InferTestsFromSource` logic.

Only failed re-run mode (`-OnlyFailed`):

- After a failing run the script remembers the set of failing test file containers.
- If a subsequent change batch has no directly changed or inferred test files and `-OnlyFailed` is set, only those failing files are re-run (fast feedback on fixes without re-running entire suite).
- A fully passing run clears the stored failing set.

Flaky retry mitigation (`-RerunFailedAttempts`):

- After the initial run, failing test file containers (*.Tests.ps1) are re-run up to N attempts.
- If failures clear on attempt K, `flaky.recoveredAfter` = K and classification is forced to `improved`.
- Counts in the delta JSON correspond to the final attempt executed (subset of full suite when retries target a subset).

Notify hook (`-NotifyScript`):

- Invoked after each run with named parameters:
  - `-Status <PASS|FAIL>`
  - `-Failed <int>`
  - `-Tests <int>`
  - `-Skipped <int>`
  - `-RunSequence <int>`
  - `-Classification <baseline|improved|worsened|unchanged>`
- Environment variables also set for convenience: `WATCH_STATUS`, `WATCH_FAILED`, `WATCH_TESTS`, `WATCH_SKIPPED`, `WATCH_SEQUENCE`, `WATCH_CLASSIFICATION`.
- Output (stdout) lines from the hook are prefixed with `[notify]` in the watcher console.
- Use cases: desktop notifications, toast popups, Slack / Teams webhook wrappers, log forwarding.

Example notify script (`tools/Notify-Demo.ps1`):

```powershell
param(
  [string]$Status,
  [int]$Failed,
  [int]$Tests,
  [int]$Skipped,
  [int]$RunSequence,
  [string]$Classification
)
"Notify: Run#$RunSequence Status=$Status Failed=$Failed/$Tests Skipped=$Skipped Class=$Classification (env=$env:WATCH_STATUS)"
```

Integration compare control loop (developer scaffold)

For rapid, iterative development against two real VIs (e.g. editing a feature branch VI and observing diff stability / timing) a lightweight polling loop script is provided:

```powershell
pwsh -File ./scripts/Integration-ControlLoop.ps1 `
  -Base 'C:\repos\main\ControlLoop.vi' `
  -Head 'C:\repos\feature\ControlLoop.vi' `
  -LvCompareArgs "-nobdcosm -nofppos -noattr" `
  -SkipIfUnchanged `
  -IntervalSeconds 3
```

Key features:

- Enforces canonical LVCompare path only
- Polls at a configurable interval (default 5s)
- Optional skip when neither VI timestamp changed (`-SkipIfUnchanged`)
- Shows a compact per-iteration table (diff flag, exit code, duration)
- Records timing metrics and counts (diffs, errors)
- Optional JSON lines log via `-JsonLog path\loop-log.json`
- Optional `-FailOnDiff` to terminate on first diff (useful in guard scenarios)

Example JSON log line (one per iteration when `-JsonLog` supplied):

```jsonc
{
  "iteration": 4,
  "timestampUtc": "2025-10-01T12:34:56.789Z",
  "skipped": false,
  "diff": true,
  "exitCode": 1,
  "status": "OK",
  "durationSeconds": 0.217,
  "baseChanged": false,
  "headChanged": true
}
```

Planned extensions (contributions welcome): file system watcher trigger, HTML report generation on diff, latency histogram, automatic re-baselining.

Module reuse

The loop logic is also packaged as a lightweight module for programmatic automation: `module/CompareLoop/CompareLoop.psd1`.

Example:

```powershell
Import-Module ./module/CompareLoop/CompareLoop.psd1 -Force
$exec = { param($CliPath,$Base,$Head,$Args) 0 } # always no diff
Invoke-IntegrationCompareLoop -Base 'C:\repos\main\ControlLoop.vi' -Head 'C:\repos\feature\ControlLoop.vi' -MaxIterations 1 -CompareExecutor $exec -BypassCliValidation -SkipValidation -PassThroughPaths -Quiet
```

## Composite Action Loop Mode (Experimental)

The composite action supports an optional **loop mode** (`loop-enabled: true`) that
delegates to the `CompareLoop` module to collect multiple LVCompare iterations and
export aggregate latency metrics, percentiles, and (optionally) a histogram.

When loop mode is enabled, the action:

1. Executes up to `loop-max-iterations` iterations (or fewer if canceled / job ends).
2. Simulated executor by default (`loop-simulate: true`) allows percentile telemetry on
  GitHub-hosted runners without LabVIEW. Set `loop-simulate: false` for real comparisons
  (requires canonical CLI path).
3. Emits additional outputs for downstream workflows (average latency, p50/p90/p99, counts, reservoir window size, etc.).
4. Writes a `compare-loop-summary.json` (aggregate) and optional histogram JSON file into the runner temp directory.

### Loop Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `loop-enabled` | `false` | Enable loop mode branch. |
| `loop-max-iterations` | `25` | Cap on iterations (0 = run until diff only if `fail-on-diff` is false; otherwise treat as finite). |
| `loop-interval-seconds` | `0` | Delay between iterations (fractional seconds supported). |
| `quantile-strategy` | `StreamingReservoir` | `Exact` \| `StreamingReservoir` \| `Hybrid`. See [Quantile Accuracy Guide](docs/QUANTILE_ACCURACY.md) for tuning. |
| `stream-capacity` | `500` | Reservoir capacity (min 10). |
| `reconcile-every` | `0` | Reservoir rebuild cadence (0 = disabled). |
| `hybrid-exact-threshold` | `200` | Exact seed iterations before streaming when `Hybrid` is chosen. |
| `histogram-bins` | `0` | Number of histogram bins (0 = disabled). |
| `loop-simulate` | `true` | Use internal mock executor instead of real LVCompare. |
| `loop-simulate-exit-code` | `1` | Exit code from simulated executor (1=differences, 0=no diff). |

### Loop Outputs

| Output | Meaning |
|--------|---------|
| `iterations` | Total iterations executed. |
| `diffCount` | Number of diff iterations (exit code 1). |
| `errorCount` | Unexpected error iterations. |
| `averageSeconds` | Mean duration across non-skipped iterations. |
| `totalSeconds` | Total elapsed wall clock (s). |
| `p50` / `p90` / `p99` | Latency percentiles (seconds). Blank if insufficient samples. |
| `quantileStrategy` | Effective quantile strategy used (alias normalized). |
| `streamingWindowCount` | Active reservoir sample count (streaming modes). |
| `loopResultPath` | Path to loop summary JSON (`loop-summary-v1` schema). |
| `histogramPath` | Path to histogram JSON (if bins > 0, else blank). |

Legacy single-run outputs (`diff`, `exitCode`, `compareDurationSeconds`, etc.) are still populated for compatibility (duration fields represent average loop latency when in loop mode).

### Example: Simulated Loop With Streaming Reservoir

```yaml
jobs:
  perf-probe:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v5
      - name: Simulated latency loop
        id: loop
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
        with:
          base: VI1.vi
          head: VI2.vi
          loop-enabled: true
          loop-max-iterations: 40
          loop-interval-seconds: 0
          quantile-strategy: StreamingReservoir
          stream-capacity: 400
          reconcile-every: 0
          histogram-bins: 5
          loop-simulate: true
          loop-simulate-exit-code: 1
      - name: Print percentiles
        run: |
          echo "p50=${{ steps.loop.outputs.p50 }} p90=${{ steps.loop.outputs.p90 }} p99=${{ steps.loop.outputs.p99 }}"
```

### Example: Hybrid Strategy With Reconciliation (Real CLI)

```yaml
jobs:
  soak:
    runs-on: [self-hosted, Windows]
    steps:
      - uses: actions/checkout@v5
      - name: Hybrid percentile soak
        id: loop
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
        with:
          base: path/to/VI1.vi
          head: path/to/VI2.vi
          fail-on-diff: "false"            # keep iterating even if diffs occur
          loop-enabled: true
          loop-max-iterations: 2000
          loop-interval-seconds: 0
          quantile-strategy: Hybrid
          hybrid-exact-threshold: 300
          stream-capacity: 600
          reconcile-every: 1800
          histogram-bins: 6
          loop-simulate: false             # real comparisons
```

Loop JSON summary schema (`loop-summary-v1`):

```jsonc
{
  "iterations": 40,
  "diffCount": 18,
  "errorCount": 0,
  "averageSeconds": 0.012,
  "totalSeconds": 0.51,
  "quantileStrategy": "StreamingReservoir",
  "streamingWindowCount": 400,
  "percentiles": { "p50": 0.010, "p90": 0.018, "p99": 0.025 },
  "histogram": [ { "Index":0, "Start":0, "End":1, "Count":15 } ],
  "schema": "loop-summary-v1",
  "generatedUtc": "2025-10-01T12:34:56.789Z"
}
```

Guidance:

- Use `StreamingReservoir` for long / memory-sensitive runs; adjust `stream-capacity` if p99 unstable.
- Use `Hybrid` when early exact percentiles are important before switching to bounded memory.
- Add `reconcile-every` for multi-thousand iteration soaks to minimize drift in non-stationary distributions.
- Keep `loop-simulate: true` in public CI if LabVIEW licenses aren't available; switch to `false` only on trusted self-hosted runners.

Limitations:

- Histogram is coarse (equal-width); future enhancements may provide adaptive or log-scale bucketing.
- Percentiles are limited to p50/p90/p99 (custom list planned as a future enhancement).
- Loop mode intentionally does not expose raw per-iteration records via outputs—consume the JSON file if needed.

## Streaming quantile strategies (timing distribution)

The compare loop module can estimate latency percentiles (p50/p90/p99) with bounded memory.

Supported `-QuantileStrategy` values:

| Strategy | Behavior | Memory | Notes |
|----------|----------|--------|-------|
| `Exact` | Collects all non-zero iteration durations then sorts at the end | O(N) | Most accurate; can grow large for long runs |
| `StreamingReservoir` | Maintains a fixed-size ring buffer (reservoir) of recent samples | O(K) | Formerly named `StreamingP2`; provides rolling approximation |
| `Hybrid` | Starts as `Exact` for seeding, then switches to `StreamingReservoir` after threshold | O(K)+O(T) initially | Good balance of early accuracy + steady-state bounded memory |

Additional parameters:

- `-StreamCapacity <int>`: Reservoir size (default 500, minimum 10). Larger improves
  tail stability but increases memory and sort cost per percentile snapshot.
- `-HybridExactThreshold <int>`: Number of iterations to collect exact samples before switching in `Hybrid`.
- `-ReconcileEvery <int>`: If > 0 and streaming active, periodically rebuilds the
  reservoir from collected durations using a uniform stride subsample. Helps reduce
  drift in long, highly non-stationary runs. Use a multiple of `StreamCapacity` (e.g.
  capacity 500 → reconcile every 2000) for freshness vs. overhead.

Result object fields (selected):

- `Percentiles.p50|p90|p99`
- `QuantileStrategy` (reports `StreamingReservoir` even if legacy alias `StreamingP2` was used)
- `StreamingWindowCount` (current reservoir size; 0 when not streaming yet)

Legacy alias:

- `StreamingP2` is accepted but now maps to `StreamingReservoir` and emits a deprecation warning unless `-Quiet` is specified.

Accuracy guidance:

- For relatively stable latency distributions, `StreamCapacity=300-500` keeps p50/p90
  within a few ms (or a few percent relative error) versus exact in quick iterations.
- Increase capacity or enable reconciliation if p99 drifts (especially with bimodal or bursty latency patterns).
- Hybrid mode is helpful when early, small-sample percentiles must be exact for initial diagnostics, but you still want bounded memory for a long soak run.

Example hybrid run with reconciliation:

```powershell
Import-Module ./module/CompareLoop/CompareLoop.psd1 -Force
$exec = { param($cli,$b,$h,$args) Start-Sleep -Milliseconds (5 + (Get-Random -Max 20)); 0 }
$r = Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 2000 -IntervalSeconds 0 `
  -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -Quiet `
  -QuantileStrategy Hybrid -HybridExactThreshold 400 -StreamCapacity 500 -ReconcileEvery 2000
$r.Percentiles
```

If reconciliation is enabled it triggers at the configured cadence only after streaming becomes active (Hybrid post-threshold or StreamingReservoir immediately).

Tuning checklist:

1. Need absolute accuracy and short run? Use `Exact`.
2. Long run, bounded memory? Use `StreamingReservoir` with suitable `StreamCapacity`.
3. Want accurate early baseline then bounded? Use `Hybrid` + set `HybridExactThreshold`.
4. Observing drift over hours? Introduce `-ReconcileEvery` at a multiple of capacity.
5. Tail (p99) noisy? Increase capacity or reconciliation frequency modestly.

Future considerations (open to contributions): true P² markers, advanced tail percentiles
 (e.g., p99.99), weighted / stratified sampling strategies.

Switches `-SkipValidation` and `-PassThroughPaths` exist solely for unit-style testing; omit them in real usage.

## Advanced loop parameters (module & delegated script)

The enhanced module (`CompareLoop`) exposes additional tuning/automation parameters beyond the basic scaffold:

| Area | Parameters | Purpose |
|------|------------|---------|
| Event-driven triggering | `-UseEventDriven`, `-DebounceMilliseconds` | React to filesystem changes instead of fixed polling. Debounce consolidates bursts. |
| Adaptive backoff | `-AdaptiveInterval`, `-MinIntervalSeconds`, `-MaxIntervalSeconds`, `-BackoffFactor` | Increase interval during quiet periods; reset on activity. |
| Diff summaries | ``-DiffSummaryFormat (Text\|Markdown\|Html)``, `-DiffSummaryPath` | Generate a one-shot human-readable summary after at least one diff. |
| Percentile metrics | (auto) `Percentiles.p50/p90/p99` | Exposed in result object when at least one non-skipped iteration ran. |
| Histogram | (auto) `Histogram[]` | Coarse distribution of iteration durations (5 bins). |
| Re-baseline helper | `-RebaselineAfterCleanCount`, `-ApplyRebaseline` | Detect sustained clean streaks and optionally treat head timestamp as new base reference. |
| Dependency injection | `-CompareExecutor`, `-BypassCliValidation`, `-SkipValidation`, `-PassThroughPaths` | Unit / synthetic testing without real LVCompare. |
| Diff control | `-FailOnDiff` | Early terminate loop when first diff occurs. |

Example combining several advanced features:

```powershell
Invoke-IntegrationCompareLoop `
  -Base 'C:\repos\main\ControlLoop.vi' `
  -Head 'C:\repos\feature\ControlLoop.vi' `
  -UseEventDriven -DebounceMilliseconds 400 `
  -AdaptiveInterval -MinIntervalSeconds 1 -MaxIntervalSeconds 20 -BackoffFactor 1.8 `
  -RebaselineAfterCleanCount 5 `
  -DiffSummaryFormat Markdown -DiffSummaryPath .\diff-summary.md `
  -LvCompareArgs '-nobdcosm -nofppos -noattr' `
  -FailOnDiff
```

Result object excerpt:

```powershell
$r = Invoke-IntegrationCompareLoop -Base ... -Head ... -MaxIterations 3 -UseEventDriven -AdaptiveInterval -SkipIfUnchanged
$r | Select-Object Iterations,DiffCount,ErrorCount,Mode,AverageSeconds,Percentiles,RebaselineApplied | Format-List
```

For full schema details see `docs/COMPARE_LOOP_MODULE.md`.

## What's New (Snapshot v2, Dynamic Percentiles & Run Summary JSON)

Recent enhancements introduce richer latency telemetry, flexible percentile analysis, and a final run summary export:

- metrics-snapshot-v2: Snapshot lines now include `percentiles` (dynamic object), `requestedPercentiles` (echo of your list or defaults), and optional `histogram` when `-IncludeSnapshotHistogram` is used.
- Custom percentile lists: Supply `-CustomPercentiles '50,75,90,97.5,99.9'` (comma/space separated). Values must be >0 and <100; duplicates removed; max 50 entries.
- Fractional percentile labels: Dots become underscores (e.g. 97.5 -> `p97_5`, 99.9 -> `p99_9`).
- Backward compatibility: Legacy `p50/p90/p99` still emitted at top-level in snapshots and result objects for existing consumers.
- Inline snapshot enrichment: Percentiles & histogram computed per-emission without relying on final aggregation logic.
- Final run summary JSON: Provide `-RunSummaryJsonPath run-summary.json` to emit one consolidated JSON document at loop completion (schema `compare-loop-run-summary-v1`) including aggregate metrics, dynamic percentiles, histogram, and rebaseline metadata.

Quick example (custom list + histogram + snapshots every 5 iterations):

```powershell
$exec = { param($cli,$b,$h,$args) Start-Sleep -Milliseconds (5 + (Get-Random -Max 20)); 0 }
Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 25 -IntervalSeconds 0 -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -CustomPercentiles '50 75 90 97.5 99.9' -MetricsSnapshotEvery 5 -MetricsSnapshotPath snapshots.ndjson -IncludeSnapshotHistogram -Quiet
Get-Content snapshots.ndjson | Select-Object -First 2
```

Parsing dynamic percentiles (robust to optional keys):

```powershell
$line = Get-Content snapshots.ndjson -First 1 | ConvertFrom-Json
$pKeys = $line.percentiles | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
"Available percentile keys: $($pKeys -join ', ')"
```

See `docs/COMPARE_LOOP_MODULE.md` for full snapshot v2 schema.

Run summary quick example:

```powershell
$exec = { param($cli,$b,$h,$args) Start-Sleep -Milliseconds (5 + (Get-Random -Max 20)); 0 }
Invoke-IntegrationCompareLoop -Base VI1.vi -Head VI2.vi -MaxIterations 40 -IntervalSeconds 0 -CompareExecutor $exec -SkipValidation -PassThroughPaths -BypassCliValidation -CustomPercentiles '50,75,90,97.5,99.9' -HistogramBins 8 -RunSummaryJsonPath run-summary.json -Quiet
$summary = Get-Content run-summary.json -Raw | ConvertFrom-Json
"Final p90: $($summary.percentiles.p90) seconds (schema=$($summary.schema))"
```

Run summary schema excerpt:

```jsonc
{
  "schema": "compare-loop-run-summary-v1",
  "iterations": 40,
  "diffCount": 0,
  "averageSeconds": 0.018,
  "percentiles": { "p50": 0.017, "p75": 0.020, "p90": 0.024, "p97_5": 0.025, "p99_9": 0.028 }
}
```
