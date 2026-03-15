# Mission Control Trigger Profiles

This document explains how future operators and agents should consume the checked-in mission-control trigger surface
without relying on chat history or inferred shorthand.

Authoritative sources:

- canonical autonomy prompt: `PROMPT_AUTONOMY.md`
- profile catalog example: `tools/priority/__fixtures__/mission-control/profile-catalog.json`
- profile resolution example: `tools/priority/__fixtures__/mission-control/profile-resolution.json`
- operator input catalog example: `tools/priority/__fixtures__/mission-control/operator-input-catalog.json`
- authoritative profile loader: `tools/priority/lib/mission-control-profile-catalog.mjs`
- profile resolution report schema: `docs/schemas/mission-control-profile-resolution-v1.schema.json`
- preset envelope renderer: `tools/priority/render-mission-control-envelope.mjs`
- prompt renderer: `tools/priority/render-mission-control-prompt.mjs`
- runtime trigger resolver: `tools/priority/resolve-mission-control-profile.mjs`

## Consumption Order

Use the mission-control surfaces in this order:

1. Resolve the trigger token through `tools/priority/resolve-mission-control-profile.mjs`.
   - when current-head automation expects a specific canonical profile id, pass `--profile <id>` so contradictory
     trigger/profile selections fail closed in the report instead of surfacing only as console text
2. Treat the resolver output and `tools/priority/lib/mission-control-profile-catalog.mjs` as the authoritative
   profile-mapping path instead of reading raw fixture data directly.
3. Render the machine-readable preset envelope through `tools/priority/render-mission-control-envelope.mjs`.
4. Verify the resolved operator preset remains legal against `operator-input-catalog.json`.
5. When an operator-facing prompt artifact is needed, render it through
   `tools/priority/render-mission-control-prompt.mjs` instead of assembling it by hand.

Do not guess trigger meanings from informal shorthand. If a token is not present in the checked-in profile catalog or
aliases, it is not part of the repo contract.

## Supported Trigger Profiles

The checked-in profile catalog currently supports these canonical triggers:

- `MC`
  - profile: `autonomous-default`
  - operator preset: `continue-driving-autonomously` + `standing-priority`
  - aliases: `MC-AUTO`, `MC-DEFAULT`
  - use when the repo-owned control plane should keep the standing lane moving and rotate to the next concrete child
    issue
- `MC-LIVE`
  - profile: `finish-live-lane`
  - operator preset: `finish-live-standing-lane` + `standing-priority`
  - aliases: `MC-FINISH`
  - use when the current standing PR should land before parked-lane expansion continues
- `MC-RED`
  - profile: `stabilize-current-head-failure`
  - operator preset: `stabilize-current-head-failure` + `current-head-failure`
  - aliases: `MC-STABILIZE`, `MC-HEAD`
  - use when the live-lane regression is the only immediate objective
- `MC-INTAKE`
  - profile: `restore-intake`
  - operator preset: `restore-intake` + `queue-health`
  - aliases: `MC-QUEUE`
  - use when standing priority is missing or only epics remain open
- `MC-PARK`
  - profile: `prepare-parked-lane`
  - operator preset: `prepare-parked-lane` + `queue-health`
  - aliases: `MC-NEXT`, `MC-PARKED`
  - use when the live lane is waiting on GitHub only and one disjoint parked lane should be prepared

## Unsupported or Ambiguous Shorthand

The repo contract does not currently define every possible shorthand token. Examples:

- `MC-STRICT`
  - status: not present in the checked-in profile catalog
  - required behavior: fail closed
  - if strict behavior is needed, track it as a new child issue under the mission-control epic and add it to the
    checked-in catalog first
- any token not listed in `profile-catalog.json` or its `aliases` arrays
  - status: not part of the current repo contract
  - required behavior: fail closed and resolve through a checked-in profile instead of inventing behavior

## Operator Field Presets

The operator input catalog bounds what each profile may request.

### Intents

- `continue-driving-autonomously`
  - summary: keep the standing lane moving without waiting for a new operator prompt
  - allowed focuses: `standing-priority`, `queue-health`, `policy-drift`, `docs-contract`
- `finish-live-standing-lane`
  - summary: bias execution toward the current live lane
  - allowed focuses: `standing-priority`, `current-head-failure`, `queue-health`
- `stabilize-current-head-failure`
  - summary: treat the current-head regression as the only immediate objective
  - allowed focuses: `current-head-failure`, `policy-drift`
- `restore-intake`
  - summary: rebuild queue intake before implementation work resumes
  - allowed focuses: `queue-health`, `policy-drift`, `handoff`
- `prepare-parked-lane`
  - summary: use live-lane wait time to cut one disjoint follow-up slice
  - allowed focuses: `docs-contract`, `queue-health`, `standing-priority`

### Focuses

| Focus | Standing priority required | Use |
| --- | --- | --- |
| `standing-priority` | yes | Drive the current standing issue to merge. |
| `current-head-failure` | yes | Fix the current-head regression before widening scope. |
| `queue-health` | no | Restore intake, keep the queue populated, and prepare parked lanes. |
| `handoff` | no | Refresh machine-readable handoff state and continuity artifacts. |
| `policy-drift` | no | Correct contradictions between checked-in law and runtime behavior before feature work widens. |
| `docs-contract` | no | Tighten mission-control documentation and schema contract surfaces. |

### Overrides

Overrides are narrow, auditable exceptions. They do not widen the repo law.

- `allowAdminMerge`
  - value type: boolean
  - meaning: temporary admin-merge exception when a queue/bootstrap edge case blocks the normal path
- `allowForkBaseDispatch`
  - value type: boolean
  - meaning: temporary exception for fork-base workflow dispatch
- `allowParkedLane`
  - value type: boolean
  - meaning: enables or suppresses the single parked lane without changing the hard lane cap
- `copilotCliUsage`
  - value type: enum (`optional`, `required`)
  - meaning: tightens local Copilot CLI use without replacing required hosted checks
- `requireProjectBoardApply`
  - value type: boolean
  - meaning: requires project-board apply and reporting before the lane is considered complete

## Practical Resolution Examples

- `MC`
  - resolves to `autonomous-default`
  - applies `continue-driving-autonomously` + `standing-priority`
  - uses no overrides
- `MC-QUEUE`
  - resolves through the `restore-intake` alias set
  - applies `restore-intake` + `queue-health`
  - keeps overrides empty unless the operator explicitly supplies an allowed override
- `node tools/priority/resolve-mission-control-profile.mjs --trigger MC-PARKED --profile prepare-parked-lane`
  - resolves through the `prepare-parked-lane` alias set
  - writes a machine-readable report under `tests/results/_agent/mission-control/`
  - fails closed if the canonical profile id does not match the trigger
- `MC-STRICT`
  - does not resolve
  - must fail closed instead of guessing at a stricter form of `MC`

## Guardrail

Keep the documentation aligned with the checked-in catalogs. If the runtime catalog changes, update this page in the
same slice so operators are never forced to infer intent from stale prose.
