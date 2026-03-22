# v0.5.2 Tag Preparation Checklist
<!-- markdownlint-disable-next-line MD041 -->

Helper reference for cutting the `v0.5.2` tag. Aligns with the archived release notes
(`../archive/releases/RELEASE_NOTES_v0.5.2.md`) and the standing-priority issue (#273). Update or archive once the tag
is live.

## 1. Pre-flight Verification

- [ ] Work from the release branch (`release/v0.5.2-rc1`, or latest RC) and ensure it contains all changes targeted for
      0.5.2 (history suite, branch guard, release tooling updates).
- [ ] CI is green on the RC branch (Validate, fixtures, session-index, `vi-compare-refs`, `vi-staging-smoke`, and any
      integration workflows).
- [ ] Release PR required contexts are all `COMPLETED/SUCCESS` before finalize: `lint`, `pester / normalize`,
      `smoke-gate`, `Policy Guard (Upstream) / policy-guard`, and `commit-integrity`.
- [ ] `node tools/npm/run-script.mjs lint` completes without errors (markdownlint + docs checks) on the RC branch.
- [ ] Optional: run `pwsh -File tools/PrePush-Checks.ps1` locally for early actionlint / YAML parity.
- [ ] Verify a clean working tree (`git status`).

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` contains a finalized `## [v0.5.2] - YYYY-MM-DD` section with the correct release date.
- [ ] All README / docs usage examples reference `@v0.5.2` (no lingering `-rc` or earlier tags outside of history
      callouts).
- [ ] `package.json` version is `0.5.2` and matches the release notes.
- [ ] Regenerate `docs/action-outputs.md` if outputs changed (`node tools/npm/run-script.mjs generate:outputs`) and
      confirm `action.yml` matches the documented inputs/outputs.
- [ ] Update `docs/documentation-manifest.json` if new documents were added for the release.

## 3. Dispatcher & Session Index Validation

- [ ] `./Invoke-PesterTests.ps1` (unit surface) passes and emits `tests/results/session-index.json` with `status: ok`.
- [ ] Self-hosted run with `./Invoke-PesterTests.ps1 -IntegrationMode include` completes without recursion/guard
      failures; capture the session index artifact.
- [ ] Confirm the session index `stepSummary` appends cleanly in Validate / orchestrated workflows (check CI logs).
- [ ] Ensure `tools/Update-SessionIndexBranchProtection.ps1` reflects the current required checks (compare with
      `tools/policy/branch-required-checks.json`).

## 4. Fixture & Drift Integrity

- [ ] Regenerate or verify `fixtures.manifest.json`; confirm the additive history manifests remain aligned.
- [ ] Run `pwsh -File tools/Validate-Fixtures.ps1 -Json -RequirePair` (with `-EvidencePath` when drift jobs produced
      compare evidence) to confirm no size mismatches.
- [ ] Validate current vs baseline fixture reports (`current-fixture-validation.json`,
      `baseline-fixture-validation.json`) for parity.
- [ ] Drift workflows (`Validate / fixtures`) are green and reference `Source: execJson` inside the report.

## 5. Release Materials Review

- [ ] `../archive/releases/PR_RELEASE_DESCRIPTION_v0.5.2.md`, `../archive/releases/PR_RELEASE_CHECKLIST_v0.5.2.md`,
      and `../archive/releases/RELEASE_NOTES_v0.5.2.md` are updated and consistent with each other.
- [ ] `PR_NOTES.md` summarizes the 0.5.2 release (history suite, branch-policy guard, release automation, Docker parity,
      auto-publish refs).
- [ ] Helper docs (`AGENTS.md`, `AGENT_HANDOFF.txt`, `docs/DEV_DASHBOARD_PLAN.md`, `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`,
      `docs/plans/VALIDATION_MATRIX.md`, etc.) reflect the finalized flows and tooling.
- [ ] `ROLLBACK_PLAN.md` still applies (update if new rollback considerations emerged).

## 6. Tag Creation

- [ ] Update the release date in `CHANGELOG.md` if needed and commit final documentation/test updates.
- [ ] Create an annotated tag:

```pwsh
git tag -a v0.5.2 -m "v0.5.2: history suite, branch-policy guard, release automation"
```

- [ ] Push the tag:

```pwsh
git push origin v0.5.2
```

## 7. GitHub Release Draft

Suggested outline:

1. Summary: history suite telemetry, branch-policy guard + release automation, auto-publish refs, Docker parity helper.
2. Upgrade notes: history manifests + Dev Dashboard samples, release tooling scripts (`tools/priority/*`), branch guard
   expectations for `develop`.
3. Validation snapshot: mention required checks (Validate, fixtures, session-index, `vi-compare-refs`,
   `vi-staging-smoke`) and guard outcomes.
4. Known issues / follow-ups: monitor history ingestion dashboards, finalize release branch merger back to `develop`.
5. Rollback: link to `ROLLBACK_PLAN.md`.

## 8. Post-Tag Actions

- [ ] Merge the release branch back to `develop` (keep CHANGELOG/readme updates in sync).
- [ ] Dispatch `vi-compare-refs.yml` and `vi-staging-smoke.yml` on `develop` to confirm both compare evidence flows
      stay green with artifacts.
- [ ] Update `POST_RELEASE_FOLLOWUPS.md` with completed vs pending items for the 0.5.2 roadmap.
- [ ] Dispatch the orchestrated watcher or `node tools/npm/run-script.mjs ci:watch:rest --branch main` to monitor the
      first runs on the tagged commit.

## 9. Validation After Publish

- [ ] Install the action via `@v0.5.2` in a sample workflow and confirm a compare using the canonical fixtures succeeds.
- [ ] Exercise `tools/Compare-VIHistory.ps1` against the sample manifests to verify suite outputs and Dev Dashboard
      rendering.
- [ ] Re-run the LabVIEW CLI wrapper path to ensure rogue detection + cleanup guard stay green.
- [ ] Check the uploaded session index, history manifests, and drift artifacts for deterministic ordering and schema
      compliance.

## 10. Communication

- [ ] Announce the release (internal channel/community notes) calling out the history suite, branch-policy guard, and
      release automation improvements.
- [ ] Remind consumers of the new manifests/telemetry and the expectation that both `vi-compare-refs` and
      `vi-staging-smoke` evidence flows stay green for tagged builds.

--- Updated: 2025-10-23 (revamped for the v0.5.2 release cycle).
