handoff# Markdownlint & Icon Editor Doc Refinement

## Milestones
1. Catalog current lint tooling (blocking vs non-blocking).
2. Document ICON_EDITOR_PACKAGE.md generation flow and failure modes.
3. Propose consolidation plan for linting and doc stabilization.
4. Anchor the #591 delivery path: harden Validate guardrails, switch ApplyVIPC/build lanes to the VIPM CLI, and document the end-to-end artifact workflow.

## Findings
### Lint Tooling Inventory
- CLI lints run three primary engines: actionlint, markdownlint (strict + optional relaxed), and docs link checker.
- Non-lint guardrails in the same job include tracked build artifact guard, ad-hoc allowlist notification, and environment snapshot generation.
- `markdownlint` runs twice; the relaxed path previously only covered `docs/releases/**`, leaving long-form docs like `docs/TROUBLESHOOTING.md` under strict rules (MD013/MD032).
- Docs link checker writes JSON output to `tests/results/lint/docs-links.json` but still emits error counts in the summary even when marked non-blocking.

### ICON_EDITOR_PACKAGE.md Churn
- `tools/PrePush-Checks.ps1` reruns `Update-IconEditorFixtureReport.ps1`, rewriting `docs/ICON_EDITOR_PACKAGE.md` whenever the fixture manifest hash differs from the committed baseline.
- Regeneration touches hundreds of entries (resource plugins, tests) because the bundled VIP captures the entire resource directory; even unchanged fixtures produce large add/remove sections.
- The Validate pipeline previously regenerated the fixture report in both `lint` and the (now-removed) `icon-editor-build` job, so contributors often see incidental diffs after any `pre-push` run.
- Regeneration only prints a notice (“docs differ”), leaving contributors unsure whether to commit or revert; guidance remains sparse.

#### Recent Validate Runs (last 5) – top markdownlint offenders
- docs/ICON_EDITOR_PACKAGE.md (MD013) – 208 hits across every run (line length, list formatting).
- docs/DEVELOPER_GUIDE.md (MD013, MD007) – 192+ hits; large tables/bullets exceed 120 chars.
- docs/TROUBLESHOOTING.md (MD013, MD032) – recurring line-length and blank-line issues (48 + 32 hits).
- docs/test-requirements/vi-history-reporting.md & docs/investigations/546-* (MD032) – 32 hits each (list spacing).
- Generated `pr-576-body.md` & icon-editor fixture READMEs (MD032/MD022/MD041) – present in every run; candidates for relaxed linting or ignore list.

### Immediate Opportunities
#### Completed tweaks
- Validate now runs relaxed markdownlint over additional docs (`docs/TROUBLESHOOTING.md`, `docs/ICON_EDITOR_PACKAGE.md`, `docs/DEVELOPER_GUIDE.md`, `docs/investigations/**`, `docs/test-requirements/**`, `docs/knowledgebase/**`, and key READMEs).
- Updated the CLI lint composite action to accept multiline relaxed paths and set the docs link checker default to opt-in.
- Added `**/pr-*.md` to `.markdownlintignore` so generated PR bodies no longer fail strict linting.

#### Remaining proposals
- Treat fixture report regeneration as an explicit developer task (e.g., `npm run icon-editor:update-docs`) instead of auto-running during lint.
- Skip fixture doc regeneration during lint when the fixture assets are unchanged; leverage Validate run metadata to short-circuit the rewrite.
- Evaluate whether any remaining long-form docs need targeted MD013/MD032 overrides beyond the expanded relaxed glob coverage.

### Latest Validate snapshot (run 19110613024)
- `Validate / lint` failed inside the local link checker: `[regex]::Matches` received a `$null` input because `Get-Content -Raw` on the generated `tests/results/_agent/icon-editor-simulate/__fixture_extract/__system_extract/File Group 0/National Instruments/LabVIEW Icon Editor/empty_pull_request.md` (0 bytes) returns `$null` in pwsh.
- The watcher summary is saved to `tests/results/_agent/watcher-rest.json` for traceability; the run lives at https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/19110613024.
- Quick local repro confirms every other markdown file loads fine; only the empty placeholder trips the regex call. Guard the checker so zero-byte files yield an empty string (or skip the file entirely) instead of failing the entire job.

### 2025-11-05 hardening pass
- Updated `.github/workflows/validate.yml` so the link checker normalizes `$null` inputs from `Get-Content -Raw` to an empty string before running the regex.
- Ad-hoc repro (temp dir with an empty `.md` plus a referencing link) now exits cleanly (`OK`), proving the guard prevents the prior crash.
- Documented the guard/exclusion behaviour in `docs/DEVELOPER_GUIDE.md` so contributors know the fixture outputs are intentionally skipped.

### Fixture markdown filter sketch
- Hot paths today:
  - `tests/results/_agent/icon-editor-simulate/**/__system_extract/**/empty_pull_request.md` (0-byte placeholder).
  - `tests/results/_agent/history-stub/history-report.md` (generated report content).
  - Future replay artefacts will also land under `tests/results/_agent/**`.
- Filtering ideas:
  1. **Inline exclusion** – extend the `Where-Object` filter inside the link checker to drop any path containing `/tests/results/_agent/`. Simple, keeps authored docs in scope, and makes the job faster. Add a helper comment so future additions remember why fixtures are skipped.
  2. **Fixture-only pass** – keep the authored-doc checker as-is, but add a second (non-blocking) step that scans the fixture folder and warns if a link breaks. Useful if we still want visibility into fixture drift without blocking standard lint.
  3. **Manifest-driven allowlist** – teach the generator to emit a manifest of legit fixture markdown files, then have the checker ignore only those entries. More precise but adds maintenance overhead; probably overkill unless we need finer-grained control.
- Testing impact:
  - Option 1 just needs a unit/integration test proving the filter removes fixture files from the candidate set.
  - Option 2 requires a trimmed-down dataset plus expectations for the non-blocking path (ensure warnings bubble to the summary).
  - Option 3 would require generator + checker coordination; defer unless the first two options prove insufficient.

- Implemented option 1 on 2025-11-05; local scan now reports `FixtureIncluded=0` (490 authored markdown files remain in scope), so fixture placeholders no longer affect the checker.

### 2025-11-05 Validate replay (run 19111229037)
- `Validate / lint` finished cleanly: the link checker printed "Intra-repo markdown links OK." and no longer crashes on fixture placeholders.
- The overall workflow failed later in `hook-parity (windows-latest)` (known pending work) but that doesn't impact the lint verification.
- Decision for now: rely on the existing fixture validation flows (fixtures job + replay tools). Revisit a dedicated notice-only scan only if fixture diffs begin slipping through.

### Hook parity stabilization (2025-11-05)
- Windows hook parity failed because the PowerShell wrapper reported `fixtureAssetCategoryCounts` of 313 (counting the manifest delta) while the shell wrapper reported the real fixture-only asset count of 2.
- Updated `tools/PrePush-Checks.ps1` to derive category counts by explicitly tallying `fixtureReport.fixtureOnlyAssets` per category instead of relying on `Group-Object`, which was sensitive to the manifest delta on the hosted runner.
- Local `node tools/hooks/core/run-multi.mjs` now reports matching summaries across shell/pwsh; Validate run 19111757284 confirmed the fix on `windows-latest`.
- Remaining VIPM CLI tasks: finalize ApplyVIPC/build integration tests, update developer docs with new CLI usage, and retire legacy provider mentions so the pipeline is single-path.
- `.github/actions/apply-vipc/ApplyVIPC.ps1` and `Replay-ApplyVipcJob.ps1` now enforce `vipm-cli` (no more `auto/gcli/vipm` fallback paths).
- `IconEditorPackage.psm1` and `Invoke-IconEditorBuild.ps1` still accept `gcli`/`vipm`/`vipm-cli` (defaulting to CLI but keeping the older paths), and tests still import `tools/Vipm.psm1`.
- Legacy `tools/Vipm.psm1` provider hub remains in-place for comparisons and is imported whenever `vipm` is chosen.

## Next actions (self-prioritized)
1. **High** - Publish updated guidance (developer docs / CLI-lints readme) explaining the link checker guard and fixture exclusion so contributors know what changed.
2. **High** - Lock the pipeline to the VIPM CLI (drop the g-cli/legacy provider fallback, adjust replays/tests, and document the `vipm` requirement explicitly).
3. **Medium** - Finish cataloging lint guardrails vs. non-lint notices and fold the summary into developer docs so contributors know which failures to prioritize.
4. **Low** - Continue trimming relaxed markdownlint glob false negatives (measure whether TROUBLESHOOTING/DEVELOPER_GUIDE still need manual overrides after the next Validate cycle).

## Notes
- TODO: quantify how often `docs/TROUBLESHOOTING.md` still fails after the relaxed glob expansion.
- TODO: decide whether the docs link checker stays in CLI lints or moves to a scheduled/non-blocking workflow.
- DONE: Kicked off Validate run 19111229037; lint pass confirmed the guard and fixture filter.
