# Release Operations Runbook

## Objective

Define a deterministic operating model for release and promotion events so execution does not depend on a single
operator.

Related migration playbook: `docs/COMPAREVI_SHARED_PACKAGE_MIGRATION.md`.
Downstream onboarding runbook: `docs/DOWNSTREAM_RELEASE_TRAIN_ONBOARDING.md`.

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
5. Verify rollback drill health:
   - `node tools/npm/run-script.mjs priority:rollback:drill:health -- --repo <owner/repo>`
   - confirm `tests/results/_agent/release/rollback-drill-health.json` reports `status=pass`
6. Obtain environment approvals for protected deployments from GitHub UI/mobile.
7. Record evidence links in the governing issue/PR before closure.

## One-command rollback

When an incident requires rollback, run:

- Dry-run:
  - `node tools/npm/run-script.mjs release:rollback -- --stream stable`
- Apply:
  - `node tools/npm/run-script.mjs release:rollback:apply -- --stream stable`

Apply mode resolves the previous-good immutable release tag pointer for the stream, force-updates `main` and
`develop` using `--force-with-lease`, then validates branch alignment and policy sync evidence.

## Downstream onboarding loop

Use the downstream onboarding commands when validating platform adoption in consumer repositories:

- Bootstrap/evaluate one repository:
  - `node tools/npm/run-script.mjs priority:onboard:downstream -- --repo <owner/repo> --parent-issue 715`
- Aggregate success report:
  - `node tools/npm/run-script.mjs priority:onboard:success -- --report tests/results/_agent/onboarding/downstream-onboarding.json --parent-issue 715`

For unattended cadence, use `.github/workflows/downstream-onboarding-feedback.yml` and set
`vars.DOWNSTREAM_PILOT_REPO` to the current pilot repository.

## Escalation matrix

| Condition | Initial response window | Escalation path |
| --- | --- | --- |
| Required check stalled > 30 minutes | 15 minutes | Release operator -> incident commander |
| `Policy Guard (Upstream)` fails | Immediate | Incident commander + audit recorder |
| Deployment approval blocked/misrouted | 15 minutes | Deployment gate approver -> repository admin |
| Rollback-triggering regression | Immediate | Incident commander triggers rollback flow and pauses promotion |

## SLO thresholds and routing

- SLO metrics are emitted by `node tools/priority/slo-metrics.mjs` in release/promotion workflows under
  `tests/results/_agent/slo/`.
- Default breach thresholds:
  - failure rate > `0.30`
  - MTTR > `24` hours
  - stale budget > `1080` hours (45 days)
  - gate regressions > `3`
- Breach routing:
  - release/monthly workflows upsert an issue labeled `slo`, `ci`, `governance`
  - issue title prefix: `[SLO] ... breach`
  - escalation follows the matrix above

## Incident and rollback communication protocol

1. Open or update an incident issue with timestamped status.
2. Post a concise status comment in the affected PR/release issue:
   - impact
   - current gate status
   - containment action
   - next update ETA
3. If rollback is required:
   - run rollback path:
     - `node tools/npm/run-script.mjs release:rollback -- --stream stable`
     - `node tools/npm/run-script.mjs release:rollback:apply -- --stream stable`
   - publish rollback evidence artifacts
   - confirm branch/policy parity after rollback
4. Close incident only after:
   - gate health is green
   - evidence artifacts are linked
   - follow-up remediation issues are created when needed

## Supply-chain trust remediation classes

When the release trust gate fails, inspect `tests/results/_agent/supply-chain/release-trust-gate.json` and follow the
matching remediation path:

- `missing-artifacts-root`, `missing-required-file`, `no-distribution-artifacts`
  - Re-run publish steps and confirm artifacts exist under `artifacts/cli`.
- `tag-ref-missing`, `tag-ref-lookup-failed`, `tag-object-lookup-failed`, `tag-signature-parse-failed`
  - Confirm release workflow was triggered from a tag push and rerun with GitHub CLI/API access intact.
- `tag-signature-cli-unavailable`
  - Restore GitHub CLI availability on runner and retry release.
- `tag-not-annotated`, `tag-signature-unverified`
  - Recreate release tag as a signed annotated tag and rerun release.
- `checksum-invalid-line`, `checksum-empty`, `checksum-entry-missing-file`, `checksum-missing-artifact`, `checksum-mismatch`
  - Regenerate `SHA256SUMS.txt` from fresh artifacts and ensure no post-pack mutation occurred.
- `sbom-parse-failed`, `sbom-invalid`
  - Re-run `tools/Generate-ReleaseSbom.ps1` and validate content/coverage for all distribution archives.
- `provenance-parse-failed`, `provenance-invalid`
  - Re-run `tools/Generate-ReleaseProvenance.ps1`; verify repository/run/sha identity fields.
- `attestation-cli-unavailable`
  - Restore GitHub CLI availability on runner and retry release.
- `attestation-output-parse-failed`, `attestation-empty-result`, `attestation-unverified`
  - Re-run attestation and verify with:
    - `gh attestation verify <artifact> --repo <owner/repo> --signer-workflow <owner/repo/.github/workflows/release.yml>`

## Rehearsal contract (testable, repeatable)

- Weekly operator rehearsal (non-destructive):
  - `node tools/npm/run-script.mjs release:branch:dry -- <version>`
  - `node tools/npm/run-script.mjs release:finalize:dry -- <version>`
  - scheduled workflow `release-rollback-drill.yml` for rollback pointer drill evidence
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
- `tests/results/_agent/supply-chain/release-trust-gate.json`
- `tests/results/_agent/release/rollback-drill-health.json`
- `tests/results/_agent/release/rollback-drill-report.json`
- `tests/results/_agent/release/shared-source-resolution.json`
