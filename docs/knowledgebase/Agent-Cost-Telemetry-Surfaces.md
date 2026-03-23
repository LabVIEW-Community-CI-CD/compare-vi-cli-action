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
- helper: `tools/priority/pr-spend-projection.mjs`
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

## Durable GitHub Comment Budget Hook

Automation-authored GitHub comments now have a checked-in budget attestation
surface so cost state survives session compaction and comment history remains a
durable breadcrumb for later agents.

- schema: `docs/schemas/github-comment-budget-hook-policy-v1.schema.json`
- schema: `docs/schemas/github-comment-budget-hook-report-v1.schema.json`
- policy: `tools/policy/github-comment-budget-hook.json`
- helper: `tools/priority/github-comment-budget-hook.mjs`
- npm surface: `priority:cost:comment-hook`
- wrappers:
  - `tools/Post-IssueComment.ps1`
  - `tools/Post-PullRequestComment.ps1`

The hook appends a machine-readable and human-readable budget block to GitHub
comments with these markers:

- `<!-- priority:github-comment-budget-hook:start -->`
- `<!-- priority:github-comment-budget-hook:end -->`

The hook projects:

- token spend
- observed operator-equivalent labor
- observed blended lower-bound spend
- operator budget cap / remaining lower bound
- operational invoice-turn remainder
- reserved calibration funding window state
- live/background/total turn counts

The checked-in policy keeps the calibration window reserved instead of silently
consuming it. The current intent is:

- operational invoice turn may spend
- calibration invoice turn remains on hold

Use the wrappers by default so GitHub issue and PR comments pick up the durable
budget hook automatically. Pass `-SkipBudgetHook` only for narrow test or
break-glass cases where the attestation must be suppressed deliberately.
Instead, it normalizes a local private metadata JSON payload into a checked-in
invoice-turn contract. That keeps raw invoice documents out of the repository
while still reducing manual transcription drift.

The checked-in fixture must never embed the private invoice path. Local receipts
may carry that path under operator control for later reconciliation.

## PR Spend Projection

`#1679` adds a stakeholder-facing PR projection surface on top of the rollup.
This remains a projection layer, not a second billing system.

- schema: `docs/schemas/pr-spend-projection-v1.schema.json`
- helper: `tools/priority/pr-spend-projection.mjs`
- outputs:
  - `tests/results/_agent/cost/pr-spend-projection.json`
  - `tests/results/_agent/cost/pr-spend-projection.md`
- wrapper:
  - `node tools/npm/run-script.mjs priority:cost:pr-spend -- --pr <number> --repo <owner/repo>`

Behavior:

- consumes the existing rollup at `tests/results/_agent/cost/agent-cost-rollup.json`
- preserves rollup billing-truth provenance:
  - `estimated-only`
  - `mixed`
  - `exact-only`
- summarizes spend by:
  - live versus background agent
  - provider
  - model
  - issue
  - lane
- can optionally upsert a PR comment for stakeholder visibility

This surface must always remain honest about intermediate state. It may show
heuristic USD while calibration is still in progress, but it must not claim
final reconciled billing truth unless the underlying rollup carries that
evidence.

## Operator Labor And Blended Autonomy Cost

`#1872` extends the spend layer so active agent runtime is priced as operator-
equivalent labor in addition to token spend:

- schema: `docs/schemas/operator-cost-profile-v1.schema.json`
- policy: `tools/policy/operator-cost-profile.json`
- turn helper: `tools/priority/agent-cost-turn.mjs`
- rollup helper: `tools/priority/agent-cost-rollup.mjs`
- projection helper: `tools/priority/pr-spend-projection.mjs`
- benchmark helper: `tools/priority/average-issue-cost-scorecard.mjs`
- wake pricing helper: `tools/priority/wake-investment-accounting.mjs`

The checked-in default operator profile currently sets:

- `operator.id = sergio`
- `operator.displayName = Sergio Velderrain Ruiz`
- `laborRateUsdPerHour = 250`
- `pricingBasis = agent-runtime-hour`

This means active agent runtime is additive across the system:

- one agent running for one hour = `$250` operator labor before token cost
- two agents running for one hour each = `$500` operator labor before token cost
- total autonomy cost = `operatorLaborUsd + tokenCostUsd`

The per-turn receipt now records:

- `runtime.startedAt`
- `runtime.endedAt`
- `runtime.elapsedSeconds`
- `runtime.elapsedSource`
- `labor.operatorProfilePath`
- `labor.operatorId`
- `labor.operatorName`
- `labor.laborRateUsdPerHour`
- `labor.amountUsd`
- `labor.blendedTotalUsd`

Blended reporting is intentionally honest about missing evidence:

- if elapsed timing is missing, labor stays unset instead of being invented
- if labor is known and token spend is known, `blendedTotalUsd` is emitted
- if labor is partially missing, PR projections and issue averages keep the
  token total visible and mark the labor status as partial or missing

Use this model when discussing autonomous economics:

- `token` cost alone is incomplete
- `operator labor` alone is incomplete
- `blended autonomy cost` is the decision surface for future capital routing

## Average Issue Cost Over Time

`#1708` adds a first machine-readable average issue cost scorecard that stays on
top of the existing rollup and invoice-turn receipts instead of creating a
second spend system.

- schema: `docs/schemas/average-issue-cost-scorecard-v1.schema.json`
- helper: `tools/priority/average-issue-cost-scorecard.mjs`
- output:
  - `tests/results/_agent/capital/average-issue-cost-scorecard.json`

Behavior:

- consumes the existing rollup at `tests/results/_agent/cost/agent-cost-rollup.json`
- ties spend attribution to invoice turns and funding windows
- emits a time-ordered funding-window series with:
  - per-window `averageUsdPerIssue`
  - cumulative `rollingAverageUsdPerIssue`
  - cumulative `rollingAverageBlendedUsdPerIssue`
- separates observed spend into:
  - `liveAgentUsd`
  - `backgroundAgentUsd`
  - `hostedValidationUsd` when the turn is explicitly hosted-plane
  - `operatorLaborUsd`
- reports current issue-state buckets:
  - `open`
  - `closed-completed`
  - `blocked-external`
  - `unknown`
- preserves per-issue provenance:
  - turn ids
  - source receipt/report paths
  - invoice-turn ids
  - assignment strategies

When labor timing is available, the scorecard also reports:

- `blendedTotalUsd`
- `rollingAverageBlendedUsdPerIssue`
- `currentActiveWindowAverageBlendedUsdPerIssue`
- `latestTrailingOperationalWindowAverageBlendedUsdPerIssue`

This first slice is intentionally honest about issue state. It applies the
current hydrated issue state to observed spend windows, which is enough to
benchmark present averages but not enough to prove historical state transitions
inside older windows.

## Sticky Calibration Funding-Window Mode

`#1657` extends the invoice-turn contract with an explicit selection record so
calibration windows can stay pinned while calibration remains active:

- `selection.mode = hold` is the default before calibration activation
- `selection.mode = sticky-calibration` pins the calibration invoice turn for
  continued auto-selection
- `selection.mode = ended` marks the calibration window as explicitly closed
- `selection.calibrationWindowId` records the pinned invoice-turn identifier
- `selection.reason` explains why the window remained selected

The roll-up surface copies that selection state into both:

- `summary.provenance.invoiceTurn.selection`
- `billingWindow.selection`

Use the invoice-turn helper with:

- `--selection-mode hold`
- `--selection-mode sticky-calibration --selection-reason <text>`
- `--calibration-window-id <invoice-turn-id>` when the pinned window id needs to
  be spelled out explicitly

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

## Operator Steering Attribution

`#1656` extends the turn and rollup contracts so operator steering can be
measured immediately, even while the spend layer is still partially heuristic.

At the turn level:

- `docs/schemas/agent-cost-turn-v1.schema.json`
- `tools/priority/agent-cost-turn.mjs`

Each turn now carries a required `steering` object with:

- `operatorIntervened`
- `kind`
- `source`
- `observedAt`
- `note`
- `invoiceTurnId`

This keeps steering attributable by:

- turn
- lane
- repository
- invoice turn when known

At the rollup level:

- `docs/schemas/agent-cost-rollup-v1.schema.json`
- `tools/priority/agent-cost-rollup.mjs`

Rollups now expose:

- `summary.metrics.steeredTurnCount`
- `summary.metrics.unsteeredTurnCount`
- `summary.metrics.steeredUsd`
- `summary.metrics.unsteeredUsd`
- `summary.provenance.steeringKinds`
- `summary.provenance.steeringSources`
- `breakdown.bySteering`

Use these fields to compare:

- heuristic versus actual spend
- calibration versus operational funding windows
- steered versus unsteered calibration runs

That gives future agents a clean path to judge whether a cost or quality change
came from the model, the operator, or a mixed session instead of blending those
factors into one opaque number.

## Follow-Up Seams To Keep Separate

- separate rate-card contract/schema
- projection of cost summaries into delivery-agent runtime state
- provider-specific exact billing reconciliation
- any future Codex-native exact usage ingestion

Those should stay follow-up lanes. The first slice should stay anchored to
existing repo-visible receipts.

Also keep these boundaries explicit:

- the operator labor profile is checked-in policy, not hidden memory
- labor math should price active agent runtime, not passive external waits
- background daemon continuity should reduce active operator-equivalent burn,
  not hide it

## Account-Backed Calibration Evidence

`#1671` extends the roll-up layer so it can consume optional normalized account
evidence without replacing invoice turns:

- usage-export receipts under `tests/results/_agent/cost/usage-exports/`
- account-balance receipts under `tests/results/_agent/cost/account-balances/`

The roll-up now accepts:

- `--usage-export <path>`
- `--account-balance <path>`

When those flags are omitted, the roll-up auto-discovers JSON receipts from the
default directories above. Valid receipts are summarized into:

- `summary.metrics.usageExportWindowCount`
- `summary.metrics.usageExportCreditsReported`
- `summary.metrics.usageExportQuantityReported`
- `summary.metrics.accountBalanceTotalCredits`
- `summary.metrics.accountBalanceUsedCredits`
- `summary.metrics.accountBalanceRemainingCredits`
- `summary.provenance.usageExports`
- `summary.provenance.accountBalance`

This keeps the calibration layer honest:

- invoice turns still define the selected funding window
- usage exports provide account-window usage evidence
- account balance snapshots provide current-plan total/used/remaining evidence

These evidence receipts are optional. Missing directories do not fail the roll-
up, but unreadable or schema-mismatched receipts do surface as blockers once
they are present.
