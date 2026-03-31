<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.10 - PR Notes Helper

Reference sheet for the `v0.6.10` maintenance release. This cut carries the
merged VI-history product work after the stale `v0.6.9` draft: decision-useful
history guidance, the self-hosted Windows proof split, and the Docker-override
runtime fixes that make the canonical proof reproducible on this machine.

## 1. Summary

Release `v0.6.10` focuses on four themes:

- **Decision-useful history output**: the canonical VI-history report now
  preserves touch-history chronology, surfaces collapsed-noise pairs, and tells
  the developer which pair to review first.
- **Windows proof split**: `vi-history-scenarios-windows` now runs as the
  self-hosted Windows Docker 64-bit lane, while
  `vi-history-scenarios-windows-lv32` runs in parallel as the native 32-bit
  reference.
- **Docker override determinism**: the NI Linux proof tooling and local fast
  loop now honor `DOCKER_COMMAND_OVERRIDE`, keeping WSL-hosted `docker.exe`
  and wrapper-based runtimes deterministic.
- **Released-backend proof target**: `comparevi-history` can now re-pin to the
  released backend and rerun the canonical
  `VIP_Pre-Install Custom Action.vi` proof without a maintainer-only runtime
  path.

## 2. Maintenance Highlights

- `tools/Compare-VIHistory.ps1`, `tools/Render-VIHistoryReport.ps1`, and
  `tools/VICategoryBuckets.psm1` now keep touch-history pairs visible and
  emit chronology-aware decision guidance instead of hiding the newest
  meaningful change behind report noise.
- `validate.yml` now routes Windows VI-history proofing through the self-hosted
  ingress host: Docker-backed 64-bit proof plus parallel LV32 reference.
- `tools/Run-NILinuxContainerCompare.ps1`,
  `tools/Assert-DockerRuntimeDeterminism.ps1`, and the local fast-loop facade
  now honor `DOCKER_COMMAND_OVERRIDE`, keeping the canonical proof runnable
  under WSL-hosted `docker.exe`.
- Stable release surfaces now pin `0.6.10`, superseding the unpublished
  `v0.6.9` draft with the merged product-semantic work.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [x] Direct merged-state proof succeeded for the canonical VI target:
  - target: `Tooling/deployment/VIP_Pre-Install Custom Action.vi`
  - outcome:
    3 comparisons, 2 signal diffs, 1 collapsed noise
  - decision statement:
    newest VI touch is metadata-only; review starts at pair 2 for the newest
    meaningful functional change
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.10` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.10` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.10`
      before the canonical `VIP_Pre-Install Custom Action.vi` product proof is
      rerun on the released backend

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the decision-useful VI-history surface for correctness:
  - `tools/Compare-VIHistory.ps1`
  - `tools/Render-VIHistoryReport.ps1`
  - `tools/VICategoryBuckets.psm1`
  - `tests/CompareVI.History.Tests.ps1`
  - `tests/Render-VIHistoryReport.Tests.ps1`
- Review the Windows proof split and Docker override behavior:
  - `.github/workflows/validate.yml`
  - `tools/Run-NILinuxContainerCompare.ps1`
  - `tools/Assert-DockerRuntimeDeterminism.ps1`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.10.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.8` to `v0.6.10` and rerun the
   canonical `VIP_Pre-Install Custom Action.vi` proof on the released backend.
2. Supersede the stale `v0.6.9` draft release so `v0.6.10` is the only active
   unpublished stable cut during final publication.
3. Re-evaluate the current emitted history surface against the real developer
   question before treating any mode as decision-ready.
4. Reduce the public mode surface again if the rerun product proof only
   justifies a narrower mode set.

--- Updated: 2026-03-30 (prepared for the `v0.6.10` maintenance cut).
