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
