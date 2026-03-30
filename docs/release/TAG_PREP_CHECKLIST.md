# v0.6.8 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.8` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.8.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.8` and ensure it contains the final maintenance
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
      `## [v0.6.8] - 2026-03-30` section.
- [ ] Stable docs reference `v0.6.6` consistently until `v0.6.8` publication
      completes, and the release helper packet references `v0.6.8`
      consistently.
- [ ] `package.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.8`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. History Semantics Validation

- [ ] Focused history regression tests pass locally:

```bash
pwsh -NoLogo -NoProfile -Command "Invoke-Pester -Path 'tests/CompareVI.History.Tests.ps1' -Output Detailed -CI"
```

- [ ] Confirm the direct backend proofs preserve the requested history start:

- [ ] Real-history stub proof preserves `startRef=47ae...` for
      `DrawIcon.vi` and processes four comparison pairs.
- [ ] Synthetic merge-history proof preserves the merge commit as `startRef`
      while the legacy non-merge-aware probe reports no touch.
- [ ] `block-diagram` mode regression proves the emitted compare flags do not
      include `-nobd` or `-nobdcosm`.
- [ ] `comparevi-history` pin-bump coordination is queued immediately after
      publication so the canonical product proof uses the released backend.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.8.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` still treat `v0.6.6` as the
      previously released stable pin until `v0.6.8` publication completes.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.8
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.8 -m "v0.6.8: publish truthful block-diagram VI history mode"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.8
```

## 6. Validation After Publish

- [ ] Publish the `v0.6.8` tag and let `release.yml` attach the release assets
      and provenance bundle.
- [ ] Install the action via `@v0.6.8` in a sample workflow and confirm a
      merge-aware VI history run preserves the requested start ref while
      `block-diagram` mode leaves block-diagram surfaces visible.
- [ ] Re-pin `comparevi-history` to `v0.6.8` and confirm the canonical
      `DrawIcon.vi` proof reaches real comparisons instead of failing closed on
      zero executed pairs.

## 7. Communication

- [ ] Announce the maintenance cut, calling out the truthful block-diagram mode
      fix and the required `comparevi-history` repin.
- [ ] Notify consumers that `v0.6.8` supersedes `v0.6.6` as the supported
      stable pin.

--- Updated: 2026-03-30 (prepared for the `v0.6.8` maintenance cut).
