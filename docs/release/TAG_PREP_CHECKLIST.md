# v0.6.10 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.10` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.10.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.10` and ensure it contains the final maintenance
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
      `## [v0.6.10] - 2026-03-30` section.
- [ ] Stable docs reference `v0.6.8` consistently until `v0.6.10` publication
      completes, and the release helper packet references `v0.6.10`
      consistently.
- [ ] `package.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.10`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. Canonical Proof & Runtime Validation

- [ ] Focused canonical proof replay succeeds on the release branch:

```bash
DOCKER_COMMAND_OVERRIDE="$(command -v docker.exe)" pwsh -NoLogo -NoProfile -File <comparevi-history-root>/scripts/Invoke-CompareVIHistoryManualExplorationFastLoop.ps1 -ConsumerRepositoryRoot <consumer-root> -ConsumerRef develop -ViPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' -ToolingRoot <compare-vi-cli-action-root> -InvokeScriptPath <consumer-proof-script> -ResultsDir <results-dir> -NoisePolicy collapse
```

- [ ] Confirm the merged-state proof remains decision-useful:
  - 3 comparisons
  - 2 signal diffs
  - 1 collapsed noise
  - decision statement routes review to pair 2 as the newest meaningful change
- [ ] Confirm the self-hosted Windows split remains healthy:
  - `vi-history-scenarios-windows` plans and executes as the 64-bit Windows
    Docker lane
  - `vi-history-scenarios-windows-lv32` plans in parallel as the native
    32-bit reference
  - planner regressions for the empty health-receipt binding path remain green
- [ ] `comparevi-history` pin-bump coordination is queued immediately after
      publication so the canonical product proof uses the released backend
      instead of a maintainer override.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.10.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` still treat `v0.6.8` as the
      previously released stable pin until `v0.6.10` publication completes.
- [ ] The release packet consistently calls the canonical proof target
      `Tooling/deployment/VIP_Pre-Install Custom Action.vi`.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.10
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.10 -m "v0.6.10: ship decision-useful VI history proofing"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.10
```

## 6. Validation After Publish

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.10` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Install the bundle via `@v0.6.10` in a sample workflow and confirm the
      released hosted NI Linux VI-history contract executes without a local
      source-tree override.
- [ ] Optional maintainer fast loop: run the local Windows Docker replay lane
      for `vi-history-scenarios-windows` and confirm it still mirrors the
      self-hosted certification contract without replacing the release proof.
- [ ] Re-pin `comparevi-history` to `v0.6.10` and confirm the canonical
      `VIP_Pre-Install Custom Action.vi` proof reaches real comparisons on the
      released backend.
- [ ] Supersede the stale draft `v0.6.9` release record once `v0.6.10`
      publishes so consumers do not see competing unpublished stable cuts.

## 7. Communication

- [ ] Announce the maintenance cut, calling out the decision-useful history
      guidance, the Windows proof split, and the required `comparevi-history`
      repin.
- [ ] Notify consumers that `v0.6.10` supersedes `v0.6.8` as the supported
      stable pin.

--- Updated: 2026-03-30 (prepared for the `v0.6.10` maintenance cut).
