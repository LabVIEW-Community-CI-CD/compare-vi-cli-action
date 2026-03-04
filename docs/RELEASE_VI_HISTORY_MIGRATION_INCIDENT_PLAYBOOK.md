# Release VI History Migration Incident Playbook

This playbook defines incident response and rollback actions for Phase 8 migration enforcement failures.

## Incident Triggers

Open an incident when any of the following occur:

- unexpected release failure caused by migration enforcement selection,
- policy summary fields are missing or inconsistent (`tagClass`, `enforcementSource`, `enforcementMode`),
- stable tag behavior diverges from approved rollout policy,
- repeated RC proofs show unexplained `rawOutcome`/`outcome` mismatch.

## Severity Levels

- `SEV-1`: stable release blocked or incorrect stable promotion behavior.
- `SEV-2`: RC proof instability affecting confidence in rollout.
- `SEV-3`: metadata/reporting drift with no gate impact.

## First 15 Minutes

1. Capture run URL and failing job URL.
2. Download `release-vi-history-review-index` artifact.
3. Snapshot `release-vi-history-policy.json` and `release-vi-history-review.json`.
4. Record migration config from commit SHA used by the run.
5. Post a short incident update on PR/issue thread.

## Triage Checklist

- Confirm tag classification logic (`rc` vs `stable`) from `github.ref_name`.
- Confirm `enforcementSource` points to expected config node.
- Confirm `rawOutcome` aligns with policy violations in summary.
- Confirm effective `outcome` aligns with migration mode semantics.
- Confirm no malformed/legacy summary payload drift after normalization step.

## Immediate Mitigation Options

### Option A: Safe Revert to Hard

Use when behavior uncertainty affects release confidence.

- set `policyEnforcementMode` to `hard`,
- set `tagClassEnforcement.rc` and `tagClassEnforcement.stable` to `hard`,
- run disposable RC proof and confirm deterministic behavior.

### Option B: RC-Only Softening

Use when RC experimentation is desired without affecting stable safety.

- keep `tagClassEnforcement.stable = hard`,
- adjust only `tagClassEnforcement.rc` (`soft` or `observe`),
- validate with disposable RC proof tag.

### Option C: Temporary Observe for RC

Use when collecting additional telemetry from known noisy lanes.

- set `tagClassEnforcement.rc = observe`,
- keep stable hard,
- create follow-up issue with expiry criteria and revert date.

## Rollback Procedure

1. Prepare a focused config rollback commit.
2. Run `tools/PrePush-Checks.ps1 -SkipIconEditorFixtureChecks` locally.
3. Push to active fork branch and post PR note with rationale.
4. Create disposable RC proof tag and verify artifact fields.
5. If stable was impacted, halt stable promotion until proof is green.

## Communication Template

```text
Status: Phase 8 migration incident under investigation
Impact: <release class + gating impact>
Current mode: <policyEnforcementMode / tagClassEnforcement.*>
Mitigation: <selected option>
Next update: <time>
```

## Exit Criteria

Incident can be closed when:

- mitigation config is merged and validated,
- at least one disposable RC proof confirms expected enforcement metadata,
- stakeholder update is posted with run and artifact references,
- any temporary relaxation includes a tracked follow-up for re-tightening.