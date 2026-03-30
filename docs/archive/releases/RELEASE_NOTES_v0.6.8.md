# Release Notes v0.6.8

`v0.6.8` is a maintenance release that makes the `block-diagram` VI history
mode truthful on top of the earlier merge-aware start-ref repair.

## Highlights

- `block-diagram` mode now leaves block-diagram diffs visible instead of
  passing hidden `-nobd` and `-nobdcosm` suppression flags behind a mode name
  that implied the opposite behavior.
- This is the first backend cut that combines:
  - merge-aware VI history `startRef` resolution
  - truthful block-diagram compare flags
- The canonical `DrawIcon.vi` product proof can now move to a released backend
  that matches both the history window and the requested block-diagram mode.

## Included maintenance slice

- `#2046` Honor merge commits in VI history start ref resolution
- `#2048` fix: make block-diagram VI history mode truthful

## Validation highlights

- Release branch `release/v0.6.8` updates the stable backend version surfaces
  to `0.6.8`.
- Direct backend proofs validated the history-window repair before publication:
  - real-history stub proof preserved `startRef=47ae...` and processed four
    comparison pairs for `DrawIcon.vi`
  - synthetic merge-history proof preserved a merge commit as `startRef` while
    the legacy non-merge-aware probe reported no path touch
- Regression coverage now proves `block-diagram` mode does not emit `-nobd` or
  `-nobdcosm` in the compare flags or manifest receipts.

## Consumer impact

- Stable consumers can move from `@v0.6.6` to `@v0.6.8` to pick up both the
  merge-aware history start-ref repair and the truthful block-diagram mode
  semantics.
- `comparevi-history` should treat `v0.6.8` as the minimum backend ref for the
  canonical single-VI product proof going forward.
