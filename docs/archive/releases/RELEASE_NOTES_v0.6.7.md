# Release Notes v0.6.7

`v0.6.7` is a maintenance release that repairs VI history start-ref resolution
for histories that begin at a merge commit touching the target VI.

## Highlights

- VI history generation now uses merge-aware path detection when resolving the
  effective `startRef`, so a requested merge commit remains the start of the
  comparison window when the target VI changed through that merge.
- The canonical `DrawIcon.vi` product proof can now move forward on a released
  backend instead of depending on an unreleased maintainer branch override.
- This cut is intentionally narrow. It does not claim to resolve the separate
  question of which public history modes are decision-useful.

## Included maintenance slice

- `#2046` Honor merge commits in VI history start ref resolution

## Validation highlights

- Release branch `release/v0.6.7` updates the stable backend version surfaces
  to `0.6.7`.
- Direct backend proofs validated the repair before publication:
  - real-history stub proof preserved `startRef=47ae...` and processed four
    comparison pairs for `DrawIcon.vi`
  - synthetic merge-history proof preserved a merge commit as `startRef` while
    the legacy non-merge-aware probe reported no path touch
- Post-publication coordination for this cut is explicit:
  - repin `comparevi-history` to `v0.6.7`
  - rerun the canonical `DrawIcon.vi` proof on the released backend
  - take the separate mode-semantics correction before treating all current
    public modes as trustworthy decision surfaces

## Consumer impact

- Stable consumers can move from `@v0.6.6` to `@v0.6.7` to pick up the
  merge-aware history start-ref repair.
- `comparevi-history` should treat `v0.6.7` as the minimum backend ref for the
  canonical single-VI proof going forward.
