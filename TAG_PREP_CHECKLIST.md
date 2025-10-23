<!-- markdownlint-disable-next-line MD041 -->
# v0.5.1 Tag Preparation Checklist

Helper reference for cutting the `v0.5.1` tag. Aligns with the release notes (`RELEASE_NOTES_v0.5.1.md`) and the
standing priority issue (#134). Update or archive once the tag is live.

## 1. Pre-flight Verification

- [ ] Work from the release branch (`release/v0.5.1-rc.1`, or latest RC) and ensure it is rebased/merged with
      `develop` for all changes targeted at 0.5.1.
- [ ] CI is green on the RC branch (Validate, fixtures, session-index, and any integration workflows).
- [ ] `node tools/npm/run-script.mjs lint` completes without errors (markdownlint + docs checks) on the RC branch.
- [ ] Optional: run `pwsh -File tools/PrePush-Checks.ps1` locally for early actionlint / YAML parity.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized `## [v0.5.1] - YYYY-MM-DD` section with the correct release date.
- [ ] All README / docs usage examples reference `@v0.5.1` (no lingering `-rc` or earlier tags outside of history
      callouts).
- [ ] `package.json` version is `0.5.1` and matches the release notes.
- [ ] Regenerate `docs/action-outputs.md` if outputs changed (`node tools/npm/run-script.mjs generate:outputs`) and
      confirm `action.yml` matches the documented inputs/outputs.
- [ ] Update `docs/documentation-manifest.json` if new documents were added as part of the release.

## 3. Dispatcher & Session Index Validation

- [ ] `./Invoke-PesterTests.ps1` (unit surface) passes and emits `tests/results/session-index.json` with `status: ok`.
- [ ] Self-hosted run with `./Invoke-PesterTests.ps1 -IntegrationMode include` (or CI equivalent) completes without
      recursion or guard failures; capture the session index artifact.
- [ ] Confirm the session index `stepSummary` appends cleanly in Validate / orchestrated workflows (check CI logs).
- [ ] Ensure `tools/Update-SessionIndexBranchProtection.ps1` reflects the current required checks (compare with
      `tools/policy/branch-required-checks.json`).

## 4. Fixture & Drift Integrity

- [ ] Regenerate or verify `fixtures.manifest.json` so `bytes` replaces `minBytes` and (if used) the `pair` block
      matches the latest schema (`fixture-pair/v1`).
- [ ] Run `pwsh -File tools/Validate-Fixtures.ps1 -Json -RequirePair` (with `-EvidencePath` when drift jobs produced
      compare evidence) to confirm no size mismatches.
- [ ] Validate current vs baseline fixture reports (`current-fixture-validation.json`,
      `baseline-fixture-validation.json`) for parity.
- [ ] Drift workflows (`Validate / fixtures`) are green and reference `Source: execJson` inside the report.

## 5. Release Materials Review

- [ ] `PR_NOTES.md` summarizes the 0.5.1 release (deterministic CI, session index, fixture policy, drift/report
  hardening).
- [ ] `PR_RELEASE_DESCRIPTION_v0.5.1.md`, `PR_RELEASE_CHECKLIST_v0.5.1.md`, and `RELEASE_NOTES_v0.5.1.md` are updated
  and
      consistent with each other.
- [ ] `ROLLBACK_PLAN.md` still applies (update if new rollback considerations emerged).
- [ ] Helper docs (`AGENTS.md`, `docs/ENVIRONMENT.md`, `docs/CI_ORCHESTRATION_REDESIGN.md`, etc.) reference the
      finalized flow and published tools image.

## 6. Tag Creation

- [ ] Update the release date in `CHANGELOG.md` if needed and commit final documentation/test updates.
- [ ] Create an annotated tag:

```pwsh
git tag -a v0.5.1 -m "v0.5.1: deterministic CI + session index + fixture policy hardening"
```

- [ ] Push the tag:

```pwsh
git push origin v0.5.1
```

## 7. GitHub Release Draft

Suggested outline:

1. Summary: deterministic self-hosted CI, session index artifacts, fixture manifest policy, drift/report improvements.
2. Upgrade notes: `fixtures.manifest.json` now uses `bytes`; session index artifacts are emitted everywhere.
3. Validation snapshot: mention required checks and guard outcomes.
4. Known issues / follow-ups: composites consolidation, managed tokenizer adoption (see standing issue).
5. Rollback: link to `ROLLBACK_PLAN.md`.

## 8. Post-Tag Actions

- [ ] Merge the release branch back to `develop` (keep CHANGELOG/readme updates in sync).
- [ ] Update `POST_RELEASE_FOLLOWUPS.md` with completed vs pending items for the 0.5.1 roadmap.
- [ ] Dispatch the orchestrated watcher or `node tools/npm/run-script.mjs ci:watch:rest --branch main` to monitor first
      runs on the tagged commit.

## 9. Validation After Publish

- [ ] Install the action via `@v0.5.1` in a sample workflow and confirm a compare using the canonical fixtures succeeds.
- [ ] Repeat with the LabVIEW CLI wrapper (if applicable) to verify the provider path resolves correctly.
- [ ] Check the uploaded session index and drift artifacts for deterministic ordering and schema compliance.

## 10. Communication

- [ ] Announce the release (internal channel/community notes) calling out deterministic CI, session index artifacts, and
      fixture policy changes.
- [ ] Remind consumers of the fixture byte-field change and the plan for upcoming composites/tokenizer work.

--- Updated: 2025-10-19 (revamped for the v0.5.1 release cycle).

