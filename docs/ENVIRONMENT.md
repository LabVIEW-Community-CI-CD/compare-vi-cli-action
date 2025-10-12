<!-- markdownlint-disable-next-line MD041 -->
# Environment Variables (Windows)

Reference for toggles consumed by the LVCompare action, dispatcher, and supporting scripts.
All values are strings; use `1` / `0` for boolean-style flags.

## Core inputs

| Variable | Purpose |
| -------- | ------- |
| `LV_BASE_VI`, `LV_HEAD_VI` | Paths to base/head VIs for integration tests |
| `LVCI_COMPARE_MODE` | `lvcompare` (default) or `labview-cli` to route through LabVIEW CLI |
| `LVCI_GCLI_MODE` | `off` (default) or `compare` to route through g-cli |
| `LABVIEW_CLI_PATH` | Optional explicit path to `LabVIEWCLI.exe` when using CLI mode |
| `GCLI_PATH` | Optional explicit path to `g-cli` executable |
| `GCLI_ARGS` | Optional argument string for a one-off g-cli action in CI (e.g., `--version` or a custom LabVIEW-close command) |
| `LVCI_CLI_FORMAT` | LabVIEW CLI report format (`XML`, `HTML`, `TXT`, `DOCX`; default `XML`) |
| `LVCI_CLI_EXTRA_ARGS` | Additional flags appended to `CreateComparisonReport` (e.g. `--noDependencies`) |
| `LVCI_CLI_TIMEOUT_SECONDS` | Timeout for LabVIEW CLI invocation (default `120`) |
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
| `CLOSE_MODE` | `auto` (default), `labview-cli`, or `g-cli` to select the close strategy |
| `CLOSE_TIMEOUT_SECONDS` | Timeout for Close-LabVIEW.ps1 graceful attempt (default 30) |
| `CLOSE_FORCEKILL_SECONDS` | Optional delay before best-effort kill if graceful close times out (default 0 = disabled) |

## Invoker controls

| Variable | Purpose |
| -------- | ------- |
| `LVCI_SINGLE_COMPARE` | Gate additional compare requests after first run |
| `LVCI_SINGLE_COMPARE_AUTOSTOP` | Auto-stop invoker when single compare completes |

## Runbook & fixture reporting

| Variable | Purpose |
| -------- | ------- |
| `RUNBOOK_LOOP_ITERATIONS`, `RUNBOOK_LOOP_QUICK`, `RUNBOOK_LOOP_FAIL_ON_DIFF` | Integration runbook knobs |
| `FAIL_ON_NEW_STRUCTURAL`, `SUMMARY_VERBOSE` | Fixture reporting strictness |
| `DELTA_FORCE_V2`, `DELTA_SCHEMA_VERSION` | Fixture delta schema selection |

Use workflow inputs for most toggles; fall back to env variables for local runs and CI
experiments. Unknown variables are ignored.
