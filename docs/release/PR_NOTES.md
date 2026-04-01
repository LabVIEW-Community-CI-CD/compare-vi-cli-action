<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.11 - PR Notes Helper

Reference sheet for the `v0.6.11` maintenance release. This cut carries the
`v0.6.10` stable line forward and adds the VI-history native-path repair proven
on the Windows NI Docker-backed proof surface.

## 1. Summary

Release `v0.6.11` focuses on three themes:

- **VI-history native-path correctness**: the released backend now resolves
  Windows NI proof-surface file paths without losing the repository-relative VI
  target, so hosted and local replay lanes can reach the real history target
  instead of a synthetic temp-root mismatch.
- **Windows NI proof continuity**: the LabVIEW Docker-backed Windows proof path
  remains the authoritative hosted execution surface, and `v0.6.11` is cut
  directly from the `v0.6.10` stable line so the released proof authority is
  preserved rather than reintroduced from stale `develop`.
- **Consumer-ready repin path**: the release packet is aligned for the next
  `comparevi-history` pin bump and the clone-backed `ni/labview-icon-editor`
  history proof rerun on the newly published backend.

## 2. Maintenance Highlights

- `tools/Compare-VIHistory.ps1`, `tools/Compare-RefsToTemp.ps1`, and
  `tools/Render-VIHistoryReport.ps1` now preserve the intended VI-history
  target path across the Windows NI proof surface instead of collapsing to a
  host-native path that the replay layer cannot certify.
- `tests/TestFileExistsAtRef.Tests.ps1` and
  `tests/CompareVI.GitRefs.VI2.Tests.ps1` now cover the backend-side path and
  git-ref seams that caused the Windows proof regression.
- Stable release surfaces now pin `0.6.11`, while the helper docs still point
  consumers at `v0.6.10` until publication completes.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [ ] Hosted Windows NI Docker proof is green on the release branch.
- [ ] Local-proof autonomy selector still emits the truthful next proof
      surface instead of looping or hanging.
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.11` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.11` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.11`
      before the clone-backed `ni/labview-icon-editor` proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the released Windows NI Docker proof and VI-history backend surfaces for correctness:
  - `.github/workflows/windows-ni-proof-reusable.yml`
  - `tools/Compare-VIHistory.ps1`
  - `tools/Compare-RefsToTemp.ps1`
  - `tools/Render-VIHistoryReport.ps1`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.11.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.10` to `v0.6.11` and rerun the
   clone-backed `ni/labview-icon-editor` proof on the released backend.
2. Confirm the Windows NI proof artifacts and the published benchmark packet
   still agree on the certified backend version after the repin.
3. Re-evaluate the current emitted history surface against the real developer
   question before treating any mode as decision-ready.

--- Updated: 2026-04-01 (prepared for the `v0.6.11` maintenance cut).
