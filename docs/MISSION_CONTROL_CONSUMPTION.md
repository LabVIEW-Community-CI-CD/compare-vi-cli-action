# Mission Control Consumption

This document defines how future agents and operator tooling should discover, resolve, and apply mission control in
`compare-vi-cli-action` without widening repository law.

## Discovery Order

1. Start with [PROMPT_AUTONOMY.md](../PROMPT_AUTONOMY.md) for the canonical operator-facing mission-control charter.
2. Treat [mission-control-envelope-v1.schema.json](schemas/mission-control-envelope-v1.schema.json) and the checked-in
   [mission-control envelope fixture](../tools/priority/__fixtures__/mission-control/mission-control-envelope.json) as
   the machine-readable source of mission-control-specific policy.
3. Use [mission-control-operator-input-catalog-v1.schema.json](schemas/mission-control-operator-input-catalog-v1.schema.json)
   and the checked-in
   [operator-input catalog fixture](../tools/priority/__fixtures__/mission-control/operator-input-catalog.json) to bound
   `operator.intent`, `operator.focus`, and `operator.overrides`.
4. Use [mission-control-profile-catalog-v1.schema.json](schemas/mission-control-profile-catalog-v1.schema.json), the
   checked-in [profile catalog fixture](../tools/priority/__fixtures__/mission-control/profile-catalog.json), and the
   authoritative loader [mission-control-profile-catalog.mjs](../tools/priority/lib/mission-control-profile-catalog.mjs)
   when resolving preset trigger tokens.
5. Resolve trigger tokens with
   [resolve-mission-control-profile.mjs](../tools/priority/resolve-mission-control-profile.mjs) before choosing a preset
   by hand.
6. Render a machine-readable preset envelope with
   [render-mission-control-envelope.mjs](../tools/priority/render-mission-control-envelope.mjs) instead of copying
   operator fields into ad hoc prompt text.

## Consumption Flow

1. Read `PROMPT_AUTONOMY.md` to understand the standing-priority control loop, lane law, anti-idle rules, and stop
   conditions.
2. Resolve the requested trigger or alias through the checked-in profile catalog.
3. Render the mission-control envelope from the resolved preset.
4. Treat `missionControl` as mission-control-specific repo policy and `operator` as bounded operator input layered on top
   of that policy.
5. Start from the proactive four-lane posture when safe actionable work exists; do not wait for a later operator
   prompt to fill capacity that is already available.
6. Preserve the broader instruction-precedence contract:
   - `AGENTS.md` remains authoritative for repository-wide automation law.
   - `.github/copilot-instructions.md` remains authoritative for the local Copilot review plane.
   - phase overlays under `.github/instructions/` still control draft-review vs ready-validation behavior.
7. Keep downstream automation fail-closed when operator input conflicts with the envelope contract, the operator input
   catalog, the profile catalog, or the repository-wide instruction surfaces above.
8. Audit actual lane utilization through the checked-in and emitted receipts:
   - checked-in worker-slot target: `tools/priority/delivery-agent.policy.json`
   - current slot occupancy and released waits: `tests/results/_agent/runtime/delivery-agent-state.json`
   - utilization and queue pressure summary: `tests/results/_agent/throughput/throughput-scorecard.json`

## Guardrails

- Do not treat free-form operator text as a policy surface.
- Do not bypass the checked-in schemas, fixtures, or authoritative loader/resolver helpers.
- Do not widen lane counts, merge authority, or raw-package-manager policy outside the checked-in delivery-agent policy
  and mission-control envelope contract.
- Keep future mission-control helpers deterministic and machine-readable so local review and standing-priority receipts
  remain attributable.
