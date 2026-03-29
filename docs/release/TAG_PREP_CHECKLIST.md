# v0.6.5 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.5` maintenance release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.5.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.5` and ensure it contains the final maintenance
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
      `## [v0.6.5] - 2026-03-29` section.
- [ ] Stable docs reference `v0.6.5` consistently.
- [ ] `package.json`, `package-lock.json`, `Directory.Build.props`, and
      `tools/CompareVI.Tools/CompareVI.Tools.psd1` all report `0.6.5`.
- [ ] `docs/action-outputs.md` still matches `action.yml`.
- [ ] Update `docs/documentation-manifest.json` if release-doc coverage changed.

## 3. Runtime Guard Validation

- [ ] Focused compare/runtime tests pass locally:

```pwsh
Invoke-Pester -Path 'tests/CompareVI.Timeout.Tests.ps1','tests/CompareVI.InputOutput.Tests.ps1','tests/Action.CompositeOutputs.Tests.ps1' -Output Detailed -CI
```

- [ ] Workflow contract assertions pass:

```bash
node --test tools/priority/__tests__/docker-labview-path-contract.test.mjs tools/priority/__tests__/capability-ingress-runner-routing.test.mjs
```

- [ ] Confirm the specialized `labview-cli-compare` workflow still uses
      `compare-timeout-seconds: '1200'` and that the action input remains
      opt-in for other consumers.

## 4. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.5.md` are consistent.
- [ ] `README.md` and `docs/USAGE_GUIDE.md` treat `v0.6.5` as the current
      supported stable pin.
- [ ] `POST_RELEASE_FOLLOWUPS.md` reflects the current maintenance backlog
      instead of historical `v0.5.0` planning debt.

## 5. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.5
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json`
      reports `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.5 -m "v0.6.5: publish compare timeout guard maintenance release"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.5
```

## 6. Validation After Publish

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.5` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Install the action via `@v0.6.5` in a sample workflow and confirm a
      compare using the canonical fixtures succeeds.
- [ ] Re-run the native wrapper path and confirm:
  - the compare still succeeds under the `1200` second budget
  - `Runner Unblock Guard` executes afterward
  - the lane does not emit timeout exit code `124`

## 7. Communication

- [ ] Announce the maintenance cut, calling out the guarded compare runtime and
      verified native wrapper proof.
- [ ] Notify consumers that `v0.6.5` supersedes `v0.6.4` as the supported
      stable pin.

--- Updated: 2026-03-29 (prepared for the `v0.6.5` maintenance cut).
