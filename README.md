# Compare VI (composite) GitHub Action

<!-- ci: bootstrap status checks -->

[![Validate](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/validate.yml)
[![Smoke test](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml/badge.svg)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/smoke.yml)
[![Repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action)
[![Environment](https://img.shields.io/badge/docs-Environment%20Vars-6A5ACD)](./docs/ENVIRONMENT.md)

## Purpose

This repository provides a **composite GitHub Action** for comparing two LabVIEW `.vi` files
using National Instruments' LVCompare CLI tool. It enables CI/CD workflows to detect
differences between LabVIEW virtual instruments, making it easy to integrate LabVIEW code
reviews and diff checks into automated GitHub Actions workflows.

The action wraps the `LVCompare.exe` command-line interface with intelligent path
resolution, flexible argument pass-through, and structured output formats suitable for
workflow branching and reporting. It supports both single-shot comparisons and
experimental loop mode for latency profiling and stability testing.

**Key Features:**

- **Simple Integration**: Drop-in action for self-hosted Windows runners with LabVIEW installed
- **Flexible Configuration**: Full pass-through of LVCompare CLI flags via `lvCompareArgs`
- **Structured Outputs**: Exit codes, diff status, timing metrics, and command audit trails
- **CI-Friendly**: Automatic step summaries, JSON artifacts, and configurable fail-on-diff behavior
- **Loop Mode (Experimental)**: Aggregate metrics, percentile latencies, and histogram generation for performance analysis

Validated with LabVIEW 2025 Q3 on self-hosted Windows runners. See also:
[`CHANGELOG.md`](./CHANGELOG.md) and the release workflow at
`.github/workflows/release.yml`.

## Documentation Map

- Workflows overview: `docs/WORKFLOWS_OVERVIEW.md`
- Fixtures and Validator: `docs/FIXTURES.md`
- Self-hosted setup: `docs/SELFHOSTED_CI_SETUP.md`
- Developer guide: `docs/DEVELOPER_GUIDE.md`

> **Breaking Change (v0.5.0)**: Legacy artifact names `Base.vi` / `Head.vi` are no longer supported. Use `VI1.vi` / `VI2.vi` exclusively. Public action input names (`base`, `head`) and environment variables (`LV_BASE_VI`, `LV_HEAD_VI`) remain unchanged.

## Requirements

- Self-hosted Windows runner with LabVIEW 2025 Q3 installed and licensed
- `LVCompare.exe` installed at the **canonical path**: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- Only the canonical path is supported; paths via `PATH`, `LVCOMPARE_PATH`, or `lvComparePath` must resolve to this exact location

## Fixture Artifacts (VI1.vi / VI2.vi)

This repository ships two canonical fixtures (`VI1.vi`, `VI2.vi`) and a manifest
(`fixtures.manifest.json`). For policy, validator exit codes, and update commands,
see `docs/FIXTURES.md`.

### Fixture Validator (Refined)

`tools/Validate-Fixtures.ps1` now supports structured JSON output and stricter manifest governance.

Supported exit codes:

| Code | Meaning |
|------|---------|
| 0 | OK (all checks passed) |
| 2 | Missing fixture |
| 3 | Untracked fixture (not in git index) |
| 4 | Size issue (actual bytes differ from manifest or below fallback) |
| 5 | Multiple issue categories present (aggregation) |
| 6 | Hash mismatch (no override token / flag) |
| 7 | Manifest error (parse, schema, or hash computation failure) |
| 8 | Duplicate manifest entry |

Flags:

```text
  -MinBytes <n>             Global minimum size fallback when an item lacks recorded bytes
  -Quiet / -QuietOutput     Suppress non-error console lines
  -Json                     Emit single JSON object (suppresses human lines)
  -TestAllowFixtureUpdate   INTERNAL: ignore hash mismatches (used in tests)
  -DisableToken             INTERNAL: disable commit message token override for tests
```

JSON output fields:

```json
{
  "ok": true|false,
  "exitCode": <int>,
  "summary": "text",
  "issues": [ { type, ... } ],
  "manifestPresent": true|false,
  "fixtureCount": 2,
  "fixtures": ["VI1.vi","VI2.vi"],
  "checked": ["VI1.vi","VI2.vi"]
}
```

Issue objects may include:

- `missing` { fixture }
- `untracked` { fixture }
- `tooSmall` { fixture, length, min }
- `sizeMismatch` { fixture, actual, expected }
- `hashMismatch` { fixture, actual, expected }
- `manifestError` { }
- `duplicate` { path }
- `schema` { detail }

Update helper enhancements:

`tools/Update-FixtureManifest.ps1` now supports:

```text
  -Allow              Required (or -Force) to write new manifest
  -DryRun             Show whether an update is needed without writing
  -Output <file>      Alternate manifest path (default fixtures.manifest.json)
```

It records exact per-item `bytes`; rerun after intentional fixture changes.

## Quick Start

### Basic Usage

```yaml
jobs:
  compare:
    runs-on: [self-hosted, Windows]
    steps:
      - uses: actions/checkout@v5
      - name: Compare VIs
        id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
        with:
          base: path/to/VI1.vi
          head: path/to/VI2.vi
          fail-on-diff: true

      - name: Act on result
        if: steps.compare.outputs.diff == 'true'
        shell: pwsh
        run: |
          Write-Host 'Differences detected.'
```

### Action Inputs

- `base` (required): Path to base `.vi` file
- `head` (required): Path to head `.vi` file
- `lvComparePath` (optional): Full path to `LVCompare.exe` if not on `PATH`
- `lvCompareArgs` (optional): Extra CLI flags for `LVCompare.exe` (space-delimited; quotes supported)
- `fail-on-diff` (optional, default `true`): Fail the job if differences are found
- `working-directory` (optional): Directory to run the command from; relative `base`/`head` are resolved from here
- `loop-enabled` (optional, default `false`): Enable experimental loop mode for performance testing

### Action Outputs

- `diff`: `true|false` whether differences were detected (0 = no diff, 1 = diff)
- `exitCode`: Raw exit code from the CLI
- `cliPath`: Resolved path to the executable
- `command`: Exact command line executed (quoted) for auditing
- `compareDurationSeconds`: Elapsed execution time (float, seconds)
- `compareDurationNanoseconds`: High-resolution elapsed time in nanoseconds
- `compareSummaryPath`: Path to JSON summary file (comparison metadata)
- `shortCircuitedIdentical`: `true|false` short‑circuit when `base` and `head` resolve identically (no process spawned)

Loop mode outputs (when `loop-enabled: true`): `iterations`, `diffCount`, `errorCount`,
`averageSeconds`, `totalSeconds`, `p50`, `p90`, `p99`, `quantileStrategy`,
`streamingWindowCount`, `loopResultPath`, `histogramPath`.

See [`docs/action-outputs.md`](./docs/action-outputs.md) for complete output documentation.

### Exit Codes and Behavior

- **Exit code mapping**: 0 = no diff, 1 = diff detected, any other code = failure
- **Identical path short-circuit**: If `base` and `head` resolve to the exact same absolute
  path, the action skips invoking LVCompare and emits
  `shortCircuitedIdentical=true`, `diff=false`, `exitCode=0`.
- **Same filename / different directories**: LVCompare cannot compare two different VIs
  with the *same leaf filename*. The action fails early with an explanatory error instead
  of triggering an IDE dialog.

### Local Pester by Category

Run targeted test categories locally using file patterns and a separate results folder per category:

```powershell
# Dispatcher-focused tests
./Invoke-PesterTests.ps1 -IncludePatterns 'Invoke-PesterTests*Tests.ps1','PesterAvailability*Tests.ps1','PesterSummary*Tests.ps1','NestedDispatcher*Tests.ps1','Write-PesterSummaryToStepSummary*Tests.ps1' -ResultsPath tests/results/dispatcher

# Fixtures / validator
./Invoke-PesterTests.ps1 -IncludePatterns 'Fixtures*Tests.ps1','FixtureValidation*Tests.ps1','FixtureSummary.Tests.ps1','ViBinaryHandling.Tests.ps1' -ResultsPath tests/results/fixtures

# Schema checks
./Invoke-PesterTests.ps1 -IncludePatterns 'Schema*Tests.ps1','SchemaLite*Tests.ps1' -ResultsPath tests/results/schema

# CompareVI
./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI*Tests.ps1' -ResultsPath tests/results/comparevi

# Loop & metrics
./Invoke-PesterTests.ps1 -IncludePatterns 'Run-AutonomousIntegrationLoop*Tests.ps1','CompareLoop*Tests.ps1','LoopMetrics.Tests.ps1' -ResultsPath tests/results/loop

# Runbook
./Invoke-PesterTests.ps1 -IncludePatterns 'IntegrationRunbook.Tests.ps1' -ResultsPath tests/results/runbook

# Orchestrator / workflows
./Invoke-PesterTests.ps1 -IncludePatterns 'On-FixtureValidationFail.Tests.ps1','Workflow*Tests.ps1','Guard*Tests.ps1','AggregationHints*Tests.ps1','ArtifactTracking*Tests.ps1','FunctionShadowing*Tests.ps1','Args.Tokenization.Tests.ps1','Action.CompositeOutputs.Tests.ps1' -ResultsPath tests/results/orchestrator
```

See the CI version in the orchestrated workflow: `.github/workflows/ci-orchestrated.yml`.

### (Deprecated heading placeholder removed)

```yaml
  - name: Compare VIs
    id: compare
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
    with:
  base: VI1.vi
  head: VI1.vi  # Intentional identical path
      fail-on-diff: true

  - name: Handle identical-path short-circuit
    if: steps.compare.outputs.shortCircuitedIdentical == 'true'
    shell: pwsh
    run: |
      Write-Host 'Identical file comparison short-circuited; no diff expected.'

  - name: Handle real diff
    if: steps.compare.outputs.shortCircuitedIdentical != 'true' && steps.compare.outputs.diff == 'true'
    shell: pwsh
    run: |
      Write-Host 'Real differences detected.'
```

- **Always-emit outputs**: `diff`, `exitCode`, `cliPath`, `command` are always emitted
  even when the step fails, to support workflow branching and diagnostics.
- **Step summary**: A structured run report is appended to `$GITHUB_STEP_SUMMARY` with
  working directory, resolved paths, CLI path, command, exit code, and diff result.

## Advanced Configuration

For advanced configuration including lvCompareArgs recipes, working-directory usage, path resolution, and HTML report generation, see the **[Usage Guide](./docs/USAGE_GUIDE.md)**.

Tip: Environment variables quick reference moved to the **[Environment appendix](./docs/ENVIRONMENT.md)**.
Note: For CI integration test runs, consider setting CLEAN_AFTER=1, KILL_LEAKS=1, and `LEAK_GRACE_SECONDS`≈1.0 to avoid lingering LabVIEW/LVCompare processes; see Troubleshooting → Leak Detection and the Environment appendix for details.

## Loop Mode

The action supports an experimental loop mode for performance testing and stability analysis. For complete details on loop mode, percentile strategies, histogram generation, and the autonomous runner script, see the **[Loop Mode Guide](./docs/COMPARE_LOOP_MODULE.md)**.

**Quick example:**

```yaml
- name: Performance test loop
  uses: LabVIEW-Community-CI-CD/compare-vi-cli-action@v0.4.1
  with:
    base: VI1.vi
    head: VI2.vi
    loop-enabled: true
    loop-max-iterations: 100
    loop-interval-seconds: 0.1
    fail-on-diff: false
```

Loop mode outputs include: `iterations`, `diffCount`, `errorCount`, `averageSeconds`, `totalSeconds`, `p50`, `p90`, `p99`, and more.

### Autonomous Integration Loop Runner

```powershell
$env:LV_BASE_VI = 'VI1.vi'
$env:LV_HEAD_VI = 'VI2.vi'
$env:LOOP_SIMULATE = '1'
$env:LOOP_DIFF_SUMMARY_FORMAT = 'Html'
$env:LOOP_MAX_ITERATIONS = '15'
$env:LOOP_SNAPSHOT_EVERY = '5'
$env:LOOP_JSON_LOG = 'loop-events.ndjson'
$env:LOOP_EMIT_RUN_SUMMARY = '1'
pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

Excerpt output:

```text
=== Integration Compare Loop Result ===
VI1: VI1.vi
VI2: VI2.vi
Iterations: 15 (Diffs=15 Errors=0)
Latency p50/p90/p99: 0.005/0.006/0.007 s
Diff summary fragment emitted.
Run summary JSON: loop-run-summary.json
Snapshots NDJSON: loop-snapshots.ndjson
```

Structured events sample (`loop-events.ndjson` first lines):

```jsonc
{"timestamp":"2025-10-01T12:00:00.100Z","type":"plan","simulate":true,"dryRun":false,"maxIterations":15,"interval":0,"diffSummaryFormat":"Html"}
{"timestamp":"2025-10-01T12:00:00.250Z","type":"result","iterations":15,"diffs":15,"errors":0,"succeeded":true}
```

Event schema versioning:

- Each event now includes `"schema":"loop-script-events-v1"`.
- Meta events:
  - `type=meta action=create` on new log creation
  - `type=meta action=rotate` when rotation occurs (fields: `from`, `to`)
- Backward compatibility: future minor additions will retain existing fields; consumers should ignore unknown properties.

JSON Schemas:

- `docs/schemas/loop-script-events-v1.schema.json`
- `docs/schemas/loop-final-status-v1.schema.json`

Final status example minimal structure:

```jsonc
{
  "schema": "loop-final-status-v1",
  "timestamp": "2025-10-01T12:34:56.789Z",
  "iterations": 40,
  "diffs": 12,
  "errors": 0,
  "succeeded": true,
  "averageSeconds": 0.012,
  "totalSeconds": 0.55,
  "percentiles": { "p50": 0.010, "p90": 0.018, "p99": 0.024 },
  "histogram": [ { "Index":0, "Start":0, "End":1, "Count":40 } ],
  "diffSummaryEmitted": true,
  "basePath": "VI1.vi",
  "headPath": "VI2.vi"
}
```

GitHub Actions step example (simulated):

```yaml
  - name: Autonomous integration loop (simulated)
    shell: pwsh
    run: |
  $env:LV_BASE_VI = 'VI1.vi'
  $env:LV_HEAD_VI = 'VI2.vi'
      $env:LOOP_SIMULATE = '1'
      $env:LOOP_MAX_ITERATIONS = '30'
      $env:LOOP_INTERVAL_SECONDS = '0'
      $env:LOOP_DIFF_SUMMARY_FORMAT = 'Markdown'
      $env:LOOP_EMIT_RUN_SUMMARY = '1'
      pwsh -File scripts/Run-AutonomousIntegrationLoop.ps1
```

If `GITHUB_STEP_SUMMARY` is present and a diff summary is generated it is appended automatically.

Timing metrics

- Each invocation now records wall-clock execution time and surfaces it via:
  - Action output `compareDurationSeconds` (was `durationSeconds` in earlier versions)
  - Action output `compareDurationNanoseconds` (high-resolution; derived from Stopwatch ticks)
  - Step summary line `Duration (s): <value>`
  - Step summary line `Duration (ns): <value>`
  - PR comment and artifact workflow job summary include a combined line: `<seconds>s (<milliseconds> ms)` for quick readability
  - HTML report field (if you render a report via `Render-CompareReport.ps1` passing `-CompareDurationSeconds` or legacy alias `-DurationSeconds`)

Artifact publishing workflow

A dedicated workflow (`.github/workflows/compare-artifacts.yml`) runs the local action, generates:

- `compare-summary.json` (JSON metadata: base, head, exit code, diff, timing)
- `compare-report.html` (HTML summary rendered via `Render-CompareReport.ps1`)

and uploads them as artifacts. It also appends a timing block to the job summary:

```text
### Compare VI Timing

- Seconds: <seconds>

- Nanoseconds: <nanoseconds>
- Combined: <seconds>s (<ms> ms)
```

Use this workflow to retain comparison evidence on every push or pull request without failing the build on differences (it sets `fail-on-diff: false`).

Integration readiness

Use the helper script to assess prerequisites before enabling integration tests:

```powershell
./scripts/Test-IntegrationEnvironment.ps1 -JsonPath tests/results/integration-env.json
```

Exit code 0 means ready; 1 indicates missing prerequisites (non-fatal for CI gating).

Troubleshooting unknown exit codes

- The action treats 0 as no diff and 1 as diff. Any other exit code fails fast.
- Outputs are still set for diagnostics: `exitCode`, `cliPath`, `command`, and `diff=false`.
- Check $GITHUB_STEP_SUMMARY for a concise run report.

Smoke test workflow

- A manual workflow is provided at `.github/workflows/smoke.yml`.
- Trigger it with “Run workflow” and supply `base`, `head`, and optional `lvComparePath`/`lvCompareArgs`.
- It runs the local action (`uses: ./`) on a self-hosted Windows runner and prints outputs.

Marketplace

- Listing: Pending publication (use the [repository README](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action#readme) for latest instructions).
- After publication, update the badge/link to the final marketplace URL and ensure the README usage references the latest tag.

Notes

## For Developers

## Fixture Validation Delta (Trending)

The repository ships a helper script `tools/Diff-FixtureValidationJson.ps1` for **comparing two JSON snapshots** produced by `tools/Validate-Fixtures.ps1 -Json`.

Use cases:

- Detect introduction of new structural issue types (e.g., a first duplicate entry) between two commits.
- Generate a compact delta artifact for observability dashboards.
- Gate CI on unexpected structural regressions while allowing benign size/hash churn.

### Invocation

```powershell
pwsh -File tools/Validate-Fixtures.ps1 -Json > validate-current.json
# (Obtain or restore a previous snapshot as validate-prev.json)
pwsh -File tools/Diff-FixtureValidationJson.ps1 -Baseline validate-prev.json -Current validate-current.json > delta.json
```

Fail the build if a new structural issue category appears:

```powershell
pwsh -File tools/Diff-FixtureValidationJson.ps1 -Baseline validate-prev.json -Current validate-current.json -FailOnNewStructuralIssue
if ($LASTEXITCODE -eq 3) { throw 'New structural fixture issues detected.' }
```

### Exit Codes (Delta Script)

| Code | Meaning |
|------|---------|
| 0 | Success, no disallowed new structural issue categories |
| 2 | Input / parse error (missing files or invalid JSON) |
| 3 | New structural issue category detected and `-FailOnNewStructuralIssue` specified |

Structural issue categories monitored: `missing`, `untracked`, `hashMismatch`, `manifestError`, `duplicate`, `schema` (excludes `tooSmall`).

### Output JSON (Schemas `fixture-validation-delta-v1` / `fixture-validation-delta-v2`)

Key fields (see schema `docs/schemas/fixture-validation-delta-v1.schema.json`):

Two schema versions are supported:

- `fixture-validation-delta-v1` (default): Original unbounded integer deltas (only non-zero keys emitted in `deltaCounts`).
- `fixture-validation-delta-v2` (opt-in): Adds **bounded** numeric constraints (each delta in `deltaCounts` and `changes[].delta` must be between `-1000` and `1000`). This guards against pathological explosions in issue growth and surfaces out-of-range spikes early via schema-lite.

Opt-in to v2 emission by setting environment variable `DELTA_SCHEMA_VERSION=v2` or passing `-UseV2Schema` to `tools/Diff-FixtureValidationJson.ps1`.

Example (v1 style):

```jsonc
{
  "schema": "fixture-validation-delta-v1",
  "baselinePath": "validate-prev.json",
  "currentPath": "validate-current.json",
  "baselineOk": true,
  "currentOk": false,
  "deltaCounts": { "duplicate": 1 },
  "changes": [ { "category": "duplicate", "baseline": 0, "current": 1, "delta": 1 } ],
  "newStructuralIssues": [ { "category": "duplicate", "baseline": 0, "current": 1, "delta": 1 } ],
  "failOnNewStructuralIssue": true,
  "willFail": true
}
```

Example (v2 style identical structure – bounded values enforced by schema):

```jsonc
{
  "schema": "fixture-validation-delta-v2",
  "baselinePath": "validate-prev.json",
  "currentPath": "validate-current.json",
  "baselineOk": true,
  "currentOk": true,
  "deltaCounts": { "missing": 2 },
  "changes": [ { "category": "missing", "baseline": 0, "current": 2, "delta": 2 } ],
  "newStructuralIssues": [ { "category": "missing", "baseline": 0, "current": 2, "delta": 2 } ],
  "failOnNewStructuralIssue": false,
  "willFail": false
}
```

### Workflow Example (Delta Comparison)

```yaml
  - name: Validate fixtures (current)
    shell: pwsh
    run: pwsh -File tools/Validate-Fixtures.ps1 -Json -DisableToken > validate-current.json

  - name: Restore previous snapshot (cache)
    uses: actions/cache/restore@v4
    with:
      path: validate-prev.json
      key: fixture-validation-${{ github.sha }}
      restore-keys: |
        fixture-validation-

  - name: Diff against previous snapshot
    if: exists('validate-prev.json')
    shell: pwsh
    run: |
      pwsh -File tools/Diff-FixtureValidationJson.ps1 -Baseline validate-prev.json -Current validate-current.json -FailOnNewStructuralIssue > delta.json
      if ($LASTEXITCODE -eq 3) { Write-Host 'New structural issues introduced.'; exit 3 }

  - name: Save current snapshot for future runs
    uses: actions/cache/save@v4
    with:
      path: validate-current.json
      key: fixture-validation-${{ github.sha }}

  - name: Upload delta artifact
    if: exists('delta.json')
    uses: actions/upload-artifact@v4
    with:
      name: fixture-validation-delta
      path: delta.json
```

This pattern allows longitudinal tracking without hard-failing when no prior snapshot exists (first run).

### Fixture Validation Reporting Enhancements

The validate workflow now supports:

- `FAIL_ON_NEW_STRUCTURAL` (env) – set to `true` to fail the job when a new structural issue category first appears (duplicate, hashMismatch, schema, etc.).
- `SUMMARY_VERBOSE` (env) – set to `true` to expand the job summary with detailed change lists and per‑category structural deltas. (Can also be toggled via manual workflow dispatch input `summary-verbose`.)
- `DELTA_FORCE_V2` (env) – when set to `true`, the delta script unconditionally emits `fixture-validation-delta-v2` (bounded deltas) without requiring the `-UseV2Schema` switch. Useful once consumers have migrated and v1 is considered deprecated.
- Recursive schema-lite validation – `tools/Invoke-JsonSchemaLite.ps1` performs a lightweight recursive check of required fields, property types, array item types, `const`, `additionalProperties=false`, plus support for `enum`, `minimum`, and `maximum` (integers / numbers). This is intentionally minimal (no refs, no oneOf/anyOf) to stay dependency‑free.

Example snippet for enabling verbose summary & strict failure:

```yaml
env:
  FAIL_ON_NEW_STRUCTURAL: 'true'
  SUMMARY_VERBOSE: 'true'
```

### Enum, Range, additionalProperties, and Date-Time Validation (Schema-Lite)

When adding to a JSON schema consumed by `Invoke-JsonSchemaLite.ps1`, you can specify:

```jsonc
{
  "type": "object",
  "properties": {
    "status": { "type": "string", "enum": ["ok", "warn", "error"] },
    "retryCount": { "type": "integer", "minimum": 0, "maximum": 5 }
  },
  "required": ["status"]
}
```

You can now also use **object-form `additionalProperties`** to define a schema for arbitrary extra keys (recursively validated, including nested `enum`, `minimum`, `maximum`). Example:

```jsonc
{
  "type": "object",
  "properties": { "fixed": { "type": "string" } },
  "additionalProperties": { "type": "integer", "minimum": 0, "maximum": 10 }
}
```

Date-time format (`"format": "date-time"`) receives a light validation pass: it accepts either a native PowerShell `DateTime` (after JSON round-trip) or a basic ISO 8601 / RFC3339-style string matching `YYYY-MM-DDTHH:MM:SS`. (Timezone / fractional seconds currently not strictly validated—future extensions may tighten this.)

Violations surface as `[schema-lite] error:` lines and produce exit code `3`.

### Summary Artifact Upload

To retain the rendered summary as an artifact for external dashboards, append:

```yaml
  - name: Write fixture summary to file
    if: always()
    shell: pwsh
    run: |
      pwsh -File tools/Write-FixtureValidationSummary.ps1 -ValidationJson fixture-validation.json -DeltaJson fixture-validation-delta.json -SummaryPath fixture-summary.md

  - name: Upload fixture summary
    if: always() && hashFiles('fixture-summary.md') != ''
    uses: actions/upload-artifact@v4
    with:
      name: fixture-validation-summary
      path: fixture-summary.md
```

Set `SUMMARY_VERBOSE: 'true'` (or run the `Validate` workflow manually with the input `summary-verbose: true`) to enrich `fixture-summary.md` with detailed sections.

## Fixture Drift Composite Action (Validation + Artifacts + PR Comment)

This repository includes a local composite action to validate fixture integrity, orchestrate drift artifacts, upload them, write a job summary, and post a sticky PR comment with direct artifact download links.

- Action path: `./.github/actions/fixture-drift`
- Intended usage: in a Windows runner job on pull requests and manual dispatch.
- Use alongside branch protection to mark the job “Fixture Drift” as a required check.

Example workflow usage:

```yaml
name: Fixture Drift Validation
on:
  pull_request:
  workflow_dispatch:

jobs:
  validate:
    name: Fixture Drift
    runs-on: windows-latest
    permissions:
      actions: read
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - name: Fixture Drift Orchestrator
        uses: ./.github/actions/fixture-drift
        with:
          render-report: 'true'            # Generate compare-report.html when LVCompare is present
          comment-on-fail: 'true'          # Sticky PR comment on failure (skips forked PRs)
          upload-artifacts: 'true'         # Upload results (see only-upload-on-failure)
          only-upload-on-failure: 'true'   # Upload only when status != ok
          artifact-name: fixture-drift
          retention-days: '7'
```

Outputs (from the composite):

- `status` – `ok | drift | fail-structural | unknown`
- `summary_path` – absolute path to the `drift-summary.json` if available

To enforce as a required check:

1. Go to repository Settings → Branches → Branch protection rules.
2. Edit or create the rule for your main branch.
3. Add “Fixture Drift” to Required status checks.

Notes:

- LVCompare must exist at the canonical path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`.
- Direct artifact download URLs use the GitHub REST API and require `actions: read` permission.
- PR comments are skipped for forked PRs (no write permission).

### Make it a Required Check

To enforce Fixture Drift as a branch protection rule:

1. Open repository Settings → Branches → Branch protection rules.
2. Edit the rule for your main branch.
3. Enable “Require status checks to pass before merging”.
4. Add “Fixture Drift” to Required status checks.

Optional badge (replace workflow path if customized):

`[![Fixture Drift](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/fixture-drift.yml/badge.svg)](.github/workflows/fixture-drift.yml)`


For information on testing, building, documentation generation, and the release process, see the **[Developer Guide](./docs/DEVELOPER_GUIDE.md)**.

### Quick Links

- **Testing**: [Developer Guide - Testing](./docs/DEVELOPER_GUIDE.md#testing)
- **Building**: [Developer Guide - Building](./docs/DEVELOPER_GUIDE.md#building-and-documentation-generation)
- **Contributing**: [CONTRIBUTING.md](./CONTRIBUTING.md)

### Test Dispatcher JSON Summary

The test dispatcher emits a machine-readable JSON summary (schema v1.7.1) for integration with tooling and metrics. For complete documentation on the schema, optional blocks, and consumption guidance, see the [Developer Guide - Test Dispatcher Architecture](./docs/DEVELOPER_GUIDE.md#test-dispatcher-architecture).

The repository ships a PowerShell test dispatcher (`Invoke-PesterTests.ps1`) that emits
a machine‑readable JSON summary (`pester-summary.json`) for every run. This enables
downstream tooling (dashboards, PR annotations, quality gates) to consume stable fields
without scraping console text.

Schema files:

- Baseline (core fields) [`docs/schemas/pester-summary-v1_1.schema.json`](./docs/schemas/pester-summary-v1_1.schema.json)
- Current (adds optional context blocks) [`docs/schemas/pester-summary-v1_2.schema.json`](./docs/schemas/pester-summary-v1_2.schema.json)
- Latest (adds optional discovery block) [`docs/schemas/pester-summary-v1_5.schema.json`](./docs/schemas/pester-summary-v1_5.schema.json)

Validation tests:

- Baseline absence of optional blocks: [`tests/PesterSummary.Schema.Tests.ps1`](./tests/PesterSummary.Schema.Tests.ps1)
- Context emission (when opt-in flag used): [`tests/PesterSummary.Context.Tests.ps1`](./tests/PesterSummary.Context.Tests.ps1)

## Troubleshooting

For common issues including path resolution problems, exit code interpretation, performance tuning, and test environment setup, see the **[Troubleshooting Guide](./docs/TROUBLESHOOTING.md)**.

## Documentation

- **[Usage Guide](./docs/USAGE_GUIDE.md)** - Advanced configuration, lvCompareArgs recipes, path resolution
- **[Loop Mode Guide](./docs/COMPARE_LOOP_MODULE.md)** - Experimental loop mode for performance testing
- **[Developer Guide](./docs/DEVELOPER_GUIDE.md)** - Testing, building, and release process
- **[Troubleshooting Guide](./docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[Integration Tests](./docs/INTEGRATION_TESTS.md)** - Running tests with real LabVIEW
- **[Testing Patterns](./docs/TESTING_PATTERNS.md)** - Advanced test design patterns
- **[E2E Testing Guide](./docs/E2E_TESTING_GUIDE.md)** - End-to-end testing strategies
- **[Self-Hosted CI Setup](./docs/SELFHOSTED_CI_SETUP.md)** - Setting up self-hosted runners

## License

This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.

## Support and Contributing

For bug reports and feature requests, please use [GitHub Issues](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues).

For contributions, please read [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines and development workflow.
