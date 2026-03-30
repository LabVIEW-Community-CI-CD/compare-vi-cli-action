<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.8 - PR Notes Helper

Reference sheet for the `v0.6.8` maintenance release. This cut ships the
mode-semantics correction that makes `block-diagram` history output truthful on
top of the previously landed merge-aware start-ref repair.

## 1. Summary

Release `v0.6.8` focuses on three themes:

- **Truthful block-diagram mode**: `block-diagram` no longer hides the very
  block-diagram diffs the mode name promises to show.
- **Canonical single-VI readiness**: this is the first backend cut that
  contains both the merge-aware `startRef` repair and the block-diagram mode
  correction needed for the `comparevi-history` `DrawIcon.vi` proof.
- **Still a narrow maintenance cut**: this release repairs mode correctness,
  but it does not yet claim that every currently exposed public mode is
  decision-useful for developers.

## 2. Maintenance Highlights

- `block-diagram` mode now removes the hidden `-nobd`/`-nobdcosm` suppression
  flags that previously contradicted the public mode label.
- The shipped backend now combines the merge-aware `startRef` repair with the
  truthful block-diagram compare flags required for the canonical
  `DrawIcon.vi` proof.
- Stable release surfaces now pin `0.6.8`, isolating the product-semantic
  correction in an immutable stable cut before any further surface reduction.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [x] Direct backend proof preserved the requested merge-aware history window:
  - real-history stub proof preserved `startRef=47ae...` and processed four
    comparison pairs across the requested modes
  - synthetic merge-history proof preserved a merge commit as `startRef` while
    the legacy probe reported no path touch
- [x] Block-diagram mode regression removes hidden block-diagram suppression:
  - `tests/CompareVI.History.Tests.ps1` asserts `block-diagram` mode does not
    emit `-nobd` or `-nobdcosm`
- [ ] Published release `v0.6.8` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.8`
      before the canonical `DrawIcon.vi` product proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the history correctness repairs:
  - `tools/Compare-VIHistory.ps1`
  - `tests/CompareVI.History.Tests.ps1`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.8.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.6` to `v0.6.8` and rerun the
   canonical `DrawIcon.vi` proof on the released backend.
2. Reduce the public mode surface if the rerun product proof only justifies a
   narrower mode set.
3. Keep the release scope narrow until the product proof shows which current
   surfaces actually help a developer decide what changed.

--- Updated: 2026-03-30 (prepared for the `v0.6.8` maintenance cut).
