<!-- markdownlint-disable-next-line MD041 -->
# Troubleshooting Guide

Common issues when running the LVCompare composite action.

## Installation / path issues

### LVCompare not found

Symptoms: "LVCompare.exe not found at canonical path".

Fix:

```powershell
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
```

Only the canonical path is supported; ensure LabVIEW 2025 Q3 (compare feature) is installed.

### Custom path rejected

Even when `lvComparePath`/`LVCOMPARE_PATH` is provided, it must resolve to the canonical
location. Update the runner install if the CLI lives elsewhere.

## Exit codes & behaviour

| Exit code | Meaning | Notes |
| --------- | ------- | ----- |
| 0 | Identical | No diffs detected |
| 1 | Differences | Review outputs, HTML report |
| 2 | Invocation error | Inspect logs, rerun locally |

Set `fail-on-diff: false` to treat code 1 as notice-only.

## Performance checklist

- Use noise filters (`-noattr -nofp -nofppos -nobd -nobdcosm`).
- Shorten paths with `working-directory`.
- For UNC/long paths, map a drive or enable long-path support.

## Watcher / busy-loop signals

- `[hang-watch]` / `[hang-suspect]` → idle for extended periods.
- `[busy-watch]` / `[busy-suspect]` → log growing without progress markers.
- Use `node tools/npm/run-script.mjs dev:watcher:status` to inspect heartbeat freshness; run
  `node tools/npm/run-script.mjs dev:watcher:trim` if `needsTrim=true`.

## Loop mode hiccups

- Check `tests/results/loop/**` for JSON logs and timing stats.
- Enable leak detection (`tools/Detect-RogueLV.ps1 -FailOnRogue`).
- Close LVCompare after loop runs (`tools/Close-LVCompare.ps1`).
- Post-run cleanup retries LabVIEW shutdown automatically (up to three attempts). If it still fails, inspect `tests/results/_agent/post/post-run-cleanup.log`—the script now reports remaining PID lists before throwing so you can terminate them manually.

## Test environment tips

- Run `./Invoke-PesterTests.ps1 -IntegrationMode include` to repro CI suites.
- Use `tools/Dev-Dashboard.ps1` for a quick telemetry snapshot (locks, queue waits).
- Hand-offs: `tools/Print-AgentHandoff.ps1 -AutoTrim` surfaces watcher state and trims logs.

## Further reading

- [`README.md`](../README.md)
- [`docs/USAGE_GUIDE.md`](./USAGE_GUIDE.md)
- [`docs/COMPARE_LOOP_MODULE.md`](./COMPARE_LOOP_MODULE.md)
- [`docs/DEV_DASHBOARD_PLAN.md`](./DEV_DASHBOARD_PLAN.md)

