# v0.6.4-rc.2 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the `v0.6.4-rc.2` release candidate.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.4-rc.2.md`) and the published RC
release surfaces. Update or archive once the next release candidate supersedes
it.

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
      `## [v0.6.4-rc.2] - 2026-03-25` section.
- [ ] Release docs reference `v0.6.4-rc.2` consistently where the RC is
      intentionally named.
- [ ] `package.json` version is `0.6.4-rc.2` and matches the release notes.
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
git tag -a v0.6.4-rc.2 -m "v0.6.4-rc.2: signing-gated release conductor repair and topology hardening"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.4-rc.2
```

## 7. GitHub Release Draft

Suggested draft-release outline:

1. Summary: signing-gated release conductor hardening, repair/replay flow, and
   runtime topology concentration.
2. Upgrade notes: release-signing readiness, repair of unsigned tags, queue and
   governor topology evidence.
3. Validation snapshot: required checks, Fixture Drift Validation, published
   signed assets, checksums, SBOM, and provenance.
4. Known issues / follow-ups: final `v0.6.4` cut, remaining non-RC backlog.
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
- [ ] Re-run downstream onboarding against
      `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`:

```bash
node tools/npm/run-script.mjs priority:onboard:downstream -- \
  --repo LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding-labview-template.json
```

- [ ] Confirm the onboarding report no longer fails
      `certified-reference-pinned` after the stable consumer ref is updated. If
      protected-environment or required-check warnings remain, record them as
      explicit follow-up backlog instead of treating the downstream proof as
      complete.
- [ ] Re-run the LabVIEW CLI wrapper path to ensure rogue detection and cleanup
      guard stay green.

## 10. Communication

- [ ] Announce the RC cut, calling out the signing-gated release conductor,
      repair/replay flow, and runtime topology concentration.
- [ ] Remind consumers that the final pivot to `LabviewGitHubCiTemplate`
      remains gated on an RC release summary and a future agent handoff.

--- Updated: 2026-03-29 (realigned to the published `v0.6.4-rc.2` release cycle).
