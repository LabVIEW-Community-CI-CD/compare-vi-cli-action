<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.10 - PR Notes Helper

Reference sheet for the `v0.6.10` maintenance release. This cut promotes the
Windows NI Docker-backed proof authority and local-proof autonomy packet onto
the stable line while carrying forward the stable release-control-plane repairs
needed to keep publication deterministic.

## 1. Summary

Release `v0.6.10` focuses on four themes:

- **Windows NI proof authority**: the LabVIEW Docker-backed Windows proof path
  now owns VI-binary CI truth through
  `.github/workflows/windows-ni-proof-reusable.yml`.
- **Local-proof autonomy**: maintainers can iterate locally through the shared
  Windows Docker and VI-history proof surfaces before escalating to hosted CI.
- **Layered Pester control plane**: service-model context, selection,
  readiness, execution, finalize, postprocess, and evidence are now explicit
  layers in the released baseline.
- **Release publication repair**: the stable release conductor now ignores
  generic queue stabilization pauses, no longer requires green dwell, supports
  first-time signed tag publication replay, and defers impossible exact-SHA
  downstream proof until `develop` realigns.

## 2. Maintenance Highlights

- `.github/workflows/windows-ni-proof-reusable.yml` and
  `.github/workflows/vi-binary-gate.yml` now route the authoritative hosted
  Windows NI proof contract directly.
- `tools/Run-NIWindowsContainerCompare.ps1`,
  `tools/Test-WindowsNI2026q1HostPreflight.ps1`, and
  `tools/Invoke-DockerRuntimeManager.ps1` now form the released LabVIEW Docker
  image proof surface.
- `tools/priority/comparevi-local-program-ci.mjs` now federates the Pester, VI
  History, and Windows shared-surface packets into one local next-step
  selector.
- Stable release surfaces now pin `0.6.10`, carrying the promoted Windows NI
  and release-conductor repairs into an immutable stable cut.

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
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.10` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.10` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.10`
      before the canonical `DrawIcon.vi` product proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the released Windows NI Docker proof and autonomy surfaces for correctness:
  - `.github/workflows/windows-ni-proof-reusable.yml`
  - `tools/Run-NIWindowsContainerCompare.ps1`
  - `tools/Test-WindowsNI2026q1HostPreflight.ps1`
  - `tools/priority/comparevi-local-program-ci.mjs`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.10.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.9` to `v0.6.10` and rerun the
   canonical `DrawIcon.vi` proof on the released backend.
2. Re-evaluate the current emitted history surface against the real developer
   question before treating any mode as decision-ready.
3. Reduce the public mode surface again if the rerun product proof only
   justifies a narrower mode set.

--- Updated: 2026-04-01 (prepared for the `v0.6.10` maintenance cut).
