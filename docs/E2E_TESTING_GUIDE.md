# End-to-End Testing Guide for Self-Hosted Windows Runner

This guide provides step-by-step instructions for performing end-to-end testing of the LabVIEW Compare VI CLI Action on a self-hosted Windows runner.

## Prerequisites

Before running end-to-end tests, ensure you have completed the setup in [SELFHOSTED_CI_SETUP.md](./SELFHOSTED_CI_SETUP.md):

- ✅ Self-hosted Windows runner installed and online
- ✅ LabVIEW 2025 Q3 installed with CLI at canonical path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
- ✅ PowerShell 7+ installed (`pwsh`)
- ✅ Repository variables configured:
  - `LV_BASE_VI` - Path to base test VI file
  - `LV_HEAD_VI` - Path to head test VI file (different from base)
- ✅ Repository secret configured:
- `GH_ADMIN_TOKEN` - Personal Access Token with `repo` and `actions:write` scopes

## Pre-Test Validation

### 1. Verify Runner Status

1. Navigate to repository Settings → Actions → Runners
2. Confirm your self-hosted runner shows as "Idle" or "Active"
3. Verify runner has labels: `self-hosted`, `Windows`, `X64`

### 2. Verify CLI Installation

On the self-hosted runner, open PowerShell and run:

```powershell
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
```

Expected output: `True`

### 3. Verify Test VI Files

On the self-hosted runner, run:

```powershell
# Check repository variables are set (from workflow environment)
$baseVi = [Environment]::GetEnvironmentVariable('LV_BASE_VI', 'Machine')
$headVi = [Environment]::GetEnvironmentVariable('LV_HEAD_VI', 'Machine')

Write-Host "LV_BASE_VI: $baseVi"
Write-Host "LV_HEAD_VI: $headVi"

# Or check the files directly if you know their paths
Test-Path 'C:\TestVIs\Empty.vi'
Test-Path 'C:\TestVIs\Modified.vi'
```

Expected output: Both should return `True`

## End-to-End Test Scenarios

### Test 1: Manual Integration Test Dispatch

**Purpose:** Verify the pester-selfhosted workflow runs successfully with Integration tests.

**Steps:**

1. Navigate to Actions → "Pester (self-hosted, real CLI)"
2. Click "Run workflow"
3. Select branch: `copilot/fix-d73c7249-f485-4f8a-ad53-449df8d32b8a`
4. Set `include_integration`: `true`
5. Click "Run workflow"

**Expected Results:**

✅ **Environment validation step passes:**

```text
Environment validation passed:
  - CLI: C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
  - LV_BASE_VI: C:\TestVIs\Empty.vi
  - LV_HEAD_VI: C:\TestVIs\Modified.vi
```

✅ **Pester installation succeeds:**

```text
Installing Pester v5.4.0...
Pester v5.4.0 installed successfully
```

✅ **All tests pass:**

```text
Tests Passed: 24, Failed: 0, Skipped: 0
```

✅ **Artifacts uploaded:**

- `pester-selfhosted-results/pester-results.xml`
- `pester-selfhosted-results/pester-summary.txt`

### Test 2: PR Label-Triggered Integration Test

**Purpose:** Verify automatic Integration tests trigger when PR is labeled.

**Steps:**

1. Navigate to Pull Requests
2. Open PR #[your PR number]
3. Add label: `test-integration`
4. Wait for workflow to trigger automatically

**Expected Results:**

✅ **Workflow triggers within 1-2 minutes**

✅ **Environment validation passes**

✅ **Integration tests run and pass:**

```text
Describing Invoke-CompareVI (real CLI on self-hosted)
  [+] has required files present
  [+] exit 0 => diff=false when base=head
  [+] exit 1 => diff=true when base!=head
  [+] fail-on-diff=true throws after outputs are written for diff
```

✅ **PR comment posted with results:**

```text
### Pester integration test results (label-triggered)

Tests Passed: 24
Tests Failed: 0
Tests Skipped: 0
```

### Test 3: PR Comment-Triggered Test

**Purpose:** Verify `/run pester-selfhosted` command works from PR comments.

**Steps:**

1. Navigate to Pull Requests
2. Open PR #[your PR number]
3. Add a comment: `/run pester-selfhosted`
4. Wait for command dispatcher to process

**Expected Results:**

✅ **Command dispatcher responds within 30 seconds:**

```text
Dispatched 'pester-selfhosted' on `copilot/fix-d73c7249-f485-4f8a-ad53-449df8d32b8a` via `.github/workflows/pester-selfhosted.yml`.
- include_integration: `true`
```

✅ **Workflow runs successfully** (same as Test 1)

### Test 4: Smoke Test with Repository Variables

**Purpose:** Verify the smoke test workflow runs with repository-configured VI files.

**Steps:**

1. Add label `smoke` to the PR
2. Wait for automatic trigger

**Expected Results:**

✅ **Environment validation passes**

✅ **Action executes successfully:**

```text
diff      = true (or false, depending on your test VIs)
exitCode  = 1 (or 0)
cliPath   = C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe
command   = "C:\Program Files\..." "C:\TestVIs\Empty.vi" "C:\TestVIs\Modified.vi"
```

✅ **PR comment posted with results**

### Test 5: Smoke Test with Custom VI Files

**Purpose:** Verify smoke test works with custom VI file paths via PR comment.

**Steps:**

1. Prepare two different VI files on your self-hosted runner (e.g., `C:\CustomTest\FileA.vi` and `C:\CustomTest\FileB.vi`)
2. Add a PR comment:

   ```text
   /run smoke base=C:\CustomTest\FileA.vi head=C:\CustomTest\FileB.vi
   ```

3. Wait for dispatcher to trigger workflow

**Expected Results:**

✅ **Workflow dispatches with custom inputs**

✅ **Action runs with specified VI files**

✅ **Results posted to PR comment**

### Test 6: Environment Validation Failure (Negative Test)

**Purpose:** Verify helpful error messages when environment is misconfigured.

**Steps:**

1. Temporarily stop your self-hosted runner
2. Try to trigger a workflow (label PR with `test-integration`)
3. Restart runner and remove the label

**Expected Results:**

✅ **Workflow stays in "Queued" state** (waiting for runner)

✅ **Clear message in workflow UI:** "Waiting for a runner to pick up this job..."

**Alternative - Test with Missing CLI:**

If you want to test the validation error messages:

1. Temporarily rename the CLI file on the runner:

   ```powershell
   Rename-Item 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe' 'LVCompare.exe.backup'
   ```

2. Trigger workflow (e.g., add `test-integration` label)
3. Workflow should fail with clear error:

   ```text
   Environment validation failed:
     - LVCompare.exe not found at canonical path: C:\Program Files\...
     - Install LabVIEW 2025 Q3 or later with LabVIEW Compare CLI
   
   See docs/SELFHOSTED_CI_SETUP.md for setup instructions
   ```

4. Restore the CLI file:

   ```powershell
   Rename-Item 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe.backup' 'LVCompare.exe'
   ```

## Validation Checklist

After running all test scenarios, verify:

- [ ] Manual workflow dispatch works for pester-selfhosted
- [ ] PR label `test-integration` triggers Integration tests automatically
- [ ] PR label `smoke` triggers smoke tests automatically
- [ ] PR comment `/run pester-selfhosted` dispatches workflow
- [ ] PR comment `/run smoke` with custom paths works
- [ ] Environment validation catches missing CLI
- [ ] Environment validation catches missing environment variables
- [ ] Test results are uploaded as artifacts
- [ ] Test results are posted as PR comments (when GH_ADMIN_TOKEN is configured)
- [ ] All Integration tests pass on self-hosted runner
- [ ] Smoke tests complete successfully

## Troubleshooting

### Workflow Stays in "Queued"

**Cause:** Runner offline or labels mismatch

**Solution:**

1. Check runner status in Settings → Actions → Runners
2. Verify runner labels match workflow requirements: `[self-hosted, Windows, X64]`
3. Restart runner service if needed

### Environment Validation Fails

**Cause:** Missing CLI or environment variables

**Solution:**

1. Follow detailed steps in [SELFHOSTED_CI_SETUP.md](./SELFHOSTED_CI_SETUP.md)
2. Verify CLI at canonical path
3. Check repository variables are set correctly
4. Ensure VI files exist at specified paths

### Tests Fail with "VI not found"

**Cause:** Incorrect repository variable paths

**Solution:**

1. Verify `LV_BASE_VI` and `LV_HEAD_VI` variables point to valid files
2. Check file permissions (runner service account must have read access)
3. Update repository variables if paths changed

### PR Comments Don't Trigger Workflows

**Cause:** Missing GH_ADMIN_TOKEN or insufficient permissions

**Solution:**

1. Verify `GH_ADMIN_TOKEN` secret is set in repository settings
2. Ensure PAT has `repo` and `actions:write` scopes
3. Verify commenter has OWNER, MEMBER, or COLLABORATOR association
4. Check command-dispatch workflow logs for errors

## Performance Benchmarks

Record these metrics during testing for baseline performance:

- **Unit tests (GitHub-hosted):** ~15-20 seconds
- **Integration tests (self-hosted):** ~30-60 seconds (depends on runner)
- **Smoke test (self-hosted):** ~20-40 seconds (depends on VI complexity)
- **Environment validation:** ~2-5 seconds
- **Command dispatcher:** ~5-10 seconds to dispatch

## Next Steps After E2E Testing

Once all tests pass:

1. **Document results:**
   - Take screenshots of successful workflow runs
   - Note any performance issues
   - Document any environment-specific configurations

2. **Update team:**
   - Share E2E test results with team
   - Document any discovered issues
   - Update runbook if needed

3. **Enable for production:**
   - Merge PR if all tests pass
   - Update main branch documentation
   - Train team on PR comment commands

4. **Monitor:**
   - Watch for workflow failures
   - Check runner health weekly
   - Update test VI files quarterly

## Contact

For issues or questions:

- Check [SELFHOSTED_CI_SETUP.md](./SELFHOSTED_CI_SETUP.md) for setup details
- Review [IMPLEMENTATION_STATUS.md](./releases/IMPLEMENTATION_STATUS.md) for feature status
- Create a GitHub issue with test logs and environment details

