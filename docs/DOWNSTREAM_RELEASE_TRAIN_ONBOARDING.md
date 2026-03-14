<!-- markdownlint-disable-next-line MD041 -->
# Downstream Release Train Onboarding

This runbook defines the controlled onboarding path for issue `#715`:

- integration checklist + bootstrap script
- pilot onboarding + stabilization feedback loop
- success reporting with deltas, pain points, and hardening backlog

## Artifacts and schemas

- Onboarding report:
  - `tests/results/_agent/onboarding/downstream-onboarding.json`
  - schema: `docs/schemas/downstream-onboarding-report-v1.schema.json`
- Success report:
  - `tests/results/_agent/onboarding/downstream-onboarding-success.json`
  - schema: `docs/schemas/downstream-onboarding-success-v1.schema.json`
- Feedback status report:
  - `tests/results/_agent/onboarding/downstream-onboarding-feedback.json`
  - schema: `docs/schemas/downstream-onboarding-feedback-v1.schema.json`
- Checklist policy:
  - `tools/policy/downstream-onboarding-checklist.json`

## Bootstrap checklist command

Run the downstream bootstrap against a candidate repository:

```bash
node tools/npm/run-script.mjs priority:onboard:downstream -- \
  --repo <owner/downstream-repo> \
  --started-at <ISO-8601-utc-optional> \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding.json
```

Equivalent direct script invocation:

```bash
node tools/priority/downstream-onboarding.mjs \
  --repo <owner/downstream-repo> \
  --started-at <ISO-8601-utc-optional> \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding.json
```

What it evaluates:

- downstream repo accessibility
- workflow reference to the upstream compare-vi action
- immutable certified ref pinning (stable semver tag or full commit SHA)
- successful workflow consumption run
- protected production environment presence
- visibility of policy-required branch checks

## Pilot stabilization loop

Repeat the onboarding run after each remediation cycle:

1. Execute `downstream-onboarding.mjs` after each downstream change.
2. Fix blockers/warnings in descending severity (`P1` before `P2`).
3. Re-run until required checklist items are all `pass`.
4. Optional hardening issue creation:

```bash
node tools/priority/downstream-onboarding.mjs \
  --repo <owner/downstream-repo> \
  --parent-issue 715 \
  --create-hardening-issues \
  --issue-prefix "[onboarding]" \
  --issue-labels program,enhancement
```

## Success report generation

Aggregate one or more onboarding reports into a single success view:

```bash
node tools/npm/run-script.mjs priority:onboard:success -- \
  --report tests/results/_agent/onboarding/downstream-onboarding.json \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding-success.json
```

Equivalent direct script invocation:

```bash
node tools/priority/downstream-onboarding-success.mjs \
  --report tests/results/_agent/onboarding/downstream-onboarding.json \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding-success.json
```

The success report includes:

- per-repository deltas (`checklistPassRate`, `requiredCompletionRate`, blockers/warnings)
- aggregated pain points ranked by frequency and severity
- normalized hardening backlog for follow-up planning

Optional aggregated hardening issue creation:

```bash
node tools/priority/downstream-onboarding-success.mjs \
  --report tests/results/_agent/onboarding/downstream-onboarding.json \
  --create-hardening-issues \
  --issue-prefix "[onboarding-hardening]" \
  --issue-labels program,enhancement
```

## CI feedback loop

Workflow `.github/workflows/downstream-onboarding-feedback.yml` runs this loop on manual dispatch and weekly schedule.
It now uses a single checked-in feedback harness so the local/manual and hosted paths share the same sequencing
contract:

```bash
node tools/npm/run-script.mjs priority:onboard:feedback -- \
  --repo <owner/downstream-repo> \
  --parent-issue 715 \
  --report tests/results/_agent/onboarding/downstream-onboarding.json \
  --success-output tests/results/_agent/onboarding/downstream-onboarding-success.json \
  --feedback-output tests/results/_agent/onboarding/downstream-onboarding-feedback.json
```

The hosted workflow exports `GH_TOKEN`, attempts to leave behind a valid onboarding report even on infrastructure
failures, validates all report schemas that were produced, and uploads the resulting JSON artifacts for auditability.
It now follows the shared hosted-signal contract in [`HOSTED_SIGNAL_REPORT_FIRST_CONTRACT.md`](HOSTED_SIGNAL_REPORT_FIRST_CONTRACT.md):

- exports both `GH_TOKEN` and `GITHUB_TOKEN`
- appends a deterministic step summary from the feedback report when present
- keeps schema validation and artifact upload existence-aware so missing-report cascades do not mask the primary failure
