# v0.6.9 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.9` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.9.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.9` and ensure it contains the final maintenance
      changes.
- [ ] CI is green on the release branch (`lint`, `pester / normalize`,
      `smoke-gate`, `Policy Guard (Upstream) / policy-guard`,
      `commit-integrity`, and any active release workflows).
- [ ] Local lint equivalents complete without errors on the release branch:
      `node tools/npm/run-script.mjs lint:md`
      and
      `pwsh -File tools/PrePush-Checks.ps1`.
- [ ] Optional: run
      `node tools/npm/run-script.mjs priority:release:conductor:test`
      locally to preflight the release helper packet.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized
      `## [v0.6.9] - 2026-03-30` section.
- [ ] Stable docs reference `v0.6.8` consistently until `v0.6.9` publication
      completes, and the release helper packet references `v0.6.9`
      consistently.
- [ ] `package.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.9`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. Bundle Contract Regression Validation

- [ ] Focused bundle regression tests pass locally:

```bash
pwsh -NoLogo -NoProfile -File tools/Test-CompareVIHistoryBundleCertification.ps1 -BundleArchivePath tests/results/_agent/bundle-fix/artifacts/CompareVI.Tools-v0.6.9.zip -ResultsDir tests/results/_agent/bundle-fix/certification -SummaryJsonPath tests/results/_agent/bundle-fix/certification/summary.json
```

- [ ] Confirm the published bundle preserves the hosted NI Linux consumer contract:

- [ ] The extracted bundle contains:
      `tools/Run-NILinuxContainerCompare.ps1`
      and
      `tools/Get-LabVIEWContainerShellContract.ps1`
- [ ] Bundle certification reports `status: producer-native-ready`
- [ ] `comparevi-history` pin-bump coordination is queued immediately after
      publication so the canonical product proof uses the released backend
      instead of a maintainer override.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.9.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` still treat `v0.6.8` as the
      previously released stable pin until `v0.6.9` publication completes.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.9
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.9 -m "v0.6.9: repair CompareVI.Tools hosted bundle contract"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.9
```

## 6. Validation After Publish

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.9` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Install the bundle via `@v0.6.9` in a sample workflow and confirm the
      released hosted NI Linux VI-history contract executes without a local
      source-tree override.
- [ ] Optional maintainer fast loop: run the local Windows Docker replay lane
      for `vi-history-scenarios-windows` and confirm it still mirrors the
      hosted contract without replacing the hosted proof requirement.
- [ ] Re-pin `comparevi-history` to `v0.6.9` and confirm the canonical
      `DrawIcon.vi` proof reaches real comparisons on the released backend.

## 7. Communication

- [ ] Announce the maintenance cut, calling out the released bundle-contract
      repair and the required `comparevi-history` repin.
- [ ] Notify consumers that `v0.6.9` supersedes `v0.6.8` as the supported
      stable pin.

--- Updated: 2026-03-30 (prepared for the `v0.6.9` maintenance cut).
