<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.4 - PR Notes Helper

Reference sheet for the final `v0.6.4` stable release. This cut promotes the
trusted `v0.6.4-rc.2` publication path into the supported stable line, aligns
the public product/adopter contract, and closes the downstream onboarding noise
seam that remained after consumer hardening.

## 1. Summary

Release `v0.6.4` focuses on four themes:

- **Trusted stable publication baseline**: the signing/readiness and
  repair/replay flow proven in `v0.6.4-rc.2` now become the supported stable
  release path.
- **Public trust packet alignment**: the supported product boundary, minimal
  adopter contract, and current stable version now align on `v0.6.4`.
- **Honest maintainer governance**: workflow criticality, continuity, and
  release-runbook surfaces now match the repository's actual single-owner
  operating model.
- **Downstream proof closure**: the hardened `LabviewGitHubCiTemplate`
  consumer path passes cleanly, and the onboarding scanner no longer emits the
  false workflow-reference artifact from inline scripts.

## 2. Stable Highlights

- The release conductor stable path now stands on a proven RC trust baseline
  instead of an unresolved publication experiment.
- Public entry docs now expose the supported product boundary, minimal adopter
  contract, first-consumer success path, workflow criticality map, and
  continuity profile as first-class checked-in surfaces.
- The downstream proving rail is no longer blocked on stale stable pins,
  missing required checks, or a missing protected deployment environment in the
  certified template consumer.
- Downstream onboarding evidence remains `pass` without the prior harmless
  inline-script `uses:` false positive.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [ ] Latest `fixture-drift.yml` run for `release/v0.6.4` is green and
      uploads the NI Linux review-suite evidence bundle.
- [ ] Latest downstream onboarding report for
      `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` is `pass` with zero
      warning/fail backlog.
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.4` completes
      from a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`.
- [ ] Published release `v0.6.4` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`.

## 4. Reviewer Focus

- Confirm `CHANGELOG.md`, this helper, `TAG_PREP_CHECKLIST.md`, and
  `../archive/releases/RELEASE_NOTES_v0.6.4.md` all reference `v0.6.4`
  consistently.
- Review the stable release-surface alignment across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Check that public usage docs and downstream proof surfaces now point at the
  stable `v0.6.4` line instead of the prior stable tag or an RC-only pin.
- Check that the release conductor stable path still points at the
  authoritative trust gate rather than relying on local/manual tag mutation.

## 5. Follow-Up After Stable

1. Re-pin `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` and any other
   certified downstream consumers to `v0.6.4`.
2. Re-run downstream onboarding and template smoke after the stable pin update
   and record the passing artifact as the new consumer baseline.
3. Watch the first maintenance cycle for merge-queue drift, Dependabot noise,
   or security/regression regressions before opening a new hardening stream.

--- Updated: 2026-03-29 (prepared for the final `v0.6.4` stable cut).
