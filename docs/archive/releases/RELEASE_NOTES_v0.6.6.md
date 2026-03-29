# Release Notes v0.6.6

`v0.6.6` is a maintenance release that ships the last two downstream proving
hardening fixes that landed on `develop` after `v0.6.5`.

## Highlights

- Downstream promotion now keeps successful proving evidence when direct
  `downstream/develop` updates are blocked by repository rules, reporting an
  explicit `blocked-by-repository-rules` handoff instead of failing the run.
- Downstream onboarding now falls back to a consumer repository's checked-in
  `docs/policy/<branch>-branch-protection.json` contract when the live
  branch-protection API is not observable, which removes the last warning-only
  seam from the certified template consumer proof path.

## Included hardening slices

- `#2040` Tighten downstream promotion rule handoff
- `#2041` Use checked-in branch protection for onboarding

## Validation highlights

- Release branch `release/v0.6.6` updates the stable version surfaces to
  `0.6.6`.
- Post-merge downstream proving replay succeeded with:
  - workflow run `23718997600`
  - scorecard `status=pass`
  - scorecard `blockers=0`
  - downstream onboarding success `status=pass`
  - downstream onboarding success `totalWarnings=0`

## Consumer impact

- Stable consumers can move from `@v0.6.5` to `@v0.6.6` to pick up the shipped
  downstream maintenance fixes.
- No action interface expansion is required for this cut; the maintenance
  change is in governance/proving behavior and release confidence, not in the
  public compare input/output contract.
