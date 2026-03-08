# Summary

Describe the workflow, policy, or governance outcome and the operator-facing reason for the change.

## Agent Metadata (required for automation-authored PRs)

- Agent-ID: `agent/copilot-codex-a`
- Operator: `@svelderrainruiz`
- Reviewer-Required: `@svelderrainruiz`
- Emergency-Bypass-Label: `AllowCIBypass`

## Workflow and Policy Impact

- Workflows, jobs, or tasks touched:
- Check names, required-status contracts, or merge-queue behavior affected:
- Permissions, rulesets, labels, reviewer routing, or approval surfaces changed:
- Manual dispatch, comment command, or branch-protection effects:

## Validation Evidence

- Commands run:
  - `./bin/actionlint -color`
- Contract, schema, or guard tests:
  - `node --test ...`
- Live workflow or dry-run evidence:
  - `tests/results/...`

## Rollout and Rollback

- Rollout notes:
- Rollback path:
- Residual risks:

## Reviewer Focus

- Please verify:
- Policy assumptions to double-check:
- Follow-up issues or guardrails:
