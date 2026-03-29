# v0.6.4 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting or replaying the final `v0.6.4` stable release.
Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.6.4.md`) and the checked-in stable
release surfaces.

## 1. Pre-flight Verification

- [ ] Work from `release/v0.6.4` and ensure it contains the final stable-target
      changes.
- [ ] CI is green on the stable branch (Validate, Fixture Drift Validation,
      Cookiecutter Bootstrap, downstream proving, and any active release
      workflows).
- [ ] Release PR required contexts are all `COMPLETED/SUCCESS` before finalize:
      `lint`, `pester / normalize`, `smoke-gate`,
      `Policy Guard (Upstream) / policy-guard`, and `commit-integrity`.
- [ ] `node tools/npm/run-script.mjs lint` completes without errors on the
      release
      branch.
- [ ] Optional: run `pwsh -File tools/PrePush-Checks.ps1` locally for early
      actionlint and YAML parity.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized
      `## [v0.6.4] - 2026-03-29` section.
- [ ] Release docs reference `v0.6.4` consistently.
- [ ] `package.json` version is `0.6.4` and matches the release notes.
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
      `../archive/releases/RELEASE_NOTES_v0.6.4.md` are consistent.
- [ ] Helper docs reflect the hosted-first stable flow:
  - `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`
  - `docs/knowledgebase/VICompare-Refs-Workflow.md`
  - `docs/RELEASE_OPERATIONS_RUNBOOK.md`
- [ ] `ROLLBACK_PLAN.md` still applies (update if new rollback considerations
      emerged).

## 6. Tag Creation

- [ ] Verify signed-tag readiness before push:

```pwsh
node tools/npm/run-script.mjs priority:release:signing:readiness
node tools/npm/run-script.mjs priority:release:conductor -- --apply --channel stable --version 0.6.4
```

- [ ] Confirm `tests/results/_agent/release/release-signing-readiness.json`
      does not report `externalBlocker` before retrying authoritative release
      publication.
- [ ] Confirm `tests/results/_agent/release/release-conductor-report.json` reports
      `status: pass` before pushing the stable tag.
- [ ] Create an annotated stable tag:

```pwsh
git tag -a v0.6.4 -m "v0.6.4: stable trust-reset and downstream proof baseline"
```

- [ ] Push the tag:

```pwsh
git push origin v0.6.4
```

## 7. GitHub Release Draft

Suggested draft-release outline:

1. Summary: stable trust/publication baseline, public contract alignment, and
   downstream proof closure.
2. Upgrade notes: stable pin guidance, supported product boundary, and
   consumer repin expectations.
3. Validation snapshot: required checks, Fixture Drift Validation, downstream
   onboarding pass, published signed assets, checksums, SBOM, and provenance.
4. Known issues / follow-ups: post-release consumer repins and normal
   maintenance watch items.
5. Rollback: link to `ROLLBACK_PLAN.md`.

## 8. Post-Tag Actions

- [ ] Run `node tools/npm/run-script.mjs release:finalize -- 0.6.4` from a
      clean helper lane to fast-forward `main` and `develop`, then record the
      finalize metadata.
- [ ] Re-pin `LabviewGitHubCiTemplate` to `v0.6.4` after the stable release
      lands so the pivot gate reflects the new release summary.
- [ ] Update `POST_RELEASE_FOLLOWUPS.md` with completed vs pending items for the
      `0.6.4` roadmap.

## 9. Validation After Publish

- [ ] Install the action via `@v0.6.4` in a sample workflow and confirm a
      compare using the canonical fixtures succeeds.
- [ ] Exercise the pinned template conveyor and downstream proving rail against
      the stable release summary.
- [ ] Re-run downstream onboarding against
      `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`:

```bash
node tools/npm/run-script.mjs priority:onboard:downstream -- \
  --repo LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate \
  --parent-issue 715 \
  --output tests/results/_agent/onboarding/downstream-onboarding-labview-template.json
```

- [ ] Confirm the onboarding report no longer fails
      `certified-reference-pinned` after the stable consumer ref is updated,
      and confirm the report remains `pass` without warning backlog.
- [ ] Re-run the LabVIEW CLI wrapper path to ensure rogue detection and cleanup
      guard stay green.

## 10. Communication

- [ ] Announce the stable cut, calling out the trusted publication baseline,
      public contract alignment, and downstream proof completion.
- [ ] Notify certified consumers that `v0.6.4` is now the supported stable pin.

--- Updated: 2026-03-29 (prepared for the final `v0.6.4` stable cut).
