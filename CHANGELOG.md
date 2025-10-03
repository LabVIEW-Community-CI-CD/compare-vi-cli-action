# Changelog
<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

## [v0.5.0] - TBD

### Breaking Changes

- **Removed legacy artifact naming fallback**: `Base.vi` / `Head.vi` references eliminated from scripts, tests, and documentation. All code now uses `VI1.vi` / `VI2.vi` exclusively. Migration: Rename your artifact files and update any workflows referencing the old names. Environment variable names (`LV_BASE_VI`, `LV_HEAD_VI`) and action input names (`base`, `head`) remain unchanged.

### Added

- Deterministic HTML diff fragment test (`tests/CompareLoop.HtmlDiffDeterminism.Tests.ps1`): Ensures byte-for-byte stability, deterministic list ordering, and proper HTML entity encoding across multiple invocations.
- Quantile accuracy and tuning documentation (`docs/QUANTILE_ACCURACY.md`): Comprehensive guide covering strategy selection (Exact/StreamingReservoir/Hybrid), error bounds for different distributions, capacity tuning, reconciliation frequency, and example configurations.
- Documentation improvements: Cross-links added from README and COMPARE_LOOP_MODULE.md to new quantile accuracy guide.

### Changed

- Updated all script and test references from `Base.vi`/`Head.vi` to `VI1.vi`/`VI2.vi` (includes: `set-env-vars.ps1`, integration tests, unit tests, module examples, runbook scripts).
- README migration note updated from v0.4.0 compatibility message to v0.5.0 breaking change notice.
- `.gitignore` expanded to exclude `tmp-*.json` artifacts.

### Fixed

- (None specific to v0.5.0 scope; unreleased fixes above)

### Migration Guide (v0.4.x → v0.5.0)

1. **Artifact Naming**: Rename `Base.vi` → `VI1.vi` and `Head.vi` → `VI2.vi` in your repository root or wherever you store reference VIs.
2. **Workflow Updates**: Search workflows for hardcoded `Base.vi`/`Head.vi` references and update to new names.
3. **Environment Variables**: No change required—`LV_BASE_VI` and `LV_HEAD_VI` variable names remain the same (only the file they point to changes).
4. **Validation**: Run existing integration tests with updated file names to confirm no regressions.

GitHub search snippet for downstream auditing:

```bash
# In your repository
grep -r "Base\.vi\|Head\.vi" --include="*.yml" --include="*.ps1" .github/
```

## [Unreleased] (Post v0.5.0)

### Added

- Auto-close loop resiliency: `LOOP_CLOSE_LABVIEW` (graceful close + kill fallback) and `LOOP_CLOSE_LABVIEW_FORCE` (post-close `taskkill /F /IM LabVIEW.exe /T`).
- Bitness guard: `Resolve-Cli` now inspects PE Machine field and rejects 32-bit `LVCompare.exe` at canonical path, providing actionable remediation guidance.
- Stray LVCompare mitigation: loop detects and terminates 32-bit `LVCompare` processes; emits `lvcompareStrayKill` JSON event (`detected`, `killed`).
- Enhanced labview close event: `labviewCloseAttempt` now includes `forceKill`, `forceKillSuccess`, and `graceMs` fields.
- JSON events reference documentation plus troubleshooting rows for modal dialogs and bitness mismatch in `INTEGRATION_RUNBOOK.md`.
- Tests: `Loop.AutoClose.Tests.ps1`, force-kill path test, stray LVCompare kill test, and bitness guard test (`CompareVI.BitnessGuard.Tests.ps1`).

### Changed

- Loop summary now surfaces auto-close mode (grace + forceKill state) and adds contextual troubleshooting hints.
- Executor baseline normalizes non-canonical LVCompare path to the canonical 64-bit path when available.

### Fixed

- Eliminated stale process handle retention by disposing LVCompare and LabVIEW processes after each iteration.
- Corrected synthetic PE header generation in new tests (proper `e_lfanew` byte writes) ensuring reliable bitness simulation.

## [v0.4.1] - 2025-10-03

### Added

- Runbook automation: `scripts/Invoke-IntegrationRunbook.ps1` plus new integration guidance file `docs/INTEGRATION_RUNBOOK.md` documenting end‑to‑end environment validation & troubleshooting flows.
- Runbook JSON schema (`integration-runbook-v1.schema.json`) establishing a stable shape for future automated auditing of runbook executions.
- Release verification tooling: `scripts/Verify-ReleaseChecklist.ps1` producing structured `release-verify-summary.json` (pre‑tag gating of CHANGELOG version/date, outputs/doc sync, helper artifact presence, markdown lint cleanliness).
- Short-circuit contract test: `CompareVI.ShortCircuitContract.Tests.ps1` validating `shortCircuitedIdentical` output and exit semantics.
- Release helper documentation set: `PR_NOTES.md`, `TAG_PREP_CHECKLIST.md`, `POST_RELEASE_FOLLOWUPS.md`, `ROLLBACK_PLAN.md` to standardize release and rollback procedures.
- Artifact naming migration assets retained with explicit `VI1.vi` / `VI2.vi` presence (legacy names still available this release for compatibility) preparing consumers for removal window.

### Changed

- Updated `action.yml`, `docs/action-outputs.md`, and README to reflect finalized `shortCircuitedIdentical` output semantics introduced in v0.4.0 and now enforced by dedicated contract tests.
- Strengthened naming migration messaging (runtime warning and docs) ensuring clearer guidance ahead of v0.5.0 legacy removal.

### Fixed

- Ensured annotated release preparation no longer depends on unstaged migration artifacts by codifying checklist verifications (prevents partial tag scenarios).

### Migration / Deprecation

- `Base.vi` / `Head.vi` remain deprecated; fallback resolution still active for one more release cycle. Preferred names: `VI1.vi` / `VI2.vi`.
- Planned removal of legacy fallback and expansion of guard tests to scripts + documentation in v0.5.0 (next minor). Consumers should update workflows now to avoid disruption.

### Notes

- Remote pre-existing v0.4.0 tag preserved; this patch release (v0.4.1) aggregates the finalized migration scaffolding, runbook schema, and verification tooling without rewriting history.


## [v0.4.0] - 2025-10-02

### Added

- Pester dispatcher schema v1.3.0 (`pester-summary-v1_3.schema.json`): optional `timing` block (opt-in via `-EmitTimingDetail`) with extended per-test duration statistics (count, totalMs, min/max/mean/median/stdDev, p50/p75/p90/p95/p99) while retaining legacy root timing fields.
- Pester dispatcher schema v1.4.0 (`pester-summary-v1_4.schema.json`): optional `stability` block (opt-in via `-EmitStability`) providing scaffolding fields for future retry/flakiness detection (currently placeholder values / no retry engine).
- Pester dispatcher schema v1.5.0 (`pester-summary-v1_5.schema.json`): optional `discovery` block (opt-in via `-EmitDiscoveryDetail`) surfacing patterns, sampleLimit, captured failure snippets, and truncation flag.
- Pester dispatcher schema v1.6.0 (`pester-summary-v1_6.schema.json`): optional `outcome` block (opt-in via `-EmitOutcome`) unifying run status classification (overallStatus, severityRank, flags, counts, exitCodeModel, classificationStrategy).
- Pester dispatcher schema v1.7.0 (`pester-summary-v1_7.schema.json`): optional `aggregationHints` block (opt-in via `-EmitAggregationHints`) providing heuristic guidance (`dominantTags`, `fileBucketCounts`, `durationBuckets`, `suggestions`, `strategy`).
- Pester dispatcher schema v1.7.1 (`pester-summary-v1_7_1.schema.json`): optional root metric `aggregatorBuildMs` emitted ONLY when `-EmitAggregationHints` is specified; captures the build time (milliseconds) for generating the `aggregationHints` heuristic block (Stopwatch measured). Absent otherwise to preserve baseline payload size.
- Action output: `shortCircuitedIdentical` indicating identical-path preflight short-circuit (no LVCompare invocation, forces `diff=false`, `exitCode=0`).
- Preflight guard: identical-path detection (short-circuit) and same-filename/different-path detection with actionable error message (prevents LVCompare IDE popup: "Comparing VIs with the same name is not supported").
- Nested discovery suppression logic (default on) preventing false-positive `discoveryFailures` counts from nested dispatcher invocations; configurable via `SUPPRESS_NESTED_DISCOVERY=0` to disable suppression for diagnostics.
- Debug discovery scan instrumentation (`DEBUG_DISCOVERY_SCAN=1`) emitting `[debug-discovery]` console lines and contextual `discovery-debug.log` snippets (400 char window per match) to accelerate root-cause analysis.
- Integration test file pre-filter: automatic exclusion of `*.Integration.Tests.ps1` at file selection stage when integration is disabled (unless `DISABLE_INTEGRATION_FILE_PREFILTER=1`). Reduces discovery/parsing overhead and eliminates extraneous skip noise.
- Naming migration groundwork: preferred artifact filenames `VI1.vi` / `VI2.vi` introduced (superseding legacy `Base.vi` / `Head.vi`). Fallback resolution added to integration tests, scripts, and helper tooling with explicit migration note in docs.
- Runtime migration warning: `CompareVI.ps1` emits `[NamingMigrationWarning]` when legacy names are detected to prompt early adoption.
- Environment toggle `ENABLE_AGG_INT=1` to opt-in the aggregationHints integration smoke test (requires canonical LVCompare path + `LV_BASE_VI` + `LV_HEAD_VI`).
- Dispatcher parameter echo block gated by `COMPARISON_ACTION_DEBUG=1` listing all bound parameters for reproducible issue reports.
- README troubleshooting section documenting discovery failure diagnostics, suppression toggles, and variable initialization guidance for `-Skip` expressions.

### Documentation

- README updated to reflect schema v1.3.0 and usage examples for `-EmitTimingDetail`.
- README further updated for schemas up through v1.7.1, aggregation build timing metric (`aggregatorBuildMs`), and new discovery diagnostics environment variables (`SUPPRESS_NESTED_DISCOVERY`, `DEBUG_DISCOVERY_SCAN`, `DISABLE_INTEGRATION_FILE_PREFILTER`, `ENABLE_AGG_INT`, `COMPARISON_ACTION_DEBUG`).
- Added migration note (artifact naming: `VI1.vi` / `VI2.vi` preferred; legacy names scheduled for removal in v0.5.0) to README and integration guide; updated examples across docs and module guide JSON examples to reflect new filenames while preserving schema key stability (`basePath`, `headPath`).
- Added variable initialization best-practice note (ensure variables referenced in `-Skip:` expressions are defined at script top-level to avoid discovery-time errors).

### Tests

- Added `PesterSummary.Timing.Tests.ps1` validating timing block emission; updated existing schema/context tests to expect `schemaVersion` 1.3.0.
- Extended / updated schema tests to cover additive versions 1.4.0–1.7.1 and presence/absence rules for new optional blocks & `aggregatorBuildMs` timing metric.
- Added / updated integration smoke test for aggregationHints (`PesterSummary.Aggregation.Integration.Tests.ps1`) with corrected variable scoping to avoid discovery-time uninitialized variable errors.
- Added guard & regression coverage around discovery failure detection ensuring nested dispatcher matches are suppressed and zero false positives when integration tests are skipped.

### Changed

- Discovery failure classification now elevates matches to `errors` only when there are no existing test failures or errors, preserving primary failure semantics while still preventing silent green runs.
- File selection phase emits `pester-selected-files.txt` earlier for improved debuggability before Pester execution.
- Aggregation hints generation now records build duration (`aggregatorBuildMs`) making performance of heuristic calculation observable in downstream manifests.
- Console and diff summary labeling updated from `Base`/`Head` to `VI1`/`VI2` in loop/module outputs (human-facing only; JSON schema keys unchanged) for consistency with migration.

### Fixed

- Resolved persistent false-positive `discoveryFailures=1` caused by an integration test referencing an uninitialized `$script:shouldRun` inside a `-Skip:` expression (moved initialization to discovery scope).
- Eliminated spurious nested dispatcher discovery failure matches by counting summary headers and suppressing nested contexts (reduces noisy false error promotions).
- Stabilized discovery scan output ordering & ANSI stripping ensuring deterministic test assertions across consoles.
- Ensured `pester-summary.json` remains minimal when optional blocks not requested (no accidental emission of timing/stability/aggregation keys on baseline runs).
- Guard test (`Migration.Guard.Naming.Tests.ps1`) enforces absence of legacy names within module scope preventing regression prior to full-scope expansion post deprecation window.

### Migration / Deprecation

- Legacy artifact filenames `Base.vi` / `Head.vi` are deprecated. They continue to function for this release via fallback but emit a warning at compare runtime.
- Preferred naming is now `VI1.vi` / `VI2.vi`. Update workflows, environment variables (`LV_BASE_VI`, `LV_HEAD_VI`), and repository test assets accordingly.
- Planned removal of legacy fallback & names: v0.5.0 (next minor). Guard scope will expand to scripts & docs at that time.
- Schema field names (`basePath`, `headPath`) remain unchanged to preserve consumer compatibility; only human-facing examples updated.

## [v0.4.0-rc.1] - 2025-10-02

### Added

- Schema export type inference via `Export-JsonShapeSchemas -InferTypes` (best‑effort predicate text heuristics attaching JSON Schema `type` or union types).
- Machine-readable failure capture for schema assertions using `-FailureJsonPath` on `Assert-JsonShape` / `Assert-NdjsonShapes` (produces `errors` or `lineErrors` arrays with timestamps).
- Diff helper `Compare-JsonShape` returning structured comparison object (missing, unexpected, predicate failures, scalar value differences) for regression-style assertions.
- Tests covering: type inference export (`Schema.TypeInference.Tests.ps1`), failure JSON emission (`Schema.FailureJson.Tests.ps1`), diff helper behavior (`Schema.DiffHelper.Tests.ps1`).
- Pester dispatcher JSON summary schema v1.2.0 (`pester-summary-v1_2.schema.json`) introducing optional context blocks (`environment`, `run`, `selection`) emitted only with new `-EmitContext` switch (default output unchanged except version bump 1.1.0 → 1.2.0).

### Tooling

- Expanded `docs/SCHEMA_HELPER.md` with sections for `-InferTypes`, `-FailureJsonPath`, and `Compare-JsonShape` usage including JSON payload examples.

### Documentation

- Module guide updated with Run Summary section and schema example; README “What’s New” section expanded.
- README updated to document schema v1.2.0, `-EmitContext`, and new optional context blocks.

### Tests

- Restored run summary renderer tests (`RunSummary.Tool.Restored.Tests.ps1`) using safe initialization (all `$TestDrive` usage inside `BeforeAll`/`It`) eliminating prior discovery-time null `-Path` anomaly.
- Removed quarantine placeholder (`RunSummary.Tool.Quarantined.Tests.ps1`); anomaly documented in issue template with reproduction script (`Binding-MinRepro.Tests.ps1`).
- Added `PesterSummary.Context.Tests.ps1` verifying context block emission; updated baseline schema test to expect `schemaVersion` 1.2.0 and absence of context when `-EmitContext` not used.

### Removed

- Flaky demo artifacts: `tests/Flaky.Demo.Tests.ps1` and helper script `tools/Demo-FlakyRecovery.ps1` fully removed (previously deprecated). Retry classification telemetry retained in watcher without demo harness.

## [v0.3.0] - 2025-10-01

### Added

- Streaming latency percentile strategy `StreamingReservoir` (bounded ring buffer) for low-memory approximate p50/p90/p99.
- Hybrid quantile strategy (`Hybrid`) that seeds with exact samples then transitions to streaming after `-HybridExactThreshold`.
- Periodic reconciliation option (`-ReconcileEvery`) to rebuild reservoir from all collected durations (uniform stride subsample) reducing long-run drift.
- Configurable reservoir capacity via `-StreamCapacity` (min 10) and exposure of `StreamingWindowCount` in result object for visibility.
- Reconciliation & streaming accuracy tests: `CompareLoop.StreamingQuantiles.Tests.ps1`, `CompareLoop.StreamingReconcile.Tests.ps1`.
- README documentation: comprehensive Streaming Quantile Strategies section (usage, tuning, accuracy guidance, future considerations).
- Dispatcher zero-test safeguard: early exit generates placeholder `pester-results.xml`, `pester-summary.txt`, JSON summary, and artifact manifest when no tests are found.
- Artifact manifest (`pester-artifacts.json`) with schema version identifiers (`summaryVersion`, `failuresVersion`, `manifestVersion`).
- `-EmitFailuresJsonAlways` switch to force emission of empty failures JSON for consistent CI parsing.
- Machine-readable JSON summary artifact (`pester-summary.json`) plus `-JsonSummaryPath` customization parameter.
- Structured failures artifact `pester-failures.json` on failing test runs.
- Synthetic diagnostic test file (`Invoke-PesterTests.Diagnostics.Tests.ps1`) gated by `ENABLE_DIAGNOSTIC_FAIL` env var.
- Nightly diagnostics workflow (`pester-diagnostics-nightly.yml`) exercising enhanced failure path without failing build.
- Job summary metrics block (self-hosted workflow) using JSON summary; integration tests covering manifest and schema validation.

### Changed

- Renamed streaming strategy from `StreamingP2` to `StreamingReservoir`; legacy name retained as deprecated alias with warning.
- Percentile emission logic now branches on Exact / Streaming / Hybrid modes without retaining full sample array for streaming cases.

### Fixed

- Dispatcher: robust handling of zero-test scenario (prevents null path/placeholder failures observed previously).
- Custom percentiles test failures caused by missing closure capture of `$delayMs` (replaced inline variable reference with `.GetNewClosure()` pattern).
- Binding-MinRepro warning matching instability by consolidating missing / non-existent path output into a single deterministic line and gating verbose noise behind a flag.
- Restored backward-compatible `IncludeIntegration` string normalization for legacy pattern-based tests.
- Single-test file array handling (`$testFiles.Count` reliability) and artifact manifest scoping.
- Corrected test assertion operators (`-BeLessOrEqual`) preventing ParameterBindingException during streaming tests.

### Removed

- Legacy experimental P² estimator implementation (fully supplanted by reservoir approach; alias maintained for user continuity).

### Notes

- JSON summary schema: `{ total, passed, failed, errors, skipped, duration_s, timestamp, pesterVersion, includeIntegration, schemaVersion }`.
- Reservoir percentiles use linear interpolation—raise `-StreamCapacity` or enable `-ReconcileEvery` for more stable high-percentile (p99) estimates under bursty distributions.
- Schema version policy: patch for strictly additive fields; minor for additive but monitored fields; major for breaking structural changes.

## [v0.2.0] - 2025-10-01

### Added (Initial Release)

- Output: `compareDurationSeconds` (execution duration in seconds; replaces legacy `durationSeconds` name not present in v0.1.0 release)
- Output: `compareDurationNanoseconds` (high-resolution duration in nanoseconds)
- Output: `compareSummaryPath` (path to generated JSON comparison metadata)
- High-resolution timing instrumentation in `CompareVI.ps1`
- Artifact publishing workflow: `.github/workflows/compare-artifacts.yml` (uploads JSON summary + HTML report, appends timing to job summary)
- Integration label workflow enhancement: timing block now includes seconds, nanoseconds, and combined seconds + ms line
- JSON summary parsing in PR comment workflow (preferred over regex parsing of text summary)

### Changed

- Renamed timing output `durationSeconds` to `compareDurationSeconds`
- PR integration workflow now prefers JSON-derived timing metrics before falling back to textual summary parsing

### Documentation

- README: expanded timing metrics section (nanoseconds + combined line) and documented artifact publishing workflow
- Added guidance on interpreting timing outputs in PR comments and job summaries

### Tests / Internal

- Extended Pester tests to assert presence of `CompareDurationNanoseconds` and related output lines

## [v0.1.0] - 2025-09-30

### Added

- Composite GitHub Action to run NI LVCompare (LabVIEW 2025 Q3) on two .vi files
- Inputs: `base`, `head`, `lvComparePath`, `lvCompareArgs` (quoted args supported), `working-directory`, `fail-on-diff`
- Environment support: `LVCOMPARE_PATH` for CLI discovery
- Outputs: `diff`, `exitCode`, `cliPath`, `command`
- Smoke-test workflow (`.github/workflows/smoke.yml`)
- Validation workflow with markdownlint and actionlint
- Release workflow that creates a GitHub Release on tag push
- Documentation: README, Copilot instructions, runner setup guide, CONTRIBUTING
