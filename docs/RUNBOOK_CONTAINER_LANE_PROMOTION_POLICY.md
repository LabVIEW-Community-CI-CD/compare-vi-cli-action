# Runbook Container Lane Promotion Policy

This policy defines promotion and rollback rules for the non-blocking container canary lane introduced by #662.

## Scope and ownership

- Parent epic: #664
- Decision issue: #663
- Requirements contract linkage: #665 (R2, R3, R4, R5)
- Evidence source: #662 canary telemetry and runbook-validation artifacts

## Measured canary evidence baseline

Evidence from #662 burn-in shows the minimum evidence window is satisfied:

- Consecutive successful upstream canary runs: **5**
- Run IDs: `22689025270`, `22689058333`, `22688974313`, `22689088312`, `22689157078`
- Host job outcome across window: success (all runs)
- Container canary outcome across window: success (all runs)
- Windows lane lifecycle: `success`
- Windows stop class: `completed`
- Host duration range: `0.30s` to `0.33s`
- Container duration range: `2.89s` to `3.23s`

## Failure taxonomy

Classify canary failures into one of the following classes before promotion decisions:

1. `infra-transient`
   - Examples: runner loss, Docker pull/network throttling, GitHub-hosted API jitter.
   - Action: rerun once; do not change required-check policy on a single event.
2. `infra-persistent`
   - Examples: repeated engine startup failures, image pull/auth failures across >=2 runs.
   - Action: keep lane non-required, open stabilization issue, assign infra owner.
3. `deterministic-script-defect`
   - Examples: reproducible script regression in `tools/Test-DockerDesktopFastLoop.ps1` or runbook workflow logic.
   - Action: block promotion; fix defect first.
4. `policy-contract-defect`
   - Examples: required-check naming drift, unsatisfied branch-protection contract, merge blocking due contract mismatch.
   - Action: rollback required-check changes immediately, restore contract parity, then re-evaluate.

## Promotion decision matrix

| Condition | Outcome | Required-check impact |
| --- | --- | --- |
| >=5 consecutive canary successes, no deterministic defects, branch-protection satisfiable on develop | Promote candidate approved | May add promoted lane/check only after policy-contract update and satisfiability proof |
| Mixed results with only `infra-transient` events and no deterministic defects | Stay canary | No required-check changes |
| Any `infra-persistent` or `deterministic-script-defect` in evidence window | Hold / rollback to canary-only | No new required checks; open remediation issue |
| Any `policy-contract-defect` detected after promotion | Immediate rollback | Remove promoted required context and restore prior required-check set |

## Promotion safety proof (required before any required-check change)

Promotion cannot proceed unless all steps pass on current `develop` head:

1. Confirm develop required-check contract currently matches `tools/policy/branch-required-checks.json`.
2. Validate the proposed required-check set remains satisfiable on current `develop` head.
3. Run policy drift validation (`priority:policy`) and branch-protection verification.
4. Attach proof output (command logs + resulting required contexts) to the promotion PR and issue #663.

## Rollback procedure

If a promoted lane/check causes merge-blocking or policy drift:

1. Revert required-check mapping to the last known-good set in `tools/policy/branch-required-checks.json`.
2. Apply branch-protection parity update so GitHub required contexts match the reverted contract.
3. Re-run policy verification and confirm `develop` is merge-satisfiable.
4. Post rollback evidence with timestamp, failing context, and restored context set.

### Documented rollback drill result

Rollback behavior was validated against the canary state for #662/#663:

- Canary lane remains non-required during this policy phase.
- Current develop required-check contract remains satisfiable with no runbook-container context required.
- Expected branch-protection behavior after rollback: merges continue using canonical required contexts (`lint`,
  `fixtures`, `session-index`, `issue-snapshot`, `semver`, `Policy Guard (Upstream) / policy-guard`,
  `vi-history-scenarios-linux`, `agent-review-policy`, `commit-integrity`).

## Decision for #663

- Current status: **keep runbook container lane as non-required canary**.
- Rationale: evidence window is healthy, but promotion remains deferred until an explicit required-check naming update
  is proven satisfiable end-to-end and accepted in policy review.
