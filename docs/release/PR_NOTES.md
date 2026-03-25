<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.2 - PR Notes Helper

Reference sheet for refining the `v0.6.4-rc.2` release PR and draft release.
This RC is about publishing the merged producer-owned Docker contract, keeping
the template conveyor pinned and green, and finishing the compare-side release
identity shift needed to unblock the template Docker-profile consumer rail.

## 1. Summary

Release `v0.6.4-rc.2` focuses on four themes:

- **Producer-owned Docker contract publication**: the next RC publishes
  `consumerContract.capabilities.dockerProfile` and
  `consumerContract.dockerImageContract` in the authoritative
  `CompareVI.Tools` release bundle.
- **Honest RC identity shift**: `v0.6.4-rc.1` is now authoritative for
  producer-native `vi-history`, but a fresh RC is needed because that published
  bundle predates the merged Docker-profile contract.
- **Template conveyor as a pinned dependency**:
  `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.1` is treated as an
  immutable dependency and is revalidated through the cookiecutter conveyor.
- **Continuity/control-plane hardening**: replay automation routing, standing
  release continuity, and published-bundle observation stay aligned while the
  RC moves toward authoritative Docker-contract publication.

## 2. RC Highlights

- The published bundle observer now proves `v0.6.4-rc.1` is authoritative for
  producer-native `vi-history`, which narrows the remaining release gap to the
  newer Docker-profile contract.
- The next RC carries the merged producer Docker contract from `#1940` / `#1941`
  onto the release surface instead of relying on template-local conventions.
- The downstream template rail remains pinned and blocked cleanly until the new
  producer contract is published.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [ ] Latest `fixture-drift.yml` run for `release/v0.6.4-rc.2` is green and
      uploads the NI Linux review-suite evidence bundle.
- [ ] Latest template verification report stays `pass` for
      `LabviewGitHubCiTemplate@v0.1.1`.
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.2` completes
      from a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`.
- [ ] `node tools/npm/run-script.mjs priority:release:published:bundle` flips
      to the new RC and proves the producer-owned Docker contract is present.

## 4. Reviewer Focus

- Confirm `CHANGELOG.md`, this helper, `TAG_PREP_CHECKLIST.md`, and
  `../archive/releases/RELEASE_NOTES_v0.6.4-rc.2.md` all reference
  `v0.6.4-rc.2` consistently.
- Review the producer Docker-contract publication surfaces:
  - `tools/Publish-CompareVIToolsArtifact.ps1`
  - `docs/schemas/comparevi-tools-release-manifest-v1.schema.json`
  - `docs/schemas/comparevi-tools-docker-profile-capability-v1.schema.json`
  - `docs/schemas/comparevi-tools-docker-image-contract-v1.schema.json`
- Check that the release branch verification helper is validating real RC
  materials instead of stale historical release docs.

## 5. Follow-Up After RC

1. Re-run the published-bundle observer after publication and confirm the
   producer-owned Docker contract is authoritative.
2. Start `LabviewGitHubCiTemplate#20` only after that published contract is
   real.
3. Cut the final `v0.6.4` release once the RC evidence and template follow-up
   both settle.

--- Updated: 2026-03-24 (aligned with the `v0.6.4-rc.2` release candidate).
