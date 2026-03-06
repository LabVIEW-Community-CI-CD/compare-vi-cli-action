<!-- markdownlint-disable-next-line MD041 -->
# Session Lock Handoff Notes

Guidance for managing the cooperative dispatcher lock used by self-hosted runs.

## Lock artefacts

- Directory: `tests/results/_session_lock/<group>/`
- Files: `lock.json` (owner metadata), `status.md` (human summary)

## Commands

```powershell
# Acquire / inspect lock
tools/SessionLock-Locate.ps1

# Force takeover (use sparingly)
tools/SessionLock-Takeover.ps1 -Group pester-selfhosted
```

## Environment controls

| Variable | Purpose |
| -------- | ------- |
| `SESSION_LOCK_ENABLED` (`CLAIM_PESTER_LOCK`) | Enable lock acquisition |
| `SESSION_LOCK_GROUP` | Lock namespace (default `pester-selfhosted`) |
| `SESSION_LOCK_FORCE` | Force takeover when stale |
| `SESSION_LOCK_STRICT` | Fail run if lock cannot be acquired |

## Agent writer lease (`#733`)

Repository-wide single-writer coordination for agent sessions now uses `tools/priority/agent-writer-lease.mjs`.

```bash
# Acquire lease for workspace mutations
node tools/npm/run-script.mjs priority:lease -- --action acquire --scope workspace

# Inspect / heartbeat / release
node tools/npm/run-script.mjs priority:lease -- --action inspect --scope workspace
node tools/npm/run-script.mjs priority:lease -- --action heartbeat --scope workspace
node tools/npm/run-script.mjs priority:lease -- --action release --scope workspace
```

Default lease root is `.git/agent-writer-leases/` (keeps workspaces clean). Useful controls:

- `AGENT_WRITER_LEASE_ENABLED=0` disables bootstrap acquisition.
- `AGENT_WRITER_LEASE_STALE_SECONDS=<n>` adjusts stale threshold.
- `AGENT_WRITER_LEASE_FORCE_TAKEOVER=1` allows stale takeover.
- `AGENT_WRITER_LEASE_MAX_ATTEMPTS=<n>` + `AGENT_WRITER_LEASE_WAIT_MS=<n>` tune contention retry behavior.

## Handoff checklist

1. Read `AGENT_HANDOFF.txt` for context.
2. Confirm lock owner in `status.md` before starting a run.
3. Use `-AutoTrim` hand-off script to print watcher summary and trim logs.
4. Release lock after run (`SessionLock-Release.ps1` or run completion).

## Troubleshooting

- Stale lock → use takeover script, document in PR/issue.
- Missing artefacts → rerun latest workflow or regenerate via dashboard (`tools/Dev-Dashboard.ps1`).

See [`docs/DEV_DASHBOARD_PLAN.md`](./DEV_DASHBOARD_PLAN.md) for telemetry aggregation and
[`docs/ENVIRONMENT.md`](./ENVIRONMENT.md) for lock-related env vars.
