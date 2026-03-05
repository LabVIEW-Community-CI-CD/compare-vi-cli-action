# Dual-Plane Operating Requirements Contract

This document defines the objective verification contract for issue #665.

## Scope

- Parent: #664
- Contract issue: #665
- Ownership map (non-overlapping):
  - #666: workspace topology
  - #667: guardrail enforcement
  - #668: snapshot/triage command + outputs

## Requirement Mapping

| Requirement | Contract statement | Executable command/check | Evidence output | Owning issue(s) |
| --- | --- | --- | --- | --- |
| R1 Plane Separation | Upstream-targeting commands never run from fork context; fork commands never mutate upstream refs directly. | `node tools/npm/run-script.mjs hooks:plane` and explicit dual-plane workspace task `cwd` wiring in `docs/DUAL_PLANE_WORKSPACES.md`. | Plane detection output from `hooks:plane`; named workspace folders and task wiring contract in docs. | #666 |
| R2 Deterministic Health Snapshot | Snapshot must output upstream SHA, fork SHA, parity verdict, required-context verdict, and latest incident run IDs. | `node tools/npm/run-script.mjs priority:health-snapshot` | `tests/results/_agent/health-snapshot/health-snapshot.json` and `tests/results/_agent/health-snapshot/health-snapshot.md` | #668 |
| R3 Guardrails | Preflight fails fast on remote/repo mismatch; destructive operations log explicit branch/repo confirmations. | `pwsh -NoLogo -NoProfile -File tools/Assert-NoAmbiguousRemoteRefs.ps1`; `pwsh -NoLogo -NoProfile -File tools/PrePush-Checks.ps1`; `node tools/npm/run-script.mjs priority:sync` | Guard script failure on ambiguous refs; pre-push gate output; standing-priority router/actions summary with repo/branch targeting. | #667 |
| R4 Incident Triage | Standard flow for cancellations/failures with timestamps, failed step, and root-cause classification. | `node tools/npm/run-script.mjs ci:watch:rest -- --run-id <id>` and `node tools/npm/run-script.mjs priority:health-snapshot` | `tests/results/_agent/watcher-rest.json`; health snapshot incidents section and degraded notes. | #668 |
| R5 Handoff Quality | Handoff includes commands, run URLs, and current open risk list. | `node tools/npm/run-script.mjs priority:handoff-tests`; `pwsh -NoLogo -NoProfile -File tools/Print-AgentHandoff.ps1 -ApplyToggles -AutoTrim` | `tests/results/_agent/handoff/test-summary.json`; handoff watcher telemetry and session capsules under `tests/results/_agent/sessions/`. | #667 |
| R6 Telemetry Contract Source | Snapshot/triage are session-index-first; no parallel long-lived run/branch/test metadata schema; migration allows v1+v2 with v2-first for new consumers. | `node tools/npm/run-script.mjs priority:health-snapshot`; `pwsh -NoLogo -NoProfile -File tools/Test-SessionIndexV2Contract.ps1`; `node tools/npm/run-script.mjs session-index:validate` | Health snapshot reports session-index source mode; v2 contract/validation outputs; migration docs and consumer matrix. | #668, #675, #676, #677, #678, #679 |

## Objective Verification Checklist

Run these commands from repository root and confirm expected artifacts/results:

1. `node tools/npm/run-script.mjs hooks:plane`
2. `pwsh -NoLogo -NoProfile -File tools/PrePush-Checks.ps1`
3. `node tools/npm/run-script.mjs priority:health-snapshot`
4. `node tools/npm/run-script.mjs ci:watch:rest -- --branch develop`
5. `node tools/npm/run-script.mjs priority:handoff-tests`
6. `pwsh -NoLogo -NoProfile -File tools/Test-SessionIndexV2Contract.ps1`
7. `node tools/npm/run-script.mjs session-index:validate`

Passing these checks demonstrates the R1-R6 contract is executable, observable, and bounded to the declared ownership map.

## Traceability Notes

- Requirement-to-issue traceability is anchored in this matrix and the linked implementation issues (#666, #667, #668).
- Telemetry migration traceability for R6 is anchored in #675 -> #676 -> #677 -> #678 -> #679.
- Follow-up issues that alter plane behavior, guardrails, snapshot/triage outputs, or telemetry schemas must update this document and keep ownership boundaries explicit.