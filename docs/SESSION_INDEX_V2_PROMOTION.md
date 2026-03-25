<!-- markdownlint-disable-next-line MD041 -->
# Session Index v2 Contract Promotion

## Goal

Promote `session-index-v2-contract` from burn-in (non-blocking) to required status only after deterministic evidence.

## Contract health scope

The check validates:

- `session-index-v2.json` exists and passes schema validation.
- `branchProtection.expected`/`branchProtection.actual` are populated.
- Required branch-check contexts from `tools/policy/branch-required-checks.json` are represented in
  `branchProtection.expected`.
- Session index artifacts are complete (`session-index.json` and `session-index-v2.json`).

## Burn-in policy

- Threshold: **10 consecutive successful upstream runs**.
- The check writes `session-index-v2-contract.json` with burn-in counters, promotion readiness, and a
  machine-readable `burnInReceipt` node.
- The check also writes `session-index-v2-disposition.json`, a compact summary that projects the latest burn-in
  disposition without requiring a reader to inspect the full failure list first.
- The cutover helper writes `session-index-v2-cutover-readiness.json`, a machine-readable readiness report that projects
  promotion evidence together with the v1 deprecation checklist state.
- The promotion-decision helper writes `session-index-v2-promotion-decision.json`, a machine-readable front door that
  combines the latest upstream Validate artifact bundle with repo policy/config state and classifies the next action as
  `hold-burn-in`, `ready-to-promote`, `promotion-config-drift`, `already-enforced`, or an evidence failure.
- Schemas for both artifacts live in:
  - `docs/schemas/session-index-v2-contract-v1.schema.json`
  - `docs/schemas/session-index-v2-disposition-summary-v1.schema.json`
  - `docs/schemas/session-index-v2-cutover-readiness-v1.schema.json`
  - `docs/schemas/session-index-v2-promotion-decision-v1.schema.json`
- While burn-in is active, failures are **non-blocking** but include warnings and triage details in the step summary.

## Enforce toggle

The workflow uses repository variable:

- `SESSION_INDEX_V2_CONTRACT_ENFORCE`
  - `false` (default): burn-in mode, non-blocking.
  - `true`: enforce mode, failing contract blocks the job.

## Promotion procedure

1. Confirm `burnIn.promotionReady = true` in recent upstream artifacts.
2. Set repository variable `SESSION_INDEX_V2_CONTRACT_ENFORCE=true`.
3. Add `session-index-v2-contract` to `develop` required checks in
   `tools/policy/branch-required-checks.json` and branch protection settings.
4. Verify `session-index-v2-contract` appears in branch protection parity output and remains green.

## Promotion-decision front door

Use the helper when you need a single deterministic answer about the current promotion state:

```text
node tools/priority/session-index-v2-promotion-decision.mjs --repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

The report consumes the latest completed upstream `validate.yml` run for `develop`, downloads the
`validate-session-index-v2-contract` artifact bundle through the checked-in artifact helper, validates the contract
payloads, inspects `SESSION_INDEX_V2_CONTRACT_ENFORCE`, checks `tools/policy/branch-required-checks.json`, and projects
live branch-protection parity when that query is available.

Bootstrap also projects the latest promotion decision into the standing issue bundle:

- `tests/results/_agent/issue/session-index-v2-promotion-decision.json`
- `tests/results/_agent/issue/session-index-v2-promotion-decision-download.json`

That keeps the promotion state in the same repo-owned reporting surface future agents already review during first
actions, instead of requiring a bespoke one-off helper invocation every time.

## Local Docker replay lane

Use the Docker replay lane when you need to re-run the promotion decision against a known Validate artifact bundle with
Linux container semantics before paying for another hosted rerun:

```text
node tools/npm/run-script.mjs priority:workflow:replay:docker -- --mode session-index-v2-promotion --run-id 23543808174 --repo LabVIEW-Community-CI-CD/compare-vi-cli-action
```

The first slice is Linux-first and runs the checked-in promotion-decision helper inside the CompareVI tools image. It
writes its outer receipt under:

- `tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion-receipt.json`

And it forwards the inner replay artifacts under:

- `tests/results/docker-tools-parity/workflow-replay/session-index-v2-promotion/`

The replay lane fails closed on missing GitHub token, missing Docker image, or failing in-container helper execution.
Use it as the local proving surface for issue-class defects like `#1956`, then treat hosted Validate as the
confirmation/publication pass after the local replay is understood.

## Triage runbook

When `session-index-v2-contract` reports failures:

1. Open the artifact `validate-session-index-v2-contract/session-index-v2-disposition.json`.
2. Read `disposition`, `mismatchClass`, and `recurrenceClassification` first.
3. Then inspect `validate-session-index-v2-contract/session-index-v2-contract.json` for the full `burnInReceipt` and
   `failures[]` detail.
4. For schema failures, validate and inspect `session-index-v2.json` payload generation.
5. For parity failures, compare `branchProtection.expected` against
   `tools/policy/branch-required-checks.json` and live branch protection output.
6. Use `session-index-v2-cutover-readiness.json` to confirm the regression guard and deprecation checklist state before
   planning v1 removal.
7. Re-run Validate and confirm burn-in counter progression resumes.
