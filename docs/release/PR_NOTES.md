<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.12 - PR Notes Helper

Reference sheet for the `v0.6.12` maintenance release. This cut carries the
`v0.6.11` stable line forward and adds the Windows preflight process-capture
repair proven on the Windows NI Docker-backed proof surface.

## 1. Summary

Release `v0.6.12` focuses on three themes:

- **Windows preflight process-capture robustness**: the released backend now
  drains large Docker manifest output through a shared timeout-safe helper, so
  the Windows NI proof lane reaches a deterministic ready/fail-closed outcome
  instead of stalling during preflight.
- **Windows NI proof continuity**: the LabVIEW Docker-backed Windows proof path
  remains the authoritative hosted execution surface, and `v0.6.12` is cut
  directly from the `v0.6.11` stable line so the released proof authority is
  preserved rather than reintroduced from stale `develop`.
- **Consumer-ready repin path**: the release packet is aligned for the next
  `comparevi-history` pin bump and the clone-backed `ni/labview-icon-editor`
  history proof rerun on the newly published backend.

## 2. Maintenance Highlights

- `tools/ProcessTimeoutHelper.ps1` now provides the shared compiled
  process-capture path for Windows Docker preflight helpers, preventing large
  `docker manifest inspect` output from wedging the hosted proof lane.
- `tools/Invoke-DockerRuntimeManager.ps1`,
  `tools/Test-WindowsNI2026q1HostPreflight.ps1`, and
  `tools/Assert-DockerRuntimeDeterminism.ps1` now consume that helper and keep
  explicit timeout classifications for Windows NI proof preflight failures.
- `tests/Invoke-DockerRuntimeManager.Tests.ps1` and
  `tests/Test-WindowsNI2026q1HostPreflight.Tests.ps1` now cover the large
  manifest-output seam that previously stranded the hosted preflight step.
- Stable release surfaces now pin `0.6.12`, while the helper docs still point
  consumers at `v0.6.11` until publication completes.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [ ] Hosted Windows NI Docker proof is green on the release branch.
- [ ] Windows preflight helper coverage proves large Docker manifest output
      does not deadlock the bounded helper path.
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.12` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.12` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`
- [ ] `comparevi-history` repins `comparevi-backend-ref.txt` to `v0.6.12`
      before the clone-backed `ni/labview-icon-editor` proof is rerun

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the released Windows NI Docker proof and VI-history backend surfaces for correctness:
  - `.github/workflows/windows-ni-proof-reusable.yml`
  - `tools/ProcessTimeoutHelper.ps1`
  - `tools/Invoke-DockerRuntimeManager.ps1`
  - `tools/Test-WindowsNI2026q1HostPreflight.ps1`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.12.md`

## 5. Follow-Up After Stable

1. Re-pin `comparevi-history` from `v0.6.11` to `v0.6.12` and rerun the
   clone-backed `ni/labview-icon-editor` proof on the released backend.
2. Confirm the Windows NI proof artifacts and the published benchmark packet
   still agree on the certified backend version after the repin.
3. Re-evaluate the current emitted history surface against the real developer
   question before treating any mode as decision-ready.

--- Updated: 2026-04-01 (prepared for the `v0.6.12` maintenance cut).
