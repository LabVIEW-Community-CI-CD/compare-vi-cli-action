# Release VI History Migration Runbook

This runbook defines the operator steps for Phase 8 migration rollout of release VI history policy enforcement.

## Scope

- migration config: `configs/release-vi-history-migration.json`
- release workflow policy evaluation in `.github/workflows/release.yml`
- review index artifact: `release-vi-history-review-index`

## Enforcement Model

- `policyEnforcementMode`: fallback mode when no tag-class override is present.
- `tagClassEnforcement.rc`: effective mode for prerelease tags (`v*` containing `-`).
- `tagClassEnforcement.stable`: effective mode for stable tags (`v*` without `-`).

Allowed values: `observe`, `soft`, `hard`.

## Standard Rollout Sequence

1. Confirm branch head is pushed and local pre-push checks are green.
2. Set target mode in `configs/release-vi-history-migration.json`.
3. Create a disposable RC tag and run release proof.
4. Verify policy summary fields from the review-index artifact.
5. Post proof evidence on the PR before changing stable behavior.
6. Only change `stable` mode after stakeholder sign-off.

## Disposable RC Proof

Example command pattern:

```powershell
$sha = (git rev-parse --short HEAD).Trim()
$tag = "v0.6.0-rc.phase8-$sha"
git tag $tag
git push origin $tag
```

Monitor run and download review-index artifact:

```powershell
gh run list -R svelderrainruiz/compare-vi-cli-action --workflow "Release on tag"
gh run download -R svelderrainruiz/compare-vi-cli-action <run-id> -n release-vi-history-review-index -D tests/results/_agent/release-proof/phase8
```

## Required Verification Fields

From `release-vi-history-policy.json`:

- `tagClass`
- `enforcementSource`
- `enforcementMode`
- `rawOutcome`
- `outcome`

Expected consistency checks:

- RC tags should resolve `tagClass = rc`.
- Stable tags should resolve `tagClass = stable`.
- `enforcementSource` must match the configured path used for resolution.
- If `rawOutcome = fail` and effective mode is `observe` or `soft`, then `outcome` should be `warn`.
- If `rawOutcome = fail` and effective mode is `hard`, job should fail.

## Stable Promotion Checklist

Before enabling any less strict stable behavior:

1. At least one green RC proof run with expected enforcement metadata.
2. No unresolved migration incidents for the previous two release proofs.
3. PR comment evidence posted with run URL and artifact field snapshot.
4. Explicit sign-off recorded in standing issue #216 comments.

## Operational Notes

- Keep changes additive; do not remove legacy outputs during Phase 8.
- Use disposable tags for proof runs; do not reuse released tags.
- Treat mode changes as configuration changes requiring PR review.

## Ongoing Monitoring

- Track stable-tag hard-enforcement evidence in `docs/RELEASE_VI_HISTORY_STABLE_ENFORCEMENT_MONITORING.md`.
- Update the tracker after each stable release cycle with run/job URLs and policy summary field values.