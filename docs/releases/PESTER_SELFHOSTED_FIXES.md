# Pester Self-Hosted Runner Setup and Fixes

## Summary of Fixes Applied

### 1. Fixed Markdown Linting Errors

**File:** `.copilot-instructions.md`

**Problem:** The file had duplicate content, missing blank lines, and bare URLs causing 13 markdown lint errors.

**Fix:** Cleaned up the file to have proper structure with:

- Single occurrence of each section
- Proper heading hierarchy
- Blank lines around lists and code blocks
- URLs enclosed in angle brackets
- No multiple consecutive blank lines

**Result:** All markdown linting errors fixed (0 errors).

### 2. Fixed test-pester.yml Workflow Parameter Passing

**File:** `.github/workflows/test-pester.yml`

**Problem:** The workflow was passing parameters to `Run-Pester.ps1` using incorrect hashtable syntax:

```powershell
./tools/Run-Pester.ps1 @{
  IncludeIntegration = $include
}
```

This doesn't work because the hashtable is not being splatted (missing `@` operator) and the script expects a switch parameter.

**Fix:** Changed to proper conditional invocation:

```powershell
$include = '${{ inputs.include_integration }}' -ieq 'true'
if ($include) {
  ./tools/Run-Pester.ps1 -IncludeIntegration
} else {
  ./tools/Run-Pester.ps1
}
```

**Result:** Tests now run correctly with proper parameter passing.

## Integration Tests for Self-Hosted Windows Runners

The Integration tests (`tests/CompareVI.Integration.Tests.ps1`) are designed to run on self-hosted Windows runners with the actual LabVIEW Compare CLI installed.

### Requirements

1. **PowerShell 7+**: The test file has `#Requires -Version 7.0`

2. **Canonical LVCompare.exe Path**: Must be installed at:

   ```powershell
   C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
   ```

3. **Environment Variables**: Must be set (via GitHub Actions repository/organization variables):
   - `LV_BASE_VI`: Full path to a base VI file for testing
   - `LV_HEAD_VI`: Full path to a different VI file (for diff testing)

4. **Self-Hosted Runner**: Tagged with `[self-hosted, Windows, X64]`

### Test Coverage

The Integration tests verify:

1. **Required files present**: Checks that CLI and test VI files exist
2. **Exit code 0 (no diff)**: Compares the same VI file twice, expects `Diff = false`
3. **Exit code 1 (diff detected)**: Compares two different VI files, expects `Diff = true`
4. **fail-on-diff behavior**: Verifies that outputs are written before throwing when diffs are detected

### Running Integration Tests

#### Via Workflow Dispatch

1. Go to Actions → "Pester (self-hosted, real CLI)"
2. Click "Run workflow"
3. Set `include_integration` to `true`
4. Click "Run workflow"

#### Via PR Comment

Comment on a PR:

```bash
/run pester-selfhosted
```

This will dispatch the `pester-selfhosted.yml` workflow with `include_integration=true`.

#### Via Label

Add the `test-integration` label to a PR to trigger integration tests automatically.

### Validation Status

- ✅ Unit tests pass (20 passed, 2 skipped on non-Windows)
- ✅ Markdown linting passes (0 errors)
- ✅ Actionlint passes (0 errors)
- ✅ Workflow parameter passing fixed
- ⏸️ Integration tests require self-hosted Windows runner with LabVIEW CLI

## Next Steps

To fully enable Integration testing:

1. **Set up self-hosted Windows runner** with:
   - Windows OS
   - PowerShell 7+
   - LabVIEW Compare CLI installed at canonical path
   - Runner labeled with `[self-hosted, Windows, X64]`

2. **Configure repository variables**:
   - `LV_BASE_VI`: Path to a test VI file
   - `LV_HEAD_VI`: Path to a different test VI file

3. **Verify Integration tests** by manually dispatching the `pester-selfhosted.yml` workflow

## Files Modified

- `.copilot-instructions.md` - Fixed markdown linting errors
- `.github/workflows/test-pester.yml` - Fixed parameter passing to Run-Pester.ps1

## Test Results

### Unit Tests (Mock-based, no CLI)

```text
Tests Passed: 20, Failed: 0, Skipped: 2
```

### Linting

```text
Markdown: 0 errors
Actionlint: 0 errors
```

All non-integration tests pass successfully. Integration tests are ready to run on properly configured self-hosted Windows runners.
