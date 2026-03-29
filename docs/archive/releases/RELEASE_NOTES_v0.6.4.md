<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4

Highlights

- Stable trust and publication baseline
  - The signing-readiness and release-conductor repair/replay path proven in
    `v0.6.4-rc.2` now become the supported stable release path.
  - Stable publication no longer depends on unresolved RC-only guidance.
- Public contract alignment
  - The supported product boundary, minimal adopter contract, first-consumer
    success path, workflow criticality map, and continuity profile are now
    checked-in first-class surfaces.
  - Public usage docs and trust/status surfaces now align on the stable
    `v0.6.4` identity.
- Downstream proof closure
  - The hardened `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` consumer
    path passes cleanly with the required policy/promotion checks and protected
    `production` environment in place.
  - Downstream onboarding evidence is now deterministic because inline-script
    `uses:` literals no longer generate false workflow references.

Upgrade Notes

- `v0.6.4` is the supported stable backend pin that supersedes `v0.6.3`.
- Use `v0.6.x-rc` tags only when deliberately evaluating a future release
  candidate.
- After publish, repin certified downstream consumers such as
  `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` to `v0.6.4` and rerun the
  proving/onboarding rail.

Validation Checklist

- [ ] Published GitHub Release `v0.6.4` with CLI distribution assets for
      released platforms
- [ ] Published `SHA256SUMS.txt`
- [ ] Published `sbom.spdx.json`
- [ ] Published `provenance.json`
- [ ] Full release compare view:
      `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/compare/v0.6.4-rc.2...v0.6.4`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4`
- [ ] Re-run downstream onboarding against
      `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` after the stable pin
      update and confirm the report remains `pass`
