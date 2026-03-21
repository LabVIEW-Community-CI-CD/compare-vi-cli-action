<!-- markdownlint-disable-next-line MD041 -->
# Agent Cost Telemetry Surfaces

This note documents the best existing checked-in and repo-visible surfaces that
can feed `#1639` cost telemetry without relying on hidden billing APIs or local
operator memory.

The goal here is evidence gathering, not a billing rewrite. Use these surfaces
to ground the first cost-telemetry slice in data the repository already emits.

## Best Existing Per-Turn Surface

The strongest current per-turn precursor is the local collaboration ledger:

- code: `tools/local-collab/ledger/local-review-ledger.mjs`
- schemas:
  - `comparevi/local-collab-ledger-receipt@v1`
  - `comparevi/local-collab-ledger-latest@v1`
- emitted receipts:
  - `tests/results/_agent/local-collab/ledger/receipts/<phase>/<head-sha>.json`
  - `tests/results/_agent/local-collab/ledger/latest/<phase>.json`

The ledger already records the fields most useful for cost attribution:

- `forkPlane`
- `persona`
- `executionPlane`
- `providerRuntime`
- `providerId`
- `requestedModel`
- `effectiveModel`
- provider/runtime effort metadata when the source receipt captures it
- `inputTokens`
- `cachedInputTokens`
- `outputTokens`
- `durationMs`
- `status`
- `outcome`
- `sourcePaths`
- `sourceReceiptIds`

That makes the ledger the best first source for per-turn cost receipts, because
it is already:

- machine-readable
- phase-aware
- plane-aware
- provider-aware
- token-aware
- linked back to source receipts

## Best Existing Provider/Model Provenance Surface

For local review providers, the best provenance source is the Copilot CLI review
receipt:

- code: `tools/local-collab/providers/copilot-cli-review.mjs`
- tests: `tools/priority/__tests__/copilot-cli-review.test.mjs`
- example receipt paths:
  - `tests/results/_hooks/pre-commit-copilot-cli-review.json`
  - `tests/results/_hooks/pre-push-copilot-cli-review.json`
  - `tests/results/docker-tools-parity/copilot-cli-review/receipt.json`

This receipt already captures:

- actual executed `copilot.model`
- `permissionPolicy`
- `sessionPolicy`
- pass-level outcomes and convergence
- actionable finding counts
- selected files / diff scope

Use this receipt as provider/model/session provenance for ledger-backed cost
estimates. Do not make up provider metadata when this receipt is present.

## Best Existing Lane And Issue Attribution Surfaces

To tie cost to delivery context, use the runtime task packet and runtime state:

- schema: `docs/schemas/runtime-delivery-task-packet-v1.schema.json`
- schema: `docs/schemas/delivery-agent-runtime-state-v1.schema.json`
- code: `tools/priority/delivery-agent.mjs`
- emitted receipt:
  - `tests/results/_agent/runtime/delivery-agent-state.json`

These surfaces already provide:

- `laneId`
- selected issue / standing issue context
- `workerProviderSelection`
- `providerDispatch`
- `workerSlotId`
- `selectedExecutionPlane`
- `selectedAssignmentMode`
- `dispatchSurface`
- `completionMode`

This is the right path for correlating spend with:

- issue
- lane
- worker slot
- provider kind
- execution plane

These surfaces are not sufficient alone for cost telemetry because they do not
carry token counts.

## Best Existing Roll-Up Surface

The strongest current roll-up precursor is the local collaboration KPI summary:

- code: `tools/local-collab/kpi/rollup-local-collab-kpi.mjs`
- schema: `comparevi/local-collab-kpi-summary@v1`
- tests: `tools/local-collab/kpi/__tests__/rollup-local-collab-kpi.test.mjs`
- emitted receipt:
  - `tests/results/_agent/local-collab/kpi/summary.json`

The KPI summary already aggregates:

- `inputTokens`
- `cachedInputTokens`
- `outputTokens`
- `durationMs`
- planes
- personas
- providers
- requested/effective models

That makes it the best current roll-up base for:

- spend by provider
- spend by plane
- spend by persona
- spend by head

It does not yet emit dollars, rate-card provenance, or exact-versus-estimated
classification.

## Best Existing Correlation Surfaces

To correlate cost against throughput and delivered outcomes, use these checked-in
reports instead of inventing a separate shadow KPI:

- `tests/results/_agent/throughput/throughput-scorecard.json`
  - code: `tools/priority/throughput-scorecard.mjs`
  - schema: `docs/schemas/throughput-scorecard-v1.schema.json`
- `tests/results/_agent/runtime/delivery-memory.json`
  - schema: `docs/schemas/delivery-memory-v1.schema.json`

These provide the denominator side of the question:

- worker utilization
- queue occupancy
- concurrent-lane activity
- hosted wait escape count
- terminal PR counts
- effort levels and duration

They are the right correlation surfaces for executive reporting after cost data
exists. They are not the right source for model/token spend by themselves.

## Intent And Policy Surfaces, Not Billing Surfaces

Mission control is still useful, but only as declared intent:

- `docs/schemas/mission-control-envelope-v1.schema.json`
- `docs/schemas/mission-control-profile-resolution-v1.schema.json`
- `docs/MISSION_CONTROL_CONSUMPTION.md`

These surfaces can explain:

- configured lane counts
- preset operator intent
- expected utilization posture

They should not be treated as cost evidence, because they describe intended
behavior rather than actual per-turn execution.

## Visible Codex Metadata: Safe Use And Unsafe Use

The Codex hygiene report is useful only as visible session-volume evidence:

- schema: `docs/schemas/codex-state-hygiene-v1.schema.json`
- code: `tools/priority/codex-state-hygiene.mjs`
- emitted receipt:
  - `tests/results/_agent/runtime/codex-state-hygiene.json`

Safe uses:

- session file counts
- session byte growth
- stale-thread candidate counts
- extension-log health indicators

Unsafe uses:

- exact token billing
- inferred per-turn model spend
- dollar estimates from file size alone

Treat this report as auxiliary observability, not as a billing source of truth.

## Smallest Coherent Implementation Slice For #1639

The smallest defensible first implementation is:

1. define a new cost receipt schema that projects from ledger receipts
2. require explicit provenance fields:
   - `amountKind = exact | estimated`
   - `rateCardSource`
   - `usageSourceReceiptPath`
   - `providerModelSourceReceiptPath`
   - `requestedReasoningEffort`
   - `effectiveReasoningEffort`
3. generate estimates from:
   - local-collab ledger receipts
   - provider receipts such as Copilot CLI review receipts
   - runtime task packet / runtime state lane attribution
4. roll up cost by:
   - issue
   - lane
   - provider
   - repo
   - session
5. correlate the roll-up with:
   - `throughput-scorecard.json`
   - `delivery-memory.json`

## First Implemented Invoice-Turn Slice

`#1639` now has a checked-in first invoice-turn baseline surface:

- schema: `docs/schemas/agent-cost-invoice-turn-v1.schema.json`
- schema: `docs/schemas/agent-cost-turn-v1.schema.json`
- schema: `docs/schemas/agent-cost-rollup-v1.schema.json`
- helper: `tools/priority/agent-cost-invoice-turn.mjs`
- helper: `tools/priority/agent-cost-invoice-normalize.mjs`
- helper: `tools/priority/agent-cost-turn.mjs`
- helper: `tools/priority/agent-cost-rollup.mjs`
- sample fixtures:
  - `tools/priority/__fixtures__/agent-cost-rollup/live-turn-estimated.json`
  - `tools/priority/__fixtures__/agent-cost-rollup/background-turn-exact.json`
  - `tools/priority/__fixtures__/agent-cost-rollup/invoice-turn-baseline.json`
  - `tools/priority/__fixtures__/agent-cost-rollup/invoice-turn-next-baseline.json`
  - `tools/priority/__fixtures__/agent-cost-rollup/invoice-turn-baseline-reconciled.json`
  - `tools/priority/__fixtures__/agent-cost-rollup/private-invoice-metadata-sample.json`

This first slice intentionally separates:

- checked-in public example baseline
- local-only normalized invoice receipts that can carry private operator evidence

There is now a local-only normalization helper for private invoice metadata:

- schema: `docs/schemas/agent-cost-private-invoice-metadata-v1.schema.json`
- helper: `tools/priority/agent-cost-invoice-normalize.mjs`

This helper intentionally does not scrape PDFs directly in the stable slice.
Instead, it normalizes a local private metadata JSON payload into a checked-in
invoice-turn contract. That keeps raw invoice documents out of the repository
while still reducing manual transcription drift.

The checked-in fixture must never embed the private invoice path. Local receipts
may carry that path under operator control for later reconciliation.

Use the helpers like this:

- `node tools/priority/agent-cost-invoice-turn.mjs ...`
- `node tools/priority/agent-cost-invoice-normalize.mjs --metadata <path> ...`
- `node tools/priority/agent-cost-turn.mjs ...`
- `node tools/priority/agent-cost-rollup.mjs --turn-report <path> --invoice-turn <path>`
- `node tools/npm/run-script.mjs priority:cost:invoice-turn -- ...`
- `node tools/npm/run-script.mjs priority:cost:invoice-normalize -- --metadata <path> ...`
- `node tools/npm/run-script.mjs priority:cost:turn -- ...`
- `node tools/npm/run-script.mjs priority:cost:rollup -- ...`

The cost layer now supports overlapping invoice turns without deleting old
receipts:

- multiple invoice-turn receipts may coexist under
  `tests/results/_agent/cost/invoice-turns/`
- rollups can auto-discover invoice-turn receipts when `--invoice-turn` is
  omitted
- rollups can choose the active invoice turn deterministically from turn timing
  or accept an explicit `--invoice-turn-id`
- overlapping prepaid invoices are not treated as additive outcome; the rollup
  selects one active invoice window instead of turning `$400` plus `$500` on
  disk into a fake `$900` result
- invoice turns can be held out of auto-selection with
  `policy.activationState = hold`; this is the right way to park a one-time
  calibration funding window on disk without letting it displace the active
  operational invoice turn
- invoice-turn receipts may later carry actual observed USD or credits so the
  rollup can show heuristic drift directly instead of requiring manual
  spreadsheet comparison

This is the right first boundary because it gives future agents:

- a real accounting epoch (`invoice turn`)
- per-turn and rollup receipts with explicit provenance
- a stable place to record model reasoning-effort tiers such as `xhigh`
- a reconciliation point for the next operator-provided invoice
- a deterministic path from heuristic spend to actual observed USD

It is still not exact billing truth. Until provider exports are available, use
the invoice-turn baseline plus explicit `exact` versus `estimated` provenance to
keep the reporting honest.

## Follow-Up Seams To Keep Separate

- separate rate-card contract/schema
- projection of cost summaries into delivery-agent runtime state
- provider-specific exact billing reconciliation
- any future Codex-native exact usage ingestion

Those should stay follow-up lanes. The first slice should stay anchored to
existing repo-visible receipts.
