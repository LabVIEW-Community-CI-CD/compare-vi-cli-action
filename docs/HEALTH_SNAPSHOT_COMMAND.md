<!-- markdownlint-disable-next-line MD041 -->
# Health Snapshot Command

## Purpose

Generate a one-command deterministic health snapshot for standing-priority triage.

Outputs:

- JSON: `tests/results/_agent/health-snapshot/health-snapshot.json`
- Markdown: `tests/results/_agent/health-snapshot/health-snapshot.md`

## Command

```bash
node tools/npm/run-script.mjs priority:health-snapshot
```

## Data sources

The command prefers canonical telemetry from session-index artifacts and reports source mode explicitly:

1. Session index source: `session-index-v2.json` → fallback `session-index.json`
2. Parity: `tools/priority/report-origin-upstream-parity.mjs`
3. Required-context verdict: `branchProtection` from session-index when available; otherwise
   `tools/Get-BranchProtectionRequiredChecks.ps1`
4. Incident runs: `watchers.rest` from session-index when available; otherwise GitHub Actions API fallback

If canonical telemetry is unavailable, output includes explicit degraded-mode notes.

## Token resolution

Credential lookup order:

1. `GH_TOKEN`
2. `GITHUB_TOKEN`
3. local token file fallback (`C:\github_token.txt` or `/mnt/c/github_token.txt`)

## Command-center usage

Run from the command-center workspace root to produce link-ready output for issue comments and handoff.
