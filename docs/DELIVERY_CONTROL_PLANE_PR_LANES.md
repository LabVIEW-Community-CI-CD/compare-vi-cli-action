# Delivery Control Plane PR Lanes (#809)

This scaffold tracks the six planned mergeable slices so agents can resume deterministically after context compaction.

## Branch map

| PR | Issue | Branch | Scope | Status | Required artifacts |
| --- | --- | --- | --- | --- | --- |
| PR1 | #813 | `codex/pr1-813-adaptive-throughput-controller` | Adaptive throughput controller (2/3/5 + hysteresis) | committed | `tests/results/_agent/queue/throughput-controller-state.json` |
| PR2 | #814 | `codex/pr2-814-readiness-buffer-admission` | Readiness buffer + admission scoring | committed | `tests/results/_agent/queue/queue-readiness-report.json` |
| PR3 | #814 | `codex/pr3-814-release-burst-windows` | Burst windows and backoff | committed | `tests/results/_agent/queue/queue-supervisor-report.json` |
| PR4 | #809 child | `codex/pr4-809-queue-aware-release-conductor` | Queue-aware release conductor (CLI stream) | in-progress | `tests/results/_agent/release/release-conductor-report.json` |
| PR5 | #813 | `codex/pr5-813-remediation-slo-evaluator` | Remediation SLO evaluator + governance transitions | pending | `tests/results/_agent/slo/remediation-slo-report.json` |
| PR6 | #815 | `codex/pr6-815-weekly-scorecards-gameday` | Weekly scorecards + canary game-day | pending | `tests/results/_agent/slo/weekly-scorecard.json` |

## Sequencing notes

- Keep each lane mergeable and production-safe in isolation.
- Rebase each next lane on merged upstream `develop` before opening its PR.
- Preserve signed-tag policy; release conductor must remain proposal-only when signing material is unavailable.

## Resume commands

Run these after any compaction/restart before editing:

```powershell
pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1
git fetch upstream --prune
git ls-remote --heads upstream "codex/pr*"
git checkout codex/pr2-814-readiness-buffer-admission
```

## Compaction checkpoint contract

Add this JSON block to issue `#809` (or lane issue) when handing off:

```json
{
  "schema": "delivery-control-plane/checkpoint@v1",
  "programIssue": 809,
  "lane": "PR2",
  "issue": 814,
  "branch": "codex/pr2-814-readiness-buffer-admission",
  "headSha": "<commit-sha>",
  "status": "in-progress|ready|blocked|merged",
  "evidence": {
    "tests": [
      "node --test tools/priority/__tests__/queue-readiness.test.mjs",
      "node --test tools/priority/__tests__/queue-readiness-schema.test.mjs",
      "node --test tools/priority/__tests__/queue-supervisor.test.mjs",
      "node --test tools/priority/__tests__/*.mjs",
      "./bin/actionlint.exe -color"
    ],
    "artifacts": [
      "tests/results/_agent/queue/queue-readiness-report.json",
      "tests/results/_agent/queue/queue-supervisor-report.json",
      "tests/results/_agent/queue/throughput-controller-state.json"
    ]
  },
  "nextLane": "PR3"
}
```
