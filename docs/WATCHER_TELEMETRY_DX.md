<!-- markdownlint-disable-next-line MD041 -->
# Watcher Telemetry DX

Design notes describing how automation (agents, scripts, CI summaries) should surface the
`Dev-WatcherManager` telemetry so hand-offs stay actionable and consistent.

## Purpose

- Provide a predictable developer experience when watcher status is reported in automation
  responses or summaries.
- Highlight the minimum telemetry fields required for quick triage (state, verification, heartbeat,
  trim hints).
- Capture fallback behaviour when watcher artefacts are missing or stale.

## Telemetry Sources

- Command: `node tools/npm/run-script.mjs dev:watcher:status` (PowerShell wrapper around
  `tools/Dev-WatcherManager.ps1 -Status`).
- JSON schema: `dev-watcher/status-v2` (written to STDOUT, optional file output).
- Artefact paths (when present):
  - `tests/results/_agent/watcher/watcher-status.json`
  - `tests/results/_agent/watcher/watcher-self.json`
  - `tests/results/_agent/watcher/watch.out`
  - `tests/results/_agent/watcher/watch.err`
  - `tests/results/_agent/watcher/watcher-trim.json`

## Consumer Surfaces

- **Agent replies / CLI automation**
  - Include a "Watcher Telemetry" section with the following fields:
    - `state` (e.g., `running`, `stopped`, `busy-suspect`).
    - `alive` and `verifiedProcess` (true/false flags).
    - `heartbeatFresh` and `heartbeatReason`.
    - `needsTrim` (true/false) and whether a trim was performed.
    - When available, `lastHeartbeatAt` or a friendly age string.
  - Mention missing artefacts explicitly (e.g., "status JSON absent") to avoid ambiguity.
- **CI step summaries**
  - Use `tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim` to append a condensed block.
  - Ensure summaries retain the same field names for searchability.
  - Include artefact presence lines for `status.json` and `heartbeat.json` (present/missing).
- **Handoff JSON snapshot**
  - Persist the raw status payload to `tests/results/_agent/handoff/watcher-telemetry.json`.
  - Include the command timestamp and any trim action metadata for downstream tools.
  - Validate against `docs/schemas/watcher-telemetry.v1.schema.json` when running schema checks.

## Response Template

Automation should adapt this outline when composing replies:

````markdown
**Watcher Telemetry**
- state: `stopped` (alive=false, verifiedProcess=false)
- heartbeat: fresh=`false` (`[heartbeat] missing`)
- trim: performed=`no`, needsTrim=`false`
- artefacts: status=`missing`, heartbeat=`missing`
````

Optional additions:

- Elapsed duration since `lastActivityAt`.
- PID or command line when `verifiedProcess=true`.
- Link to trimmed log artefacts when available.

## Automation Checklist

1. Apply LabVIEW safety toggles:
   - `LV_SUPPRESS_UI=1`, `LV_NO_ACTIVATE=1`, `LV_CURSOR_RESTORE=1`,
     `LV_IDLE_WAIT_SECONDS=2`, `LV_IDLE_MAX_WAIT_SECONDS=5`.
2. Run `tools/Detect-RogueLV.ps1` and report any rogue LabVIEW/LVCompare PIDs before taking
   action.
3. Execute `node tools/npm/run-script.mjs dev:watcher:status` (or call `tools/Dev-WatcherManager.ps1 -Status`
   in-process) and capture the output.
4. Summarise the required fields in the reply (or step summary) using the template above.
5. If `needsTrim=true`, call `node tools/npm/run-script.mjs dev:watcher:trim` (or
   `Print-AgentHandoff.ps1 -AutoTrim`) and mention the trim result; otherwise note that no trim was necessary.
6. Record anomalies: missing artefacts, schema mismatches, stale timestamps, or command failures.

## Edge Cases

- **Watcher not running**: Report `state=stopped`, `alive=false`, `heartbeatFresh=false`, and confirm
  the absence of heartbeat files.
- **Heartbeat stale**: Include the stale age and recommend running `node tools/npm/run-script.mjs dev:watcher:trim` or
  restarting via `node tools/npm/run-script.mjs dev:watcher:ensure`.
- **Schema drift**: If the status command emits an unexpected schema version, attach the raw JSON
  path for follow-up and avoid parsing assumptions.
- **Command failure**: Surface the non-zero exit code and stderr snippet; retry once before asking
  for human intervention.

## Future Enhancements

- Auto-post trimmed watcher summaries to PR comments when `needsTrim=true`.
- Consolidate rogue detection + watcher telemetry into a single helper to reduce redundant
  commands.
- Add rich formatting (emoji/icons) to CI summaries once markdown rendering is standardised.
