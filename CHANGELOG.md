# Changelog
<!-- markdownlint-disable MD024 -->

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Added

- Pester dispatcher schema v1.3.0 (`pester-summary-v1_3.schema.json`): optional `timing` block (opt-in via `-EmitTimingDetail`) with extended per-test duration statistics (count, totalMs, min/max/mean/median/stdDev, p50/p75/p90/p95/p99) while retaining legacy root timing fields.
- Pester dispatcher schema v1.4.0 (`pester-summary-v1_4.schema.json`): optional `stability` block (opt-in via `-EmitStability`) providing scaffolding fields for future retry/flakiness detection (currently placeholder values / no retry engine).
- Pester dispatcher schema v1.5.0 (`pester-summary-v1_5.schema.json`): optional `discovery` block (opt-in via `-EmitDiscoveryDetail`) surfacing patterns, sampleLimit, captured failure snippets, and truncation flag.
- Pester dispatcher schema v1.6.0 (`pester-summary-v1_6.schema.json`): optional `outcome` block (opt-in via `-EmitOutcome`) unifying run status classification (overallStatus, severityRank, flags, counts, exitCodeModel, classificationStrategy).

### Documentation

- README updated to reflect schema v1.3.0 and usage examples for `-EmitTimingDetail`.

### Tests

- Added `PesterSummary.Timing.Tests.ps1` validating timing block emission; updated existing schema/context tests to expect `schemaVersion` 1.3.0.

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
