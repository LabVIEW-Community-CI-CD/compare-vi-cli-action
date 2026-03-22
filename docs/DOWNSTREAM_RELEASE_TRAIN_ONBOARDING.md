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
- Wake adjudication report:
  - `tests/results/_agent/issue/wake-adjudication.json`
  - schema: `docs/schemas/wake-adjudication-report-v1.schema.json`
- Monitoring work injection report:
  - `tests/results/_agent/issue/monitoring-work-injection.json`
  - schema: `docs/schemas/monitoring-work-injection-report-v1.schema.json`
- Promotion scorecard:
  - `tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json`
  - schema: `docs/schemas/downstream-promotion-scorecard-v1.schema.json`
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

Branch provenance matters here:

- `upstream/develop` is the compare producer lineage ref
- `develop` is the canonical live branch for the current template repo
- `downstream/develop` is the consumer-proving rail when the conveyor chooses to maintain one

The onboarding report now records all three branch concepts separately so a
future wake can distinguish live repo truth from compare-side proving-rail
policy instead of collapsing them into one branch string.

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
  --issue-repo LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate \
  --issue-prefix "[onboarding]" \
  --issue-labels program,enhancement
```

The hosted feedback workflow now exposes `consumer_issue_repo` so hardening issues can be routed explicitly to the
consumer repository instead of falling back to the upstream action repository. The repo-level fallback variable is
`DOWNSTREAM_CONSUMER_ISSUE_REPO`. When `--create-hardening-issues` is enabled, the consumer issue target must resolve
to the intended downstream repo, for example `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`, or the workflow
fails closed.

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

## Wake adjudication

When a downstream onboarding signal fails, replay it against current live GitHub
state before reopening work:

```bash
node tools/npm/run-script.mjs priority:wake:adjudicate -- \
  --reported tests/results/_agent/onboarding/downstream-onboarding.json \
  --revalidated-output tests/results/_agent/onboarding/downstream-onboarding-revalidated.json \
  --output tests/results/_agent/issue/wake-adjudication.json
```

Equivalent direct script invocation:

```bash
node tools/priority/wake-adjudication.mjs \
  --reported tests/results/_agent/onboarding/downstream-onboarding.json \
  --revalidated-output tests/results/_agent/onboarding/downstream-onboarding-revalidated.json \
  --output tests/results/_agent/issue/wake-adjudication.json
```

The adjudicator classifies the wake as one of:

- `live-defect`
- `stale-artifact`
- `branch-target-drift`
- `platform-permission-gap`
- `environment-only`

This keeps the loop from minting downstream issues from stale hosted artifacts
alone. The adjudication report carries both the originally reported branch truth
and the revalidated live branch truth so the next issue-injection decision can
route from evidence instead of raw failure status.

## Wake synthesis and investment accounting

Once a wake is adjudicated, turn it into repo-aware work-routing and then price
that work against the current issue-cost benchmark:

```bash
node tools/npm/run-script.mjs priority:wake:synthesize
node tools/npm/run-script.mjs priority:wake:accounting
```

The synthesis report decides whether the wake belongs to compare governance,
template work, consumer-proving drift, suppression, or monitoring. The
investment accounting report then records:

- the selected issue-cost benchmark
- the current observed wake-handling cost
- any avoided misrouting cost proxy when the wake was suppressed or re-routed
- the current payback posture for the governance slice

## Monitoring work injection

When compare is in `queue-empty` monitoring mode, the loop can use live wake
evidence to decide whether it should inject compare governance work, stay
suppressed, or route the wake outside compare without reopening the wrong repo:

```bash
node tools/npm/run-script.mjs priority:monitoring:inject-work -- \
  --wake-adjudication tests/results/_agent/issue/wake-adjudication.json \
  --wake-work-synthesis tests/results/_agent/issue/wake-work-synthesis.json \
  --wake-investment-accounting tests/results/_agent/capital/wake-investment-accounting.json \
  --output tests/results/_agent/issue/monitoring-work-injection.json
```

The monitoring injection report distinguishes:

- `created-issue` or `existing-issue` for compare-side self-healing work
- `suppressed-wake` when live replay cleared the wake
- `monitoring-only` when the signal should remain observational
- `external-route` when the supported wake belongs outside compare
- `policy-blocked` when an actionable compare wake exists but policy does not
  yet map it to a standing work lane

Optional aggregated hardening issue creation:

```bash
node tools/priority/downstream-onboarding-success.mjs \
  --report tests/results/_agent/onboarding/downstream-onboarding.json \
  --create-hardening-issues \
  --issue-prefix "[onboarding-hardening]" \
  --issue-labels program,enhancement
```

## Promotion scorecard generation

Build the downstream consumer-proving scorecard from the success + feedback outputs:

```bash
node tools/npm/run-script.mjs priority:promote:downstream:scorecard -- \
  --success-report tests/results/_agent/onboarding/downstream-onboarding-success.json \
  --feedback-report tests/results/_agent/onboarding/downstream-onboarding-feedback.json \
  --manifest-report tests/results/_agent/promotion/downstream-develop-promotion-manifest.json \
  --output tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json
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
When hardening issues are requested, it also forwards the explicit consumer issue target into the onboarding helper
surface so follow-up issues are opened in the consumer repository, not the upstream action repository.
It now follows the shared hosted-signal contract in [`HOSTED_SIGNAL_REPORT_FIRST_CONTRACT.md`](HOSTED_SIGNAL_REPORT_FIRST_CONTRACT.md):

- exports both `GH_TOKEN` and `GITHUB_TOKEN`
- appends a deterministic step summary from the feedback report when present
- records requested branch override, resolved live default branch, evaluated branch, and policy consumer rail branch separately
- emits a wake adjudication artifact so stale downstream branch/provenance signals can be suppressed before reopening work
- builds and validates the downstream promotion scorecard before artifact upload
- projects immutable downstream promotion manifest inputs into the scorecard when the manifest artifact is present
- keeps schema validation and artifact upload existence-aware so missing-report cascades do not mask the primary failure
