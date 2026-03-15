# Mission Control Lifecycle

This document describes the authoritative mission-control flow for `compare-vi-cli-action`.
It is a discovery and sequencing aid, not a second policy source. The checked-in schemas, fixtures,
CLIs, `AGENTS.md`, and [PROMPT_AUTONOMY.md](../PROMPT_AUTONOMY.md) remain authoritative.

## Lifecycle

1. Define the policy envelope.
   - Schema: `docs/schemas/mission-control-envelope-v1.schema.json`
   - Fixture / seed: `tools/priority/__fixtures__/mission-control/mission-control-envelope.json`
   - Renderer: `tools/priority/render-mission-control-envelope.mjs`

2. Validate the bounded operator input.
   - Catalog schema: `docs/schemas/mission-control-operator-input-catalog-v1.schema.json`
   - Catalog fixture: `tools/priority/__fixtures__/mission-control/operator-input-catalog.json`
   - Validator: `tools/priority/validate-mission-control-operator-input.mjs`
   - Rule: do not treat free-form operator text as a policy surface.

3. Resolve the mission-control profile or trigger.
   - Catalog schema: `docs/schemas/mission-control-profile-catalog-v1.schema.json`
   - Resolution schema: `docs/schemas/mission-control-profile-resolution-v1.schema.json`
   - Catalog fixture: `tools/priority/__fixtures__/mission-control/profile-catalog.json`
   - Resolution fixture: `tools/priority/__fixtures__/mission-control/profile-resolution.json`
   - Resolver: `tools/priority/resolve-mission-control-profile.mjs`

4. Render the operator prompt from checked-in policy.
   - Prompt renderer: `tools/priority/render-mission-control-prompt.mjs`
   - Canonical prompt source: [PROMPT_AUTONOMY.md](../PROMPT_AUTONOMY.md)
   - Contract: prompt/report outputs live under `tests/results/_agent/mission-control/`
   - Contract: envelope inputs must stay inside the repository root

5. Validate the rendered prompt before consumption.
   - Prompt validator: `tools/priority/validate-mission-control-prompt.mjs`
   - Contract: embedded prompt and envelope paths are trusted only when they satisfy the same repo/artifact-root guards
   - Contract: validation reports also stay under `tests/results/_agent/mission-control/`

6. Consume the validated mission-control artifacts.
   - Consumption runbook: [MISSION_CONTROL_CONSUMPTION.md](./MISSION_CONTROL_CONSUMPTION.md)
   - Trigger presets: [MISSION_CONTROL_TRIGGER_PROFILES.md](./MISSION_CONTROL_TRIGGER_PROFILES.md)
   - Authoritative repo policy remains in `AGENTS.md`, `.github/copilot-instructions.md`, and `.github/instructions/`

## Guardrails

- `AGENTS.md` remains authoritative for standing-priority execution.
- `.github/copilot-instructions.md` remains authoritative for local Copilot review behavior.
- The lifecycle document should point back to checked-in schemas, fixtures, and CLIs instead of duplicating policy.
- Operator convenience text is input data, not a policy surface.
