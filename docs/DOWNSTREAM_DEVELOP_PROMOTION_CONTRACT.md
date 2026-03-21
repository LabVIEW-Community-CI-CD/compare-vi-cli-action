<!-- markdownlint-disable-next-line MD041 -->
# Downstream Develop Promotion Contract

`downstream/develop` is the consumer proving rail between internal integration and release.
It is not a second feature-development branch.

## Contract source of truth

- Policy file: `tools/policy/downstream-promotion-contract.json`
- Workflow: `.github/workflows/downstream-promotion.yml`
- Required check context: `Downstream Promotion / downstream-promotion`
- Manifest generator: `tools/priority/downstream-promotion-manifest.mjs`
- Manifest schema: `docs/schemas/downstream-promotion-manifest-v1.schema.json`
- Default output: `tests/results/_agent/promotion/downstream-develop-promotion-manifest.json`
- Proving scorecard generator: `tools/priority/downstream-promotion-scorecard.mjs`
- Proving scorecard schema: `docs/schemas/downstream-promotion-scorecard-v1.schema.json`
- Proving scorecard output: `tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json`
- Selection resolver: `tools/priority/resolve-downstream-proving-artifact.mjs`
- Selection schema: `docs/schemas/downstream-proving-selection-v1.schema.json`
- Selection output: `tests/results/_agent/release/downstream-proving-selection.json`

## Branch contract

- Source ref: `upstream/develop`
- Target branch: `downstream/develop`
- Target branch class: `downstream-consumer-proving-rail`
- Direct feature development on `downstream/develop`: unsupported

Every promotion into `downstream/develop` must be explainable from immutable inputs.
At minimum that means:

- exact `upstream/develop` commit SHA
- CompareVI.Tools release identity
- `comparevi-history` release identity
- scenario-pack or corpus identity
- cookiecutter/template identity
- proving scorecard reference
- actor and timestamp

## Replay and rollback

- `promote`
  - first-class move from `upstream/develop` into `downstream/develop`
- `replay`
  - reruns the same immutable proving inputs and emits a fresh manifest
- `rollback`
  - references a prior manifest and re-establishes a previously proven downstream state

Rollback and replay should reference a prior manifest instead of relying on ad hoc branch edits.

## CLI

Generate the downstream proving scorecard first:

```powershell
node tools/npm/run-script.mjs priority:promote:downstream:scorecard -- `
  --success-report tests/results/_agent/onboarding/downstream-onboarding-success.json `
  --feedback-report tests/results/_agent/onboarding/downstream-onboarding-feedback.json `
  --output tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json
```

Generate a manifest:

```powershell
node tools/npm/run-script.mjs priority:promote:downstream:manifest -- `
  --source-sha 2e058f794595649c2beeb1b531ca8f5401d1ead5 `
  --comparevi-tools-release v0.6.3-tools.14 `
  --comparevi-history-release v1.3.24 `
  --scenario-pack-id scenario-pack@v1 `
  --cookiecutter-template-id LabviewGitHubCiTemplate@v0.1.0 `
  --proving-scorecard-ref tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json `
  --actor SergioVelderrain
```

The command fails closed when the required immutable inputs are missing or when the local
`upstream/develop` ref resolves to a different commit than the requested source SHA.

## Hosted promotion workflow

Use `.github/workflows/downstream-promotion.yml` when the proving rail should be advanced from
checked-in automation instead of ad hoc local git mutation.

The workflow:

- verifies that the requested `source_sha` still matches `upstream/develop`
- runs downstream onboarding feedback against the requested consumer repository
- emits `downstream-develop-promotion-manifest.json`
- emits `downstream-develop-promotion-scorecard.json`
- advances `downstream/develop` only when the downstream promotion scorecard passes

## Release consumption

Release promotion should consume the downstream proving rail through the
`Downstream Promotion` workflow artifact, not from the onboarding-only feedback
workflow.

That means release should select a successful `downstream-promotion.yml` run
whose `downstream-develop-promotion-scorecard.json`:

- reports `summary.status = pass`
- proves `targetBranch = downstream/develop`
- records `summary.provenance.sourceCommitSha` matching the release source commit

Release evidence should retain the machine-readable selection report that points
back to the exact downstream promotion run and scorecard artifact used.

## Template pivot gate

When `compare-vi-cli-action` reaches release-candidate state and the standing
queue is empty, the next move is a checked-in pivot gate rather than operator
steering.

- Policy: `tools/policy/template-pivot-gate.json`
- Evaluator: `tools/priority/template-pivot-gate.mjs`
- Output: `tests/results/_agent/promotion/template-pivot-gate-report.json`
- Target repository: `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`

The gate only reports `ready` when all of the following are true:

- `tests/results/_agent/issue/no-standing-priority.json` exists with
  `reason = queue-empty`
- `openIssueCount = 0`
- `tests/results/_agent/handoff/release-summary.json` is valid and its version
  matches `X.Y.Z-rc.N`
- `tests/results/_agent/handoff/entrypoint-status.json` reports `status = pass`
- the policy still requires a future agent, disallows operator steering, and
  requires precise session feedback at pivot time

Run the evaluator with:

```powershell
node tools/npm/run-script.mjs priority:pivot:template
```

`ready` means a future agent may pivot into
`LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`. `blocked` means
`compare-vi-cli-action` stays in focus until the evidence gap closes.
