# Release Operations Runbook

## Objective

Define a deterministic operating model for release and promotion events so execution does not depend on a single
operator.

## Scope

- Promotion events (`rc -> stable -> lts`) and monthly stability cuts.
- Deployment approval gates (`validation`, `production`, `monthly-stability-release`).
- Incident triage, escalation, and rollback communication.

## Roles and ownership

| Role | Responsibility | Evidence owner |
| --- | --- | --- |
| Release operator | Runs release helpers/workflows, verifies required checks and policy gates. | Release artifacts under `tests/results/_agent/release/` |
| Deployment gate approver | Approves environment-protected deployments from GitHub web/mobile. | Environment deployment record + workflow summary |
| Incident commander | Declares incident severity, coordinates containment, drives rollback decision. | Incident timeline issue/comment thread |
| Audit recorder | Confirms promotion/rollback evidence is complete and linked in issue/PR context. | Promotion contract artifacts + issue closure notes |

## Environment protection mapping

Configure these roles as required reviewers in GitHub repository environment settings.

| Environment | Workflow entrypoints | Required reviewer role |
| --- | --- | --- |
| `validation` | PR validation flows (`Validate / lint`, deployment-backed PR checks) | Deployment gate approver |
| `production` | Tag release flow (`Release on tag / release`) | Deployment gate approver |
| `monthly-stability-release` | Scheduled/manual monthly stability cut | Deployment gate approver + incident commander (on exceptions) |

Configuration path: `Settings -> Environments -> <environment> -> Required reviewers`.

## Standard release procedure

1. Verify standing-priority and branch parity:
   - `pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1`
   - `node tools/npm/run-script.mjs priority:develop:sync`
2. Create release branch:
   - `node tools/npm/run-script.mjs release:branch -- <version>`
3. Validate required checks and policy gate:
   - `pwsh -NoLogo -NoProfile -File tools/PrePush-Checks.ps1`
   - `node tools/npm/run-script.mjs priority:policy:sync`
4. Finalize release (draft tag + metadata):
   - `node tools/npm/run-script.mjs release:finalize -- <version>`
5. Obtain environment approvals for protected deployments from GitHub UI/mobile.
6. Record evidence links in the governing issue/PR before closure.

## Escalation matrix

| Condition | Initial response window | Escalation path |
| --- | --- | --- |
| Required check stalled > 30 minutes | 15 minutes | Release operator -> incident commander |
| `Policy Guard (Upstream)` fails | Immediate | Incident commander + audit recorder |
| Deployment approval blocked/misrouted | 15 minutes | Deployment gate approver -> repository admin |
| Rollback-triggering regression | Immediate | Incident commander triggers rollback flow and pauses promotion |

## Incident and rollback communication protocol

1. Open or update an incident issue with timestamped status.
2. Post a concise status comment in the affected PR/release issue:
   - impact
   - current gate status
   - containment action
   - next update ETA
3. If rollback is required:
   - run rollback path (or release-finalize dry-run rehearsal first if diagnosis is uncertain)
   - publish rollback evidence artifacts
   - confirm branch/policy parity after rollback
4. Close incident only after:
   - gate health is green
   - evidence artifacts are linked
   - follow-up remediation issues are created when needed

## Rehearsal contract (testable, repeatable)

- Weekly operator rehearsal (non-destructive):
  - `node tools/npm/run-script.mjs release:branch:dry -- <version>`
  - `node tools/npm/run-script.mjs release:finalize:dry -- <version>`
- Monthly governance rehearsal:
  - manual dispatch of `monthly-stability-release` with environment approvals
  - evidence ledger review in promotion-contract artifacts
- Incident rehearsal:
  - run `node tools/npm/run-script.mjs priority:health-snapshot`
  - simulate escalation notes in issue comments using the protocol above

## Required evidence artifacts

- `tests/results/_agent/release/release-<tag>-branch.json`
- `tests/results/_agent/release/release-<tag>-finalize.json`
- `tests/results/_agent/policy/policy-drift-report.json`
- `tests/results/_agent/health-snapshot/health-snapshot.json`

