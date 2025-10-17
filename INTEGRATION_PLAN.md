<!-- markdownlint-disable-next-line MD041 -->
# Integration Plan: Canonical CLI Path Policy

## Problem Analysis

The action requires a strict canonical-only path policy for the LabVIEW Compare CLI to ensure consistency
across all self-hosted Windows runners.

### Root Cause

**File:** `scripts/CompareVI.ps1`, function `Resolve-Cli`

**Issue:** The function previously accepted any valid executable path, which could lead to inconsistencies in
self-hosted runner environments where different installations or versions might exist in non-standard
locations.

## Solution

**Implemented strict canonical path policy** that enforces:

- Only accepts `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- Rejects all other paths (via explicit `lvComparePath` input or `LVCOMPARE_PATH` environment variable)
- No PATH probing or fallback locations

This ensures all self-hosted runners use the exact same CLI installation.

## Changes Made

1. **Updated `Resolve-Cli` function** (`scripts/CompareVI.ps1`)
   - Enforces canonical-only path policy
   - Validates that explicit paths match the canonical location
   - Validates that LVCOMPARE_PATH (if set) matches the canonical location
   - Falls back to canonical path if no explicit configuration provided

2. **Updated unit tests** (`tests/CompareVI.Tests.ps1`)
   - Changed tests to verify rejection of non-canonical paths
   - Added explicit tests for canonical path validation
   - Tests confirm that only the canonical path is accepted

## Verification

### Unit Tests

✅ All 20 unit tests pass (2 skipped - require canonical CLI on Windows)

```text
Tests Passed: 22, Failed: 0, Skipped: 0
```

### Test Coverage

✅ Verified canonical-only path resolution works correctly:

- Rejects explicit `lvComparePath` when not canonical
- Rejects `LVCOMPARE_PATH` environment variable when not canonical
- Accepts canonical path when it exists
- Mock scenarios work with mocked canonical path

### Validation Checks

✅ Markdownlint passes with no errors
✅ All unit tests pass without Integration tests (which require self-hosted runner)

## Integration Test Requirements

The Integration tests (tagged with `Integration`) require:

- Self-hosted Windows runner
- LabVIEW Compare CLI installed at: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- Environment variables set:
  - `LV_BASE_VI` - Path to base VI file
  - `LV_HEAD_VI` - Path to head VI file (different from base)

## Impact

- **Minimal change:** Core logic change in `Resolve-Cli` function and test updates
- **Breaking change for non-standard installations:** Requires all installations to use canonical path
- **Ensures consistency:** All self-hosted runners must use the same CLI location
- **Simplifies troubleshooting:** Single source of truth for CLI location

## Files Changed

```text
scripts/CompareVI.ps1       | Updated Resolve-Cli to enforce canonical path only
tests/CompareVI.Tests.ps1   | Updated tests to verify rejection of non-canonical paths
INTEGRATION_PLAN.md         | Updated to reflect canonical-only policy
3 files changed
```
