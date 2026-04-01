# v0.6.12 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.12` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.12.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.12` and ensure it contains the final maintenance
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
      `## [v0.6.12] - 2026-04-01` section.
- [ ] Stable docs reference `v0.6.11` consistently until `v0.6.12` publication
      completes, and the release helper packet references `v0.6.12`
      consistently.
- [ ] `package.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.12`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. Windows Preflight Regression Validation

- [ ] Focused Windows preflight/runtime-manager regression tests pass locally:

```bash
pwsh -NoLogo -NoProfile -File Invoke-PesterTests.ps1 -TestsPath tests/Invoke-DockerRuntimeManager.Tests.ps1
pwsh -NoLogo -NoProfile -File Invoke-PesterTests.ps1 -TestsPath tests/Test-WindowsNI2026q1HostPreflight.Tests.ps1
```

- [ ] Confirm the released Windows NI / LabVIEW Docker image proof surface is intact:

- [ ] The released surface still includes:
      `tools/ProcessTimeoutHelper.ps1`
      `tools/Invoke-DockerRuntimeManager.ps1`
      and
      `tools/Run-NIWindowsContainerCompare.ps1`
      and
      `tools/Test-WindowsNI2026q1HostPreflight.ps1`
- [ ] Windows NI proof contracts and local replay commands still resolve:
      `docker:ni:windows:bootstrap`
      `compare:docker:ni:windows:probe`
      `compare:docker:ni:windows`
- [ ] `comparevi-history` pin-bump coordination is queued immediately after
      publication so the clone-backed `ni/labview-icon-editor` proof uses the
      released backend instead of a maintainer override.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.12.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` still treat `v0.6.11` as the
      previously released stable pin until `v0.6.12` publication completes.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.12
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.12 -m "v0.6.12: fix Windows preflight process capture deadlock"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.12
```

## 6. Validation After Publish

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.12` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Install the bundle via `@v0.6.12` in a sample workflow and confirm the
      released Windows NI and hosted VI-history contracts execute without a
      local source-tree override.
- [ ] Optional maintainer fast loop: run the local Windows Docker replay lane
      for `vi-history-scenarios-windows` and confirm it still mirrors the
      hosted contract without replacing the hosted proof requirement.
- [ ] Re-pin `comparevi-history` to `v0.6.12` and confirm the clone-backed
      `ni/labview-icon-editor` proof reaches real comparisons on the released
      backend.

## 7. Communication

- [ ] Announce the maintenance cut, calling out the Windows preflight deadlock
      fix and the required `comparevi-history` repin.
- [ ] Notify consumers that `v0.6.12` supersedes `v0.6.11` as the supported
      stable pin.

--- Updated: 2026-04-01 (prepared for the `v0.6.12` maintenance cut).
