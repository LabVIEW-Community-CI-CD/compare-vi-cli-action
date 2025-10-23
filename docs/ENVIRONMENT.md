<!-- markdownlint-disable-next-line MD041 -->
# Environment Variables (Windows)

Reference for toggles consumed by the LVCompare action, dispatcher, and supporting scripts.
All values are strings; use `1` / `0` for boolean-style flags.

## Core inputs

| Variable | Purpose |
| -------- | ------- |
| `LV_BASE_VI`, `LV_HEAD_VI` | Paths to base/head VIs for integration tests |
| `LVCOMPARE_PATH` | Optional override for LVCompare.exe (must resolve to canonical path) |
| `WORKING_DIRECTORY` | Process CWD when invoking LVCompare |

## Dispatcher guards (leak detection / cleanup)

| Variable | Notes |
| -------- | ----- |
| `DETECT_LEAKS` / `FAIL_ON_LEAKS` | Enable leak scan and optionally fail runs |
| `KILL_LEAKS` | Attempt to terminate leaked LVCompare/LabVIEW processes |
| `LEAK_PROCESS_PATTERNS` | Comma- or semicolon-separated process names |
| `LEAK_GRACE_SECONDS` | Delay before final leak pass |
| `CLEAN_LV_BEFORE`, `CLEAN_LV_AFTER`, `CLEAN_LV_INCLUDE_COMPARE` | Runner unblock guard defaults |
| `SCAN_ARTIFACTS`, `ARTIFACT_GLOBS` | Enable artefact trail JSON |
| `SESSION_LOCK_ENABLED`, `SESSION_LOCK_GROUP` | Cooperative dispatcher lock |
| `SESSION_LOCK_FORCE`, `SESSION_LOCK_STRICT` | Takeover / fail-fast behaviour |

Artefacts: `tests/results/pester-leak-report.json`, `tests/results/pester-artifacts-trail.json`.

## Loop mode

| Variable | Purpose |
| -------- | ------- |
| `LOOP_SIMULATE` | Use internal mock executor (CI-safe) |
| `LOOP_MAX_ITERATIONS`, `LOOP_INTERVAL_SECONDS` | Iteration count and delay |
| `LOOP_DIFF_SUMMARY_FORMAT` | `Html`, `Markdown`, etc. |
| `LOOP_EMIT_RUN_SUMMARY` | Emit JSON summary |
| `LOOP_JSON_LOG`, `LOOP_HISTOGRAM_BINS` | NDJSON log and histogram options |
| `LOOP_LABVIEW_VERSION`, `LOOP_LABVIEW_BITNESS`, `LOOP_LABVIEW_PATH` | Control post-loop closer |

## Invoker controls

| Variable | Purpose |
| -------- | ------- |
| `LVCI_SINGLE_COMPARE` | Gate additional compare requests after first run |
| `LVCI_SINGLE_COMPARE_AUTOSTOP` | Auto-stop invoker when single compare completes |

## Compare mode (CLI)

| Variable | Purpose |
| -------- | ------- |
| `LVCI_COMPARE_MODE` | Select compare mechanism: `labview-cli` or `lvcompare` |
| `LVCI_COMPARE_POLICY` | Mode policy: `cli-only` (default), `cli-first`, `lv-first`, `lv-only` |
| `LABVIEW_CLI_PATH` | Optional override for `LabVIEWCLI.exe` (defaults below) |

Notes:

- Scope: these toggles apply to harness and workflow helpers (e.g., `cli-compare.yml`, TestStand/dispatcher wrappers)
  and do not affect the composite action. The composite action always invokes LVCompare.
- On 64-bit Windows hosts, automation defaults the CLI path to:
  `C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe` when
  no CLI path overrides are set.
- With `LVCI_COMPARE_POLICY=cli-only` (or `LVCI_COMPARE_MODE=labview-cli` and not `lv-only`), both
  the wrapper and the TestStand harness invoke the LabVIEW CLI directly to generate an HTML report
  and enrich `lvcompare-capture.json` with an `environment.cli` metadata block (path, version,
  reportType, reportPath, status, message).
- When a CLI report is produced, embedded artefacts (for example, diff images) are decoded into
  `tests/results/<session>/compare/cli-images/`, and `environment.cli.artifacts` records the report
  size, image count, and exported file paths so downstream tooling can rehydrate attachments.
- Dedicated shim entry points follow the versioned pattern documented in
  [`docs/LabVIEWCliShimPattern.md`](./LabVIEWCliShimPattern.md) (current version: 1.0).

## Tooling helpers

| Variable | Purpose |
| -------- | ------- |
| `COMPAREVI_TOOLS_IMAGE` | Default image when `-UseToolsImage` is set without `-ToolsImageTag`. |
|                          | Used by `tools/Run-NonLVChecksInDocker.ps1`. |
|                          | Example: `ghcr.io/labview-community-ci-cd/comparevi-tools:latest`. |

## Schema locations

- Static JSON Schemas live under `docs/schemas/` (including watcher telemetry at
  `docs/schemas/watcher-telemetry.v1.schema.json`).
- Generated schemas remain under `docs/schema/generated/`.

## Runbook & fixture reporting

| Variable | Purpose |
| -------- | ------- |
| `RUNBOOK_LOOP_ITERATIONS`, `RUNBOOK_LOOP_QUICK`, `RUNBOOK_LOOP_FAIL_ON_DIFF` | Integration runbook knobs |
| `FAIL_ON_NEW_STRUCTURAL`, `SUMMARY_VERBOSE` | Fixture reporting strictness |
| `DELTA_FORCE_V2`, `DELTA_SCHEMA_VERSION` | Fixture delta schema selection |

Use workflow inputs for most toggles; fall back to env variables for local runs and CI
experiments. Unknown variables are ignored.

