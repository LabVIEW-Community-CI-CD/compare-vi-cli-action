# Developer Guide

This guide covers testing, building, and contributing to the compare-vi-cli-action.

## Table of Contents

- [Testing](#testing)
- [Building and Documentation Generation](#building-and-documentation-generation)
- [Release Process](#release-process)
- [Test Dispatcher Architecture](#test-dispatcher-architecture)
- [Continuous Development Workflow](#continuous-development-workflow)

## Testing

This repository includes a comprehensive Pester test suite for both unit and integration testing.

### Running Unit Tests

Unit tests run without requiring LabVIEW or LVCompare installed:

```powershell
# Fast unit tests only
./Invoke-PesterTests.ps1

# Alternative using tools directory
pwsh -File ./tools/Run-Pester.ps1
```

Unit tests produce artifacts under `tests/results/` including:

- NUnit XML results
- JSON summary
- Test timing metrics

### Running Integration Tests

Integration tests require:

- LVCompare.exe at canonical path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- Environment variables: `LV_BASE_VI` and `LV_HEAD_VI` pointing to test `.vi` files

```powershell
# Set up environment
$env:LV_BASE_VI = 'C:\Path\To\VI1.vi'
$env:LV_HEAD_VI = 'C:\Path\To\VI2.vi'

# Run with integration tests
./Invoke-PesterTests.ps1 -IncludeIntegration true

# Alternative
pwsh -File ./tools/Run-Pester.ps1 -IncludeIntegration
```

See [Integration Tests Guide](./INTEGRATION_TESTS.md) for detailed prerequisites and skip behavior.

Environment variables quick reference: see [Environment appendix](./ENVIRONMENT.md) for toggles used by the dispatcher (leak detection, cleanup), loop mode, and fixture validation.

### Test Design Patterns

For advanced test patterns including:

- Nested dispatcher handling
- Function shadowing vs mocks
- Per-test function shadowing
- Skip gating

See [Testing Patterns](./TESTING_PATTERNS.md).

### Schema Validation

For validating JSON/NDJSON schemas (Run Summary, Snapshot v2, Loop Events, Final Status), see [Schema Helper](./SCHEMA_HELPER.md).

### CI Workflows

The repository uses several GitHub Actions workflows:

- `.github/workflows/test-pester.yml` - Unit tests on GitHub-hosted Windows runners
- `.github/workflows/pester-selfhosted.yml` - Integration tests on self-hosted runners with real CLI
- `.github/workflows/pester-diagnostics-nightly.yml` - Nightly synthetic failure validation (non-blocking)

**Trigger workflows via PR comments:**

- `/run unit`
- `/run mock`
- `/run smoke`
- `/run pester-selfhosted`

## Building and Documentation Generation

The action documentation is auto-generated from `action.yml`.

### Prerequisites

```bash
npm install
```

### Build and Generate

```bash
# Build the action
npm run build

# Generate output documentation
npm run generate:outputs
```

This regenerates [`action-outputs.md`](./action-outputs.md) with all inputs and outputs based on the `action.yml` specification.

### Validation

Run linters before committing:

```bash
# Markdown linting
npm run lint

# Action linting (requires actionlint installed)
actionlint
```

## Release Process

1. **Update CHANGELOG.md** with release notes for the new version
2. **Tag the release** using semantic versioning (e.g., `v0.4.1`)
3. **Push the tag** - The release workflow reads `CHANGELOG.md` to generate release notes
4. **Update README examples** to reference the latest stable tag
5. **Verify marketplace listing** is updated

### Release Workflow

The release workflow (`.github/workflows/release.yml`) automatically:

- Builds the action
- Generates release notes from CHANGELOG.md
- Publishes to GitHub Marketplace

## Test Dispatcher Architecture

The test dispatcher (`Invoke-PesterTests.ps1`) provides advanced features for test execution.

### Pester Test Dispatcher JSON Summary (Schema v1.7.1)

The dispatcher emits a machine-readable JSON summary with versioned schema for integration with tooling, diagnostics, and metrics aggregation.

#### Core Fields

```jsonc
{
  "schema": "compare-vi-test-dispatcher-summary-v1",
  "version": "1.7.1",
  "timestamp": "2025-10-01T08:15:27.123Z",
  "tests": 134,
  "passed": 129,
  "failed": 5,
  "errors": 0,
  "skipped": 2,
  "durationSeconds": 74.10,
  "status": "FAIL",
  "discoveryFailures": 0
}
```

#### Optional Context Blocks

Enable with `-EmitContext`:

```jsonc
{
  "context": {
    "pesterVersion": "5.7.1",
    "powershellVersion": "7.4.12",
    "os": "Windows 10.0.22631",
    "hostname": "runner-abc123"
  }
}
```

#### Optional Timing Block

Enable with `-EmitTimingDetail`:

```jsonc
{
  "timing": {
    "startTime": "2025-10-01T08:15:00.000Z",
    "endTime": "2025-10-01T08:16:14.123Z",
    "durationSeconds": 74.123,
    "p50": 525.7,
    "p95": 2353,
    "max": 15509.43
  }
}
```

#### Optional Stability Block

Enable with `-EmitStability`:

```jsonc
{
  "stability": {
    "flakySuspectCount": 0,
    "flakyConfirmedCount": 0
  }
}
```

#### Optional Discovery Diagnostics

Enable with `-EmitDiscoveryDetail`:

```jsonc
{
  "discovery": {
    "suppressionEnabled": true,
    "rawMatches": 3,
    "postSuppressionCount": 0
  }
}
```

#### Optional Outcome Classification

Enable with `-EmitOutcome`:

```jsonc
{
  "outcome": {
    "classification": "SUCCESS"
  }
}
```

#### Optional Aggregation Hints

Enable with `-EmitAggregationHints`:

```jsonc
{
  "aggregationHints": {
    "buildDurationMs": 123.45,
    "slowThreshold": 2000,
    "slowTests": [
      {
        "name": "builds aggregation hints under threshold",
        "durationMs": 2091.66,
        "exceedsThreshold": true
      }
    ]
  }
}
```

### Consumption Guidance

- Treat `schema` and `version` as mandatory; fail pipelines if absent or unexpected.
- Optional blocks are present only when explicitly requested via dispatcher flags.
- Field order within blocks is stable for version parsing; new fields are always additive.
- `discoveryFailures > 0` indicates test discovery issues; investigate even if `passed` tests ran.

## Continuous Development Workflow

For rapid iteration, use the file watcher to re-execute tests when files change:

```powershell
# Basic watch mode
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart

# Advanced: Run only changed tests
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart -ChangedOnly -InferTestsFromSource

# With delta tracking and flaky recovery
pwsh -File ./tools/Watch-Pester.ps1 -RunAllOnStart -DeltaJsonPath tests/results/delta.json -RerunFailedAttempts 2
```

### Key Watch Options

- `-RunAllOnStart` - Perform an initial full run
- `-ChangedOnly` - Skip runs if no directly changed or inferred test files detected
- `-InferTestsFromSource` - Map changed module/script files to corresponding test files
- `-BeepOnFail` - Emit audible alert on failures
- `-ShowFailed` - List failing test names after summary
- `-RerunFailedAttempts <N>` - Automatically re-run failing tests (flaky mitigation)
- `-DeltaJsonPath <file>` - Write JSON artifact with run statistics and deltas
- `-DeltaHistoryPath <file>` - Append each run as NDJSON for historical tracking

### Delta JSON Schema

```jsonc
{
  "timestamp": "2025-10-01T15:15:27.123Z",
  "status": "FAIL",
  "stats": { "tests": 121, "failed": 6, "skipped": 15 },
  "previous": { "tests": 121, "failed": 7, "skipped": 15 },
  "delta": { "tests": 0, "failed": -1, "skipped": 0 },
  "classification": "improved",
  "flaky": {
    "enabled": true,
    "attempts": 2,
    "recoveredAfter": 1,
    "initialFailedFiles": 3
  },
  "runSequence": 5
}
```

**Classification Logic:**

- `baseline` - First run (no previous stats)
- `improved` - Failed count decreased
- `worsened` - Failed count increased
- `unchanged` - Failed count unchanged

### Quick Verification Tool

For quick local verification without running full Pester:

```powershell
# Default - creates temp files
./tools/Quick-VerifyCompare.ps1

# Same file (expect no diff)
./tools/Quick-VerifyCompare.ps1 -Same -ShowSummary

# Specific files
./tools/Quick-VerifyCompare.ps1 -Base path\to\A.vi -Head path\to\B.vi
```

## Contributing Guidelines

See [`../CONTRIBUTING.md`](../CONTRIBUTING.md) for:

- Coding standards
- PR requirements
- Branch protection rules
- Marketplace listing guidelines

## Related Documentation

- [Integration Tests](./INTEGRATION_TESTS.md) - Detailed test prerequisites
- [Testing Patterns](./TESTING_PATTERNS.md) - Advanced test design patterns
- [Schema Helper](./SCHEMA_HELPER.md) - JSON schema validation
- [E2E Testing Guide](./E2E_TESTING_GUIDE.md) - End-to-end testing
- [Usage Guide](./USAGE_GUIDE.md) - Advanced action configuration
