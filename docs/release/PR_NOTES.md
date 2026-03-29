<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4-rc.2 - PR Notes Helper

Reference sheet for the published `v0.6.4-rc.2` release candidate and its
checked-in release notes. This RC closes the unsigned-tag publication gap,
routes trust failures into repair/replay flow, and keeps the queue-empty and
runtime topology surfaces honest while the hosted-first conductor remains the
authoritative release path.

## 1. Summary

Release `v0.6.4-rc.2` focuses on four themes:

- **Release signing gate hardening**: the RC now fails before unsigned tag
  publication and surfaces explicit signing-readiness blocker classes.
- **Repair/replay publication flow**: existing unsigned tags can now be
  repaired or replayed through the authoritative publication path instead of
  leaving the RC in an ambiguous trust state.
- **Queue/runtime topology concentration**: the VI-history distributor,
  execution-cell bundle, kernel coordinator, and TestStand runtime surfaces are
  projected through the governor and queue-empty handoff evidence.
- **Published release evidence**: the RC ships with archived notes plus CLI
  archives, checksums, SBOM, and provenance assets attached to the release.

## 2. RC Highlights

- Release signing readiness now distinguishes code-path, signing-capability,
  and signing-authority blockers before any authoritative tag push is
  attempted.
- The release conductor can repair or replay publication when the authoritative
  tag exists but fails the trust contract.
- Queue-empty handoff, governor portfolio evidence, and runtime state now
  surface the VI-history distributor and concentrated execution topology more
  explicitly.
- The published GitHub Release attaches the released CLI bundles, checksums,
  SBOM, and provenance evidence for `v0.6.4-rc.2`.

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
- [ ] Published release `v0.6.4-rc.2` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`.

## 4. Reviewer Focus

- Confirm `CHANGELOG.md`, this helper, `TAG_PREP_CHECKLIST.md`, and
  `../archive/releases/RELEASE_NOTES_v0.6.4-rc.2.md` all reference
  `v0.6.4-rc.2` consistently.
- Review the hosted-first release gate adjustments:
  - `tools/policy/branch-required-checks.json`
  - `tools/priority/lib/release-pr-checks.mjs`
  - `tools/priority/lib/release-compare-evidence.mjs`
- Check that the release-signing readiness and repair/replay flow are pointing
  at the authoritative trust gate rather than silently accepting unsigned tags.
- Check that the queue-empty/runtime topology evidence remains deterministic on
  `release/*` branches while keeping the VI-history distributor handoff honest.

## 5. Follow-Up After RC

1. Cut the final `v0.6.4` release once RC evidence and signing publication stay
   green.
2. Re-run the template pivot gate after the RC version is published.
3. Keep the downstream proving rail pinned to the released template tag until a
   deliberate dependency bump is queued.

--- Updated: 2026-03-29 (aligned with the published `v0.6.4-rc.2` release candidate).
