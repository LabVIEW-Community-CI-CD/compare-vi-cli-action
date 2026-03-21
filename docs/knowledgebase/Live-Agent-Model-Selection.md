# Live-Agent Model Selection

This repo keeps live-agent model selection recommendation-first through the
release-candidate phase.

The selector turns repo-visible telemetry into an explainable report instead of
switching models implicitly inside the daemon.

## Inputs

- `tests/results/_agent/cost/agent-cost-rollup.json`
- `tests/results/_agent/throughput/throughput-scorecard.json`
- `tests/results/_agent/runtime/delivery-memory.json`
- `tools/policy/live-agent-model-selection.json`
- `tools/priority/delivery-agent.policy.json`

## Output

- `tests/results/_agent/runtime/live-agent-model-selection.json`

The report records, per provider:

- current model
- current reasoning-effort tier
- selected model
- selected reasoning-effort tier
- action
- confidence
- exact reason codes
- supporting telemetry evidence
- blockers when the evidence window is not met

## Runtime Projection

The current recommendation is projected into:

- `docs/schemas/runtime-delivery-task-packet-v1.schema.json`
- `docs/schemas/delivery-agent-runtime-state-v1.schema.json`

Concrete receipts:

- `tests/results/_agent/runtime/delivery-agent-state.json`
- `tests/results/_agent/runtime/live-agent-model-selection.json`

That keeps the recommendation visible to future agents without changing the
current unattended delivery behavior.

## RC Rules

- default mode is `recommend-only`
- `enforce` may exist in policy, but it stays disabled through RC
- cost alone is not enough to switch
- reasoning effort is part of model identity for recommendation purposes
- queue pressure, throughput pressure, and outcome pressure can justify a
  stronger recommendation
- hysteresis and cooldowns prevent model thrash

## Entry Point

- `node tools/npm/run-script.mjs priority:model:select`

## Related Contracts

- `docs/schemas/live-agent-model-selection-policy-v1.schema.json`
- `docs/schemas/live-agent-model-selection-report-v1.schema.json`
- `docs/schemas/agent-cost-rollup-v1.schema.json`
- `docs/schemas/delivery-agent-runtime-state-v1.schema.json`
- `docs/schemas/runtime-delivery-task-packet-v1.schema.json`
