<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.2

Highlights

- Release signing readiness now fails before unsigned tag publication.
  - The release conductor distinguishes code-path, signing-capability, and
    signing-authority blockers so the RC stops on the actual trust failure.
  - Unsigned or untrusted tag states are now surfaced as explicit readiness
    failures instead of being discovered after a broken publication attempt.
- Release publication now supports repair and replay for existing unsigned tags.
  - Authoritative publication can repair an unsigned tag or replay immutable
    release publication without treating the original trust failure as
    acceptable.
  - The released RC reflects a deterministic path for recovering from tag trust
    problems while preserving immutable GitHub Release evidence.
- Queue-empty, governor, and runtime surfaces now project execution topology
  more explicitly.
  - VI-history distributor dependency, execution-cell bundle host contracts,
    TestStand process/runtime surfaces, and kernel coordinator topology now
    appear in the handoff and runtime evidence instead of remaining implicit.
  - Queue-empty proof is therefore closer to the real runtime dependency graph
    that governs release readiness.
- The published RC now ships a fuller trust packet.
  - GitHub Release assets include the released CLI bundles plus
    `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`.
  - The archived notes, helper docs, and version metadata now align to the
    published `v0.6.4-rc.2` surface.

Upgrade Notes

- This is still a release candidate. The final `v0.6.4` release depends on RC
  validation staying green and the release conductor continuing to publish from
  a trusted signing path.
- Release trust failures should now be remediated through the release
  conductor's repair/replay flow rather than through ad hoc tag mutation.
- Runtime and governor evidence now carry a more explicit execution-topology
  contract, so downstream consumers and maintainers should expect richer
  topology receipts in release-adjacent artifacts.

Validation Checklist

- [x] Published GitHub Release `v0.6.4-rc.2` with CLI distribution assets for
      released platforms
- [x] Published `SHA256SUMS.txt`
- [x] Published `sbom.spdx.json`
- [x] Published `provenance.json`
- [x] Full release compare view:
      `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/compare/v0.6.4-rc.1...v0.6.4-rc.2`
- [ ] Live hosted RC branch validation evidence retained under the corresponding
      `release/v0.6.4-rc.2` workflow runs
- [ ] Final stable `v0.6.4` cut
