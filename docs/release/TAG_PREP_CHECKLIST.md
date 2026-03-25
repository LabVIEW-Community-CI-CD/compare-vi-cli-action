# v0.6.4-rc.2 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting the `v0.6.4-rc.2` release candidate. Aligns with
the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.4-rc.2.md`) and the standing compare
publication rail (`#1877`). Update or archive once the release candidate is
live.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.4-rc.2` (or the latest RC helper lane) and ensure
      it contains all RC-targeted changes.
- [ ] CI is green on the RC branch (Validate, Fixture Drift Validation,
      Cookiecutter Bootstrap, and any active proving workflows).
- [ ] Release PR required contexts are all `COMPLETED/SUCCESS` before finalize:
      `lint`, `pester / normalize`, `smoke-gate`,
      `Policy Guard (Upstream) / policy-guard`, and `commit-integrity`.
- [ ] `node tools/npm/run-script.mjs lint` completes without errors on the RC
      branch.
- [ ] Optional: run `pwsh -File tools/PrePush-Checks.ps1` locally for early
      actionlint and YAML parity.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized
      `## [v0.6.4-rc.2] - 2026-03-24` section.
- [ ] Release docs reference `v0.6.4-rc.2` consistently where the RC is
      intentionally named.
- [ ] `package.json` version is `0.6.4-rc.2` and matches the release notes.
- [ ] The release materials explain why this RC exists:
  - `v0.6.4-rc.1` is authoritative for producer-native `vi-history`
  - `v0.6.4-rc.2` is the first RC meant to publish the producer-owned
    docker-profile contract
- [ ] Regenerate `docs/action-outputs.md` if outputs changed
      (`node tools/npm/run-script.mjs generate:outputs`) and confirm `action.yml`
      matches the documented inputs/outputs.
- [ ] Update `docs/documentation-manifest.json` if new documents were added for
      the release.

## 3. Dispatcher & Session Index Validation

- [ ] `./Invoke-PesterTests.ps1` (unit surface) passes and emits
      `tests/results/session-index.json` with `status: ok`.
- [ ] Session index and issue snapshot checks remain green in Validate.
- [ ] Confirm the current hosted VI history lanes publish their expected
      artifacts and summaries.

## 4. Fixture & Drift Integrity

- [ ] Fixture validation remains green on the RC branch.
- [ ] `fixture-drift.yml` stays green with hosted NI Linux evidence.
- [ ] Release-branch VI history evidence uses a bounded release-friendly window
      rather than failing on the full `main` delta.

## 5. Release Materials Review

- [ ] `PR_NOTES.md`, this checklist, and
      `../archive/releases/RELEASE_NOTES_v0.6.4-rc.2.md` are consistent.
- [ ] Helper docs reflect the hosted-first RC flow:
  - `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`
  - `docs/knowledgebase/VICompare-Refs-Workflow.md`
  - `docs/RELEASE_OPERATIONS_RUNBOOK.md`
- [ ] `ROLLBACK_PLAN.md` still applies (update if new rollback considerations
      emerged).

## 6. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel rc --version 0.6.4-rc.2
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json` reports
      `status: pass` before pushing the RC tag.
- [ ] Create an annotated RC tag:

```pwsh
git tag -a v0.6.4-rc.2 -m "v0.6.4-rc.2: publish producer docker-profile contract"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.4-rc.2
```

## 7. GitHub Release Draft

Suggested draft-release outline:

1. Summary: producer-owned Docker contract publication, template conveyor
   dependency, and release-surface continuity.
2. Upgrade notes: `v0.6.4-rc.1` already published the producer-native
   `vi-history` contract; `v0.6.4-rc.2` carries the producer-owned Docker
   contract on the next authoritative RC.
3. Validation snapshot: required checks, Fixture Drift Validation,
   Cookiecutter Bootstrap, template verification, and published-bundle
   observation.
4. Known issues / follow-ups: final `v0.6.4` cut and template `#20` promotion
   after authoritative publication proof.
5. Rollback: link to `ROLLBACK_PLAN.md`.

## 8. Post-Tag Actions

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.2` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Refresh `priority:pivot:template` after the RC version lands so the pivot
      gate reflects the new release summary.
- [ ] Update `POST_RELEASE_FOLLOWUPS.md` with completed vs pending items for the
      `0.6.4` roadmap.

## 9. Validation After Publish

- [ ] Install the action via `@v0.6.4-rc.2` in a sample workflow and confirm a
      compare using the canonical fixtures succeeds.
- [ ] Exercise the pinned template conveyor and downstream proving rail against
      the RC release summary.
- [ ] Re-run `node tools/npm/run-script.mjs priority:release:published:bundle`
      and confirm the published `CompareVI.Tools` bundle carries
      `consumerContract.capabilities.dockerProfile`.
- [ ] Re-run the LabVIEW CLI wrapper path to ensure rogue detection and cleanup
      guard stay green.

## 10. Communication

- [ ] Announce the RC cut, calling out the published producer-owned Docker
      contract and the template dependency it unlocks.
- [ ] Remind consumers that `LabviewGitHubCiTemplate#20` only starts after the
      published bundle proves the producer contract authoritatively.

--- Updated: 2026-03-24 (revamped for the `v0.6.4-rc.2` release cycle).
