<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.9 - PR Notes Helper

Reference sheet for the `v0.6.9` maintenance release. This cut repairs the
published `CompareVI.Tools` bundle so released downstream consumers can execute
the hosted NI Linux VI-history contract without a maintainer checkout.

## 1. Summary

Release `v0.6.9` focuses on three themes:

- **Executable released bundle**: `CompareVI.Tools-v0.6.9.zip` now carries the
  hosted NI Linux helper `tools/Get-LabVIEWContainerShellContract.ps1` instead
  of shipping an incomplete runtime contract.
- **Released-backend recovery**: downstream VI-history consumers can once again
  rely on the published bundle rather than a maintainer override or local
  source tree to execute the canonical proof path.
- **Narrow maintenance scope**: this cut only repairs released bundle
  executability. It does not expand the public VI-history surface or add new
  product claims.

## 2. Maintenance Highlights

- `tools/Publish-CompareVIToolsArtifact.ps1` now places
  `tools/Get-LabVIEWContainerShellContract.ps1` in the bundle and advertises it
  through the published hosted-runner contract metadata.
- `tools/Test-CompareVIHistoryBundleCertification.ps1` now fails closed if the
  extracted bundle omits the hosted NI Linux support scripts required by the
  released consumer path.
- Stable release surfaces now pin `0.6.9`, isolating the bundle-contract repair
  in an immutable stable cut after the broken `v0.6.8` publication.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [x] Direct bundle proof restored the published hosted NI Linux contract:
  - extracted bundle contains both `tools/Run-NILinuxContainerCompare.ps1` and
    `tools/Get-LabVIEWContainerShellContract.ps1`
  - bundle certification summary reports `status: producer-native-ready`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.9` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.9` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.9`
      before the canonical `DrawIcon.vi` product proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the released bundle contract repair for correctness:
  - `tools/Publish-CompareVIToolsArtifact.ps1`
  - `tools/Test-CompareVIHistoryBundleCertification.ps1`
  - `docs/schemas/comparevi-history-bundle-certification-v1.schema.json`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.9.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.8` to `v0.6.9` and rerun the
   canonical `DrawIcon.vi` proof on the released backend.
2. Re-evaluate the current emitted history surface against the real developer
   question before treating any mode as decision-ready.
3. Reduce the public mode surface again if the rerun product proof only
   justifies a narrower mode set.

--- Updated: 2026-03-30 (prepared for the `v0.6.9` maintenance cut).
