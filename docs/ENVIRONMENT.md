# Environment Reference (Windows)

This appendix lists environment variables recognized by this repository’s GitHub Action, scripts, and test dispatcher. Values are read as strings; use '1'/'0' for booleans unless noted.

> Note: Windows-only. LVCompare must exist at the canonical path:
> C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe

## Core Paths and Inputs

| Variable | Purpose | Example | Default |
|---------|---------|---------|---------|
| LV_BASE_VI | Path to base VI (tests, helpers) | C:\\repo\\VI1.vi | — (required for integration tests) |
| LV_HEAD_VI | Path to head VI (tests, helpers) | C:\\repo\\VI2.vi | — (required for integration tests) |
| LVCOMPARE_PATH | Optional hint for LVCompare path (must resolve to canonical) | C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe | — |

## Test Dispatcher: Leak Detection, Cleanup, Artifacts

Used by `Invoke-PesterTests.ps1` to keep runs deterministic and diagnose leaks.

| Variable | Purpose | Accepted values | Default |
|---------|---------|------------------|---------|
| DETECT_LEAKS | Enable leak detection during run | 1/0 | 0 |
| FAIL_ON_LEAKS | Fail the run if leaks are detected | 1/0 | 0 |
| KILL_LEAKS | Attempt to auto-stop leaked procs/jobs | 1/0 | 0 |
| LEAK_PROCESS_PATTERNS | Comma/semicolon-separated process patterns | LVCompare,LabVIEW,LabVIEWCLI | LVCompare,LabVIEW |
| LEAK_GRACE_SECONDS | Seconds to wait before final leak check | float (e.g., 0.25) | 0 |
| CLEAN_LABVIEW | Pre-run best-effort stop of LabVIEW/LVCompare | 1/0 | 0 |
| CLEAN_AFTER | Post-run best-effort stop of LabVIEW/LVCompare | 1/0 | 0 |
| SCAN_ARTIFACTS | Enable artifact trail (pre/post hashing) | 1/0 | 0 |
| ARTIFACT_GLOBS | Roots to include in trail | ';' or ',' separated paths | repo defaults |

Artifacts written when enabled:

- `tests/results/pester-leak-report.json` (schema: `docs/schemas/pester-leak-report-v1.schema.json`)
- `tests/results/pester-artifacts-trail.json` (when `SCAN_ARTIFACTS=1`)

## Loop Mode (Runner and Module)

Subset commonly used by `scripts/Run-AutonomousIntegrationLoop.ps1` and loop-enabled action runs.

| Variable | Purpose | Example | Default |
|---------|---------|---------|---------|
| LOOP_SIMULATE | Simulate loop (no real CLI) | 1/0 | 0 |
| LOOP_MAX_ITERATIONS | Max iterations | 100 | 30 |
| LOOP_INTERVAL_SECONDS | Delay between iterations | 0.1 | 0 |
| LOOP_DIFF_SUMMARY_FORMAT | Diff summary output (Html/Markdown) | Html | Html |
| LOOP_EMIT_RUN_SUMMARY | Emit final run summary JSON | 1/0 | 1 |
| LOOP_JSON_LOG | NDJSON event log path | loop-events.ndjson | — |
| LOOP_HISTOGRAM_BINS | Histogram bin count | 20 | 0 (disabled) |

For full loop inputs/outputs and percentile strategies, see `docs/COMPARE_LOOP_MODULE.md`.

## Fixture Validation and Reporting

| Variable | Purpose | Accepted values | Default |
|---------|---------|------------------|---------|
| FAIL_ON_NEW_STRUCTURAL | Fail when a new structural issue category appears | 1/0 | 0 |
| SUMMARY_VERBOSE | Enrich job/file summary output | 1/0 | 0 |
| DELTA_FORCE_V2 | Force delta schema v2 emission | 1/0 | 0 |
| DELTA_SCHEMA_VERSION | Select delta schema version (v1\|v2) | v2 | v1 |

See README sections “Fixture Validator (Refined)” and “Fixture Validation Reporting Enhancements” for details and workflow snippets.

---

If a variable here conflicts with a script parameter, the explicit parameter wins. Unknown variables are ignored. When in doubt, prefer inputs in workflow YAML and use env vars for local runs and CI toggles.
