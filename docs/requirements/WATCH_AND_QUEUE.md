# Watch and Queue Telemetry — Requirements

## Overview
Defines conventions, structures, and minimum behaviors for watch-mode and queue telemetry so Dev Dashboard can ingest and act on them consistently across local runs and CI.

## Artifacts & Locations
- Watch Mode (default root `WATCH_RESULTS_DIR`, fallback: `tests/results/_watch`)
  - `watch-last.json`: latest run snapshot
  - `watch-log.ndjson`: append-only history; each JSON document separated by a blank line
- Queue (Agent Wait) (root `tests/results/_agent`)
  - `wait-last.json`: latest agent wait window
  - `wait-log.ndjson`: line-delimited history documents (blank-line separated)

## Structures (Schema-Lite)
- Watch Last: `docs/schemas/watch-last-v1.schema.json`
  - Required: `timestamp` (date-time), `status` (PASS|FAIL), `classification` (baseline|improved|worsened|unchanged), `stats.tests`, `stats.failed`
  - Optional: `runSequence`, `stats.skipped`, `flaky.recoveredAfter`
- Watch Log Item: `docs/schemas/watch-log-item-v1.schema.json`
- Agent Wait Last: `docs/schemas/agent-wait-last-v1.schema.json`
- Agent Wait Log Item: `docs/schemas/agent-wait-log-item-v1.schema.json`

## Loader Behavior (Dev-Dashboard)
- Watch:
  - Ingests `watch-last.json` and `watch-log.ndjson` when present
  - Computes `StalledSeconds` (time since last history entry) and `Stalled` (true if > 600s)
- Agent Wait:
  - Ingests `wait-last.json` and derives history/longest from `wait-log.ndjson`

## Action Items
- Watch:
  - Warn on stalled loop (`StalledSeconds > 600`)
  - Warn on `classification = worsened` with `failed > 0`
  - Info: flaky recovery detected (`flaky.recoveredAfter` present)
- Queue:
  - Warn when latest wait exceeds tolerance (`withinMargin = false`)
  - Warn when longest recorded wait is > 600 seconds

## CI & Validation
- Pester Reusable job:
  - Runs a fast watch smoke (`-SingleRun`) to produce watch outputs
  - Validates watch/queue artifacts against schema-lite (notice-only; does not fail CI)
- Optional: orchestrated publish watch smoke guarded by repo var `WATCH_SMOKE_ENABLE` (default: off)

## Acceptance Criteria
- Watch and queue artifacts exist where enabled and pass schema-lite validation
- Dev Dashboard (terminal/HTML/JSON) surfaces Watch Mode and Queue history
- Action items trigger correctly for stalled/worsened and tolerance/longest conditions
- CI dashboards and artifact links present in step summaries; added runtime stays minimal

---

See also: `docs/DEV_DASHBOARD_PLAN.md` (test plan), `tools/Dev-Dashboard.psm1` (loaders), `tools/Dev-Dashboard.ps1` (CLI), `tools/Watch-Pester.ps1` (writer).
