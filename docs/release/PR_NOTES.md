<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.7 - PR Notes Helper

Reference sheet for the `v0.6.7` maintenance release. This cut ships the
merge-aware VI history start-ref repair from `develop` without bundling the
separate mode-semantics correction work.

## 1. Summary

Release `v0.6.7` focuses on three themes:

- **Merge-aware history anchors**: `tools/Compare-VIHistory.ps1` now preserves
  a requested merge commit as the start of the history window when the target
  VI changed through that merge.
- **Canonical single-VI recovery**: this is the backend cut required for the
  `comparevi-history` `DrawIcon.vi` proof to render real comparisons instead of
  honestly failing closed with zero executed pairs.
- **Narrow maintenance scope**: this cut does not claim to solve the separate
  question of which public history modes are decision-useful; that remains the
  next product-semantic slice.

## 2. Maintenance Highlights

- History start-ref resolution now uses merge-aware path detection
  (`git diff-tree --root -m ...`) instead of merge-blind detection, so
  merge-only VI touches stay inside the emitted history plan.
- The shipped backend can now preserve `startRef=47ae...` for the canonical
  `DrawIcon.vi` proof instead of collapsing that proof to
  `startRef=endRef=fe98...` and zero comparisons.
- Stable release surfaces now pin `0.6.7`, isolating the backend repair in an
  immutable stable cut before the separate mode-semantics work begins.

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
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.7` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.7` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.7`
      before the canonical `DrawIcon.vi` product proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the start-ref repair for correctness:
  - `tools/Compare-VIHistory.ps1`
  - `tests/CompareVI.History.Tests.ps1`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.7.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.6` to `v0.6.7` and rerun the
   canonical `DrawIcon.vi` proof on the released backend.
2. Take the separate mode-semantics correction before treating the emitted
   public history modes as trustworthy decision surfaces.
3. Reduce the public mode surface if the rerun product proof only justifies a
   narrower mode set.

--- Updated: 2026-03-30 (prepared for the `v0.6.7` maintenance cut).
