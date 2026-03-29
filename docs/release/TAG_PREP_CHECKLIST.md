# v0.6.6 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.6` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.6.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.6` and ensure it contains the final maintenance
      changes.
- [ ] CI is green on the release branch (`lint`, `pester / normalize`,
      `smoke-gate`, `Policy Guard (Upstream) / policy-guard`,
      `commit-integrity`, and any active release workflows).
- [ ] `node tools/npm/run-script.mjs lint` completes without errors on the
      release branch.
- [ ] Optional: run `pwsh -File tools/PrePush-Checks.ps1` locally for early
      actionlint and YAML parity.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized
      `## [v0.6.6] - 2026-03-29` section.
- [ ] Stable docs reference `v0.6.6` consistently.
- [ ] `package.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.6`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. Downstream Hardening Validation

- [ ] Focused downstream onboarding tests pass locally:

```bash
node --test tools/priority/__tests__/downstream-onboarding.test.mjs tools/priority/__tests__/downstream-onboarding-success.test.mjs
```

- [ ] Workflow contract assertions pass:

```bash
node --test tools/priority/__tests__/downstream-promotion-contract.test.mjs tools/priority/__tests__/downstream-onboarding-contract.test.mjs
```

- [ ] Confirm the post-merge proving replay stays green on `develop` while
      routing direct `downstream/develop` updates through the documented
      `blocked-by-repository-rules` handoff.
- [ ] Confirm `required-checks-visible` can resolve from the consumer's
      checked-in `docs/policy/develop-branch-protection.json` contract when the
      live branch-protection API is not observable.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.6.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` still treat `v0.6.5` as the
      previously released stable pin until `v0.6.6` publication completes.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.6
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.6 -m "v0.6.6: publish downstream proving maintenance release"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.6
```

## 6. Validation After Publish

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.6` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Install the action via `@v0.6.6` in a sample workflow and confirm a
      compare using the canonical fixtures succeeds.
- [ ] Re-run downstream proving and confirm:
  - the scorecard still reports `status=pass` and `blockers=0`
  - the workflow reports `blocked-by-repository-rules` instead of failing when
    `GH013` blocks a direct `downstream/develop` push
  - the downstream onboarding success report stays `pass` with `totalWarnings=0`

## 7. Communication

- [ ] Announce the maintenance cut, calling out the rule-aware downstream
      promotion handoff and checked-in branch-protection fallback.
- [ ] Notify consumers that `v0.6.6` supersedes `v0.6.5` as the supported
      stable pin.

--- Updated: 2026-03-29 (prepared for the `v0.6.6` maintenance cut).
