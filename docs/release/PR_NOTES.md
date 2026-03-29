<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.6 - PR Notes Helper

Reference sheet for the `v0.6.6` maintenance release. This cut ships the last
two downstream hardening fixes from `develop` without reopening the broader
`v0.6.5` runtime guard scope.

## 1. Summary

Release `v0.6.6` focuses on three themes:

- **Rule-aware downstream proving**: `.github/workflows/downstream-promotion.yml`
  now treats direct `downstream/develop` push rejection under repository rules
  as a documented handoff instead of collapsing the proving run.
- **Contract-backed branch protection evidence**:
  `tools/priority/downstream-onboarding.mjs` now falls back to the consumer's
  checked-in `docs/policy/<branch>-branch-protection.json` contract when the
  live branch-protection API is not observable.
- **Shipped maintenance baseline**: the two post-`v0.6.5` hardening fixes are
  now packaged into an immutable stable release line instead of remaining
  `develop`-only behavior.

## 2. Maintenance Highlights

- Downstream proving now ends `success` with a `blocked-by-repository-rules`
  handoff when `GH013` blocks a direct push to `downstream/develop`, while the
  scorecard still records `status=pass` and `blockers=0`.
- Downstream onboarding now resolves `required-checks-visible` from the
  consumer template's checked-in branch-protection contract when the workflow
  token cannot read live protected-branch settings across repositories.
- Stable release surfaces now pin `0.6.6`, so the shipped maintenance line
  includes both downstream hardening slices.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [x] Post-merge downstream proving replay on `develop` succeeded with
      branch-rule handoff:
  - initial handoff proof:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23718725540`
  - checked-in branch-protection contract proof:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23718997600`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.6` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.6` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Review the downstream maintenance fixes for correctness:
  - `.github/workflows/downstream-promotion.yml`
  - `tools/priority/downstream-onboarding.mjs`
  - `tools/priority/__tests__/downstream-onboarding.test.mjs`
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.6.md`

## 5. Follow-Up After Stable

1. Re-pin certified downstream consumers from `v0.6.5` to `v0.6.6` so the
   shipped stable line includes the downstream-proving hardening.
2. Keep watching `downstream-promotion` for real consumer drift, not
   cross-repo branch-protection visibility noise.
3. Reopen downstream proving only if a later consumer contract surface still
   cannot be proven from either live API evidence or a checked-in policy
   contract.

--- Updated: 2026-03-29 (prepared for the `v0.6.6` maintenance cut).
