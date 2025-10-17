<!-- markdownlint-disable-next-line MD041 -->
# v0.4.0 Tag Preparation Checklist

Helper reference for maintainers prior to cutting the final `v0.4.0` tag. Delete or archive after release if redundant
with PR notes.

## 1. Pre-flight Verification

- [ ] On release branch: `release/v0.4.0-rc.1` (or updated RC) fully merged with latest `develop` changes intended for
  release.
- [ ] CI green (unit + integration as applicable) on the RC branch.
- [ ] Markdown lint passes (run `node tools/npm/run-script.mjs lint:md`).
- [ ] (Optional) Workflow lint (actionlint) passes if tool available.
- [ ] No uncommitted changes: `git status` clean.

## 2. Version & Metadata Consistency

- [ ] `CHANGELOG.md` has finalized `## [v0.4.0] - YYYY-MM-DD` section (date updated to actual release day).
- [ ] No remaining references to `-rc` in README examples or docs referencing the version tag (other than historical
  sections).
- [ ] `package.json` version matches `0.4.0` (if version tracking used for tooling—update only if intentionally
  coupled).
- [ ] `action.yml` does not contain stale output/input names (compare to `docs/action-outputs.md`).
- [ ] `docs/action-outputs.md` regenerated if any last-minute output changes: `node tools/npm/run-script.mjs
  generate:outputs`.

## 3. Functional Sanity Pass

- [ ] Run dispatcher (unit only): `./Invoke-PesterTests.ps1` (expect PASS).
- [ ] (If canonical LVCompare present) run full suite: `./Invoke-PesterTests.ps1 -IntegrationMode include`.
- [ ] Manual single compare smoke (identical path short-circuit) if convenient.
- [ ] Manual legacy name usage triggers `[NamingMigrationWarning]` exactly once.

## 4. Diff / Schema Integrity

- [ ] No breaking schema key removals (review `docs/schemas/` git diff vs prior tag).
- [ ] Added schema versions follow additive rule (older test fixtures still valid).
- [ ] HTML diff summary deterministic ordering spot-check (two runs produce identical fragment when diff occurs).

## 5. Release Artifacts Review

- [ ] Ensure `PR_NOTES.md` does not include secrets or non-public paths.
- [ ] Consider pruning helper files (keep or remove): `PR_NOTES.md`, `TAG_PREP_CHECKLIST.md`, planned follow-up docs.
- [ ] Validate `shortCircuitedIdentical` output appears for identical-file simulation (if test executed).

## 6. Tag Creation

- [ ] Update date in `CHANGELOG.md` if not current.
- [ ] Commit any final doc/test tweaks.
- [ ] Create annotated tag:

```pwsh
git tag -a v0.4.0 -m "v0.4.0: naming migration + resiliency + dispatcher schema expansions"
```

- [ ] Push tag:

```pwsh
git push origin v0.4.0
```

## 7. GitHub Release Draft

Include sections:

1. Summary (migration + resiliency + schema versions + discovery soft mode).
2. Migration Notice (VI1.vi / VI2.vi now preferred; Base.vi/Head.vi deprecated; removal in v0.5.0).
3. Added / Changed / Fixed highlights (mirror concise CHANGELOG form).
4. Deprecations & Next Steps (guard expansion, fallback removal timeline).
5. Rollback Instructions (copy from `ROLLBACK_PLAN.md`).

## 8. Post-Tag Actions

- [ ] Merge release branch back to `develop` (fast-forward or standard merge depending on workflow) to sync CHANGELOG.
- [ ] Open follow-up issues (see `POST_RELEASE_FOLLOWUPS.md`).
- [ ] Monitor early adopters for migration warnings volume or unexpected discovery failure counts.

## 9. Validation After Publish

- [ ] Install action via `@v0.4.0` in a sample workflow and run a quick compare with `VI1.vi` and `VI2.vi`.
- [ ] Repeat using legacy names to confirm warning (no failure) still intact.
- [ ] Observe outputs in GitHub Action logs for deterministic ordering.

## 10. Communication

- [ ] Announce release in internal channel / community notes (emphasize upcoming fallback removal in v0.5.0).
- [ ] Encourage users to rename artifacts promptly to suppress warning.

--- Generated: 2025-10-03 (Helper file; adjust or remove post-release.)

