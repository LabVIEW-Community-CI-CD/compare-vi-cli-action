# Issue 588 – Working Plan

## Context checkpoints
- Validate workflow currently calls PowerShell scripts inline (`Simulate-IconEditorBuild.ps1`, `Stage-BuildArtifacts.ps1`, `Prepare-FixtureViDiffs.ps1`, `Invoke-FixtureViDiffs.ps1`, `Render-ViComparisonReport.ps1`).
- Acceptance includes splitting the flow into smaller composites (prepare fixture, simulate build, stage artifacts, render report, compare, hook parity).
- Composite actions should live under `.github/actions/icon-editor/*` with README snippets + action.yml metadata.

## Implementation outline
1. **Inventory existing steps**  
   - Map workflow commands to logical boundaries (prepare → simulate → stage → compare → report → hook parity tests).  
   - Identify shared environment inputs (results dirs, GH tokens, enable flags).

2. **Create base composites**  
   - `prepare-fixture`: wraps fixture extraction/report generation (likely calling `Update-IconEditorFixtureReport.ps1` or new helper).  
   - `simulate-build`: calls `Simulate-IconEditorBuild.ps1` with parameters, outputs manifest, artifact paths, version info.  
   - `stage-artifacts`: uses `Stage-BuildArtifacts.ps1`, guarantees fixture report preservation.  
   - `render-report`: runs `Render-ViComparisonReport.ps1`.  
   - `prepare-vi-diff` / `invoke-vi-diff`: handle diff request generation and execution.  
   - `hook-parity-tests`: executes `node --test tools/icon-editor/__tests__/*.mjs` for parity verification.

3. **Wire composites into workflows**  
   - Replace inline pwsh steps in `validate.yml` with corresponding `uses: ./.github/actions/icon-editor/...`.  
   - Ensure job outputs remain equivalent (e.g., `vi_diff` step outputs request counts).  
   - Update other workflows (`ci-orchestrated.yml`, smoke, etc.) if they reuse the scripts.

4. **Testing strategy**  
   - Add unit tests for composite metadata using Node script (schema or presence assertions).  
   - Extend Pester coverage where script behaviour changes (e.g., verifying composite entry points pass through parameters).  
   - Run `tools/PrePush-Checks.ps1`, targeted Pester suites, and `priority:validate --allow-fork`.

5. **Documentation**  
   - Update `docs/ICON_EDITOR_PACKAGE.md` + developer guide to reference new composites and usage patterns.  
   - Provide README per composite with inputs/outputs examples.

## Immediate tasks
- [x] Capture the exact arguments & env vars used today; from `validate.yml`:
  - `Simulate-IconEditorBuild.ps1` receives `-FixturePath`, `-ResultsRoot`, `-ExpectedVersion` (object with `major/minor/patch/build/commit`), `-VipDiffOutputDir`, `-VipDiffRequestsPath`; relies on env `ICON_EDITOR_BUILD_MODE`, `ICON_EDITOR_SIMULATION_FIXTURE`, `ICON_EDITOR_ISSUE`, `RESULTS_DIR`.
  - `Invoke-IconEditorBuild.ps1` takes `-Major`, `-Minor`, `-Patch`, `-Build`, `-ResultsRoot`, optional `-RunUnitTests`.
  - `Prepare-FixtureViDiffs.ps1` uses `-ReportPath`, `-BaselineManifestPath`, `-OutputDir`; emits `vi-diff-requests.json`.
  - `Invoke-FixtureViDiffs.ps1` expects `-RequestsPath`, `-CapturesRoot`, `-SummaryPath`, `-TimeoutSeconds`.
  - `Render-ViComparisonReport.ps1` requires `-SummaryPath`, `-OutputPath`.
  - Jobs export outputs (`package_version`, `manifest_path`, `metadata_path`, `build_mode`, diff request counts) and upload artifacts from `$RUNNER_TEMP\icon-editor` plus `tests/results/_agent/icon-editor`.
- [x] Draft composite skeletons (`prepare-fixture`, `simulate-build`, `stage-artifacts`) under `.github/actions/icon-editor/`, wiring inputs/outputs doc strings.
- [x] Define output contracts for remaining composites and document expectations:
  - `prepare-fixture`: confirm `report-json`, `report-markdown`, `manifest-json`, `results-root`.
  - `simulate-build`: ensure outputs include `manifest-path`, `metadata-path`, `package-version`, `vip-diff-root`, `vip-diff-requests-path`.
  - `stage-artifacts`: bucket paths (`packages`, `reports`, `logs`) and JSON summary string.
  - Future composites (compare/report/hook parity) should expose summary/report paths + metadata for uploads.
  - Update developer docs to list these outputs and example usage.
- [x] Prototype workflow changes locally (swap one job to use the new composite while keeping inline steps as fallback until tests pass). _Status_: `validate.yml` now relies on the composite suite for simulate + compare paths, and artifact staging flows through `stage-artifacts`.

## Wiring plan for staging & compare composites
1. **Stage artifacts** ✅
   - Inline staging block replaced with `stage-artifacts` composite; artifact uploads now read composite outputs.
   - Fixture reports remain available for hook parity (composite copies the originals).

2. **VI diff composites** ✅
   - Composites (`prepare-vi-diff`, `invoke-vi-diff`, `render-vi-report`) landed and replace the remaining PowerShell blocks in both icon-editor jobs.
   - Lint job outputs still surface request counts from the composite metadata.

3. **Docs & validation**
   - Update composite READMEs and `docs/ICON_EDITOR_PACKAGE.md` to mention the new actions and usage.
   - ✅ Node metadata test added (`tools/icon-editor/__tests__/composites-metadata.test.mjs`); consider any extra coverage if gaps appear.
   - Run `tools/PrePush-Checks.ps1` and dispatch Validate in both simulate and real build modes to confirm end-to-end behaviour.
