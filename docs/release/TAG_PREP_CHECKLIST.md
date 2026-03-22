# v0.6.4-rc.1 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting the `v0.6.4-rc.1` release candidate. Aligns with
the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.4-rc.1.md`) and the RC cut issue
(`#1797`). Update or archive once the release candidate is live.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.4-rc.1` (or the latest RC helper lane) and ensure
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
      `## [v0.6.4-rc.1] - 2026-03-22` section.
- [ ] Release docs reference `v0.6.4-rc.1` consistently where the RC is
      intentionally named.
- [ ] `package.json` version is `0.6.4-rc.1` and matches the release notes.
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
      `../archive/releases/RELEASE_NOTES_v0.6.4-rc.1.md` are consistent.
- [ ] Helper docs reflect the hosted-first RC flow:
  - `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`
  - `docs/knowledgebase/VICompare-Refs-Workflow.md`
  - `docs/RELEASE_OPERATIONS_RUNBOOK.md`
- [ ] `ROLLBACK_PLAN.md` still applies (update if new rollback considerations
      emerged).

## 6. Tag Creation

- [ ] Create an annotated RC tag:

```pwsh
git tag -a v0.6.4-rc.1 -m "v0.6.4-rc.1: hosted-first release conductor hardening"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.4-rc.1
```

## 7. GitHub Release Draft

Suggested draft-release outline:

1. Summary: hosted-first release conductor hardening, template conveyor
   dependency, continuity/control-plane fixes.
2. Upgrade notes: release helper safety, RC gate alignment, queue-empty pivot
   proof.
3. Validation snapshot: required checks, Fixture Drift Validation,
   Cookiecutter Bootstrap, and template verification.
4. Known issues / follow-ups: final `v0.6.4` cut, remaining non-RC backlog.
5. Rollback: link to `ROLLBACK_PLAN.md`.

## 8. Post-Tag Actions

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.4-rc.1` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Refresh `priority:pivot:template` after the RC version lands so the pivot
      gate reflects the new release summary.
- [ ] Update `POST_RELEASE_FOLLOWUPS.md` with completed vs pending items for the
      `0.6.4` roadmap.

## 9. Validation After Publish

- [ ] Install the action via `@v0.6.4-rc.1` in a sample workflow and confirm a
      compare using the canonical fixtures succeeds.
- [ ] Exercise the pinned template conveyor and downstream proving rail against
      the RC release summary.
- [ ] Re-run the LabVIEW CLI wrapper path to ensure rogue detection and cleanup
      guard stay green.

## 10. Communication

- [ ] Announce the RC cut, calling out the hosted-first release conductor,
      template dependency, and continuity hardening.
- [ ] Remind consumers that the final pivot to `LabviewGitHubCiTemplate`
      remains gated on an RC release summary and a future agent handoff.

--- Updated: 2026-03-22 (revamped for the `v0.6.4-rc.1` release cycle).
