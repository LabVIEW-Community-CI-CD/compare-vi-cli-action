# Validation Approval Apply-Mode Proof

`validation` is the only environment in scope for the approval broker/apply path.
`production`, release, and publish environments stay out of scope.

## Proof command

Run the historical replay against recent real `validation` deployments:

```bash
node tools/npm/run-script.mjs priority:validation:proof -- \
  --repo LabVIEW-Community-CI-CD/compare-vi-cli-action \
  --max-deployments 8 \
  --min-samples 4 \
  --lookback-days 7
```

The report lands at
`tests/results/_agent/approvals/validation-approval-proof.json` and stages
per-sample replay artifacts under `tests/results/_agent/approvals/proof/`.

## Graduation rule

Apply mode may be enabled for `validation` only when the proof report shows:

- `falseReadyCount = 0`
- `samplesEvaluated >= minSamples`
- `errorCount = 0`

Historical replay is intentionally conservative. The derived replay attestation
never invents dispositions for unresolved/actionable Copilot comments. If a
historical PR still presents stale or actionable review state, the broker must
block and the sample is recorded as a conservative `false-blocked` outcome
rather than a `false-ready` outcome.
