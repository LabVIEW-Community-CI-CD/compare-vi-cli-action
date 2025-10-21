<!-- markdownlint-disable-next-line MD041 -->
# Developer Guide

Quick reference for building, testing, and releasing the LVCompare composite action.

## Testing

- **Unit tests** (no LabVIEW required)
  - `./Invoke-PesterTests.ps1`
  - `pwsh -File tools/Run-Pester.ps1`
- **Integration tests** (LabVIEW + LVCompare installed)
  - Set `LV_BASE_VI`, `LV_HEAD_VI`
  - `./Invoke-PesterTests.ps1 -IntegrationMode include`
- **Helpers**
  - `tools/Dev-Dashboard.ps1` → telemetry snapshot
  - `tools/Watch-Pester.ps1` → file watcher / retry loop
  - `tools/Detect-RogueLV.ps1 -FailOnRogue` → leak check

Artifacts land in `tests/results/` (JSON summaries, XML, loop logs).

## Building & linting

```powershell
node tools/npm/cli.mjs ci
node tools/npm/run-script.mjs build
node tools/npm/run-script.mjs generate:outputs
node tools/npm/run-script.mjs lint            # markdownlint + custom checks
./tools/PrePush-Checks.ps1  # actionlint, optional YAML round-trip
```

## Release checklist

1. Update `CHANGELOG.md`
2. Tag (semantic version, e.g. `v0.6.0`)
3. Push tag (release workflow auto-generates notes)
4. Update README usage examples to latest tag
5. Verify marketplace listing once published

## Pull request & merge policy

- Branch protection requires a linear history: use the **Squash and merge** button (or rebase-and-merge) so no merge
  commits land on `develop`/`main`.
- Keep PRs focused and include the standing issue reference (`#<number>`) in the commit subject and PR description.
- Ensure required checks (`validate`, `fixtures`, `session-index`) are green before merging; rerun as needed.

## Dispatcher modules

- `scripts/Pester-Invoker.psm1` - per-file execution with crumbs (`pester-invoker/v1`)
- `scripts/Invoke-PesterSingleLoop.ps1` - outer loop runner (unit + integration)
- `scripts/Run-AutonomousIntegrationLoop.ps1` - latency/diff soak harness

## Watch mode tips

```powershell
$env:WATCH_RESULTS_DIR = 'tests/results/_watch'
pwsh -File tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly
```

Artifacts: `watch-last.json`, `watch-log.ndjson`. Dev Dashboard surfaces these along with
queue telemetry and stakeholder contacts.

## Handoff telemetry & auto-trim

```powershell
pwsh -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim
```

- Surfaces watcher status inline (alive, verifiedProcess, heartbeatFresh/Reason, needsTrim).
- Emits a compact JSON snapshot to `tests/results/_agent/handoff/watcher-telemetry.json` and, when in CI,
  appends a summary block to the step summary.
- Auto-trim policy: if `needsTrim=true`, watcher logs are trimmed to the last ~4000 lines when either
  `-AutoTrim` is passed or `HANDOFF_AUTOTRIM=1` is set. Dev watcher also trims on start.
- Trim thresholds: ~5MB per log file; only oversized logs are trimmed.
- See [`WATCHER_TELEMETRY_DX.md`](./WATCHER_TELEMETRY_DX.md) for automation response expectations.

## Quick verification

```powershell
./tools/Quick-VerifyCompare.ps1                # temp files
./tools/Quick-VerifyCompare.ps1 -Same          # identical path preview
./tools/Quick-VerifyCompare.ps1 -Base A.vi -Head B.vi
```

Preview LVCompare command without executing:

```powershell
pwsh -File scripts/CompareVI.ps1 -Base VI1.vi -Head VI2.vi -LvCompareArgs "-nobdcosm" -PreviewArgs
```

## References

- [`docs/INTEGRATION_RUNBOOK.md`](./INTEGRATION_RUNBOOK.md)
- [`docs/TESTING_PATTERNS.md`](./TESTING_PATTERNS.md)
- [`docs/SCHEMA_HELPER.md`](./SCHEMA_HELPER.md)
- [`docs/TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)

