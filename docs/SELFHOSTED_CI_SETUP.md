# Self-Hosted Windows Runner CI/CD Setup Guide

## Overview

This guide explains how to set up continuous integration for the LabVIEW Compare VI CLI Action using self-hosted Windows runners with the actual LabVIEW Compare CLI.

## Prerequisites

### Software Requirements

1. **Windows Operating System**
   - Windows Server 2019 or later (recommended for runners)
   - Windows 10/11 (acceptable for testing)

2. **PowerShell 7+**
   - Required for running tests and workflows
   - Install from: <https://github.com/PowerShell/PowerShell/releases>
   - Verify with: `pwsh --version`

3. **LabVIEW Compare CLI**
   - Must be installed at canonical path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
   - Part of LabVIEW 2025 Q3 or later installation
   - Verify with: `Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'`

4. **GitHub Actions Runner**
   - Self-hosted runner installed and configured
   - Runner labels must include: `self-hosted`, `Windows`, `X64`

5. **Pester v5+**
   - PowerShell testing framework
   - Required for self-hosted runners
   - Install manually: `Install-Module -Name Pester -MinimumVersion 5.0.0 -Force`
   - Auto-installed by GitHub-hosted runner workflows

## Repository Configuration

### Required Repository Variables

Configure the following variables in your repository settings (Settings → Secrets and variables → Actions → Variables):

| Variable Name | Description | Example Value |
|---------------|-------------|---------------|
| `LV_BASE_VI` | Path to a test VI file (base) | `C:\TestVIs\Empty.vi` |
| `LV_HEAD_VI` | Path to a test VI file (head, different from base) | `C:\TestVIs\Modified.vi` |

**Important:** These VI files must exist on the self-hosted runner and should be different from each other to properly test diff detection.

### Required Repository Secrets

| Secret Name | Description |
|-------------|-------------|
| `GH_ADMIN_TOKEN` | Personal Access Token with `repo` and `actions:write` scopes for workflow dispatch from PR comments |

## Setting Up Test VI Files

On your self-hosted runner, create test VI files:

1. Create a directory for test files:

   ```powershell
   New-Item -ItemType Directory -Path "C:\TestVIs" -Force
   ```

2. Copy or create two different VI files:
   - One for base comparisons (e.g., `Empty.vi`)
   - One for head comparisons with differences (e.g., `Modified.vi`)

3. Set repository variables to point to these files

## Continuous Integration Workflows

### Automatic PR Testing

The following workflows run automatically on PRs:

#### 1. Validate Workflow (`validate.yml`)

- **Trigger:** Every PR commit
- **Runner:** `ubuntu-latest`
- **Purpose:** Markdown and workflow linting
- **No self-hosted runner required**

#### 2. Unit Tests (`test-pester.yml`)

- **Trigger:** Manual dispatch or PR comment `/run unit`
- **Runner:** `windows-latest` (GitHub-hosted)
- **Purpose:** Run mock-based unit tests
- **No self-hosted runner required**

#### 3. Integration Tests on Label (`pester-integration-on-label.yml`)

- **Trigger:** PR labeled with `test-integration`, PR synchronize, or reopened
- **Runner:** `[self-hosted, Windows, X64]`
- **Purpose:** Run Integration tests with real CLI
- **Requires:** Self-hosted runner with LabVIEW CLI and test VIs

#### 4. Smoke Tests on Label (`smoke-on-label.yml`)

- **Trigger:** PR labeled with `smoke`
- **Runner:** `[self-hosted, Windows, X64]`
- **Purpose:** Run smoke tests with real VI comparisons
- **Requires:** Self-hosted runner with LabVIEW CLI and test VIs

#### 5. VI Compare on Label (`vi-compare-pr.yml`)

- **Trigger:** PR labeled with `vi-compare`, PR synchronize, or reopened
- **Runner:** `[self-hosted, Windows, X64]`
- **Purpose:** Generate comprehensive VI comparison reports (single run + loop mode)
- **Requires:** Self-hosted runner with LabVIEW CLI
- **Outputs:**
  - HTML comparison reports
  - JSON summaries
  - Markdown PR comments with results
  - Latency metrics and percentiles (loop mode)

### Manual Testing via PR Comments

Team members with appropriate permissions can trigger workflows via PR comments:

| Command | Workflow | Runner | Description |
|---------|----------|--------|-------------|
| `/run unit` | `test-pester.yml` | GitHub-hosted | Unit tests only (mock-based) |
| `/run pester-selfhosted` | `pester-selfhosted.yml` | Self-hosted | Integration tests with real CLI |
| `/run smoke pr=NUMBER` | `smoke.yml` | Self-hosted | Manual smoke test with custom VIs |

**Example:**

```text
/run pester-selfhosted
```

This will dispatch the self-hosted Pester workflow on the PR's branch.

### Manual Workflow Dispatch

Workflows can also be triggered manually from the Actions tab:

1. **pester-selfhosted.yml**
   - Navigate to Actions → "Pester (self-hosted, real CLI)"
   - Click "Run workflow"
   - Choose branch
   - Set `include_integration` to `true` or `false`

2. **smoke.yml**
   - Navigate to Actions → "Smoke"
   - Click "Run workflow"
   - Provide VI file paths and options

## Test Structure

### Test Dispatcher Architecture

The repository uses a layered test execution architecture:

#### Local Dispatcher (`tools/Run-Pester.ps1`)

Used by GitHub-hosted workflows and manual local testing:

- **Used by:** `test-pester.yml`, `pester-integration-on-label.yml`
- **Purpose:** Handles Pester module discovery/installation and test execution
- **Features:** Auto-installs Pester if not found, supports exclude tags

#### Root Dispatcher (`Invoke-PesterTests.ps1`)

Used directly by self-hosted runner workflows:

- **Used by:** `pester-selfhosted.yml` (called directly via PowerShell)
- **Purpose:** Entry point for self-hosted test execution
- **Assumption:** Pester v5+ is pre-installed on the self-hosted runner
- **Parameters:**
  - `TestsPath` - Path to tests directory (default: `tests`)
  - `IncludeIntegration` - Include Integration-tagged tests (default: `false`)
  - `ResultsPath` - Path to results directory (default: `tests/results`)

**When to use which:**

- Self-hosted runners with real CLI → Call `Invoke-PesterTests.ps1` directly
- GitHub-hosted runners or local → Use `tools/Run-Pester.ps1` directly

### Unit Tests (No CLI Required)

**Files:**

- `tests/CompareVI.Tests.ps1` - Core behavior tests
- `tests/CompareVI.InputOutput.Tests.ps1` - I/O validation tests

**Features:**

- Mock-based execution (no real CLI needed)
- Tests canonical path enforcement
- Tests error handling and output generation
- Runs on GitHub-hosted Windows runners

**Run locally:**

```powershell
./tools/Run-Pester.ps1
```

### Integration Tests (Real CLI Required)

**File:** `tests/CompareVI.Integration.Tests.ps1`

**Features:**

- Tagged with `Integration` for conditional execution
- Requires real LabVIEW CLI at canonical path
- Requires `LV_BASE_VI` and `LV_HEAD_VI` environment variables
- Validates actual CLI exit codes and behavior

**Run locally on self-hosted runner:**

```powershell
$env:LV_BASE_VI = "C:\TestVIs\Empty.vi"
$env:LV_HEAD_VI = "C:\TestVIs\Modified.vi"
./tools/Run-Pester.ps1 -IncludeIntegration
```

## Troubleshooting

### Integration Tests Fail with "LVCompare.exe not found"

**Cause:** CLI not installed at canonical path

**Solution:**

1. Verify LabVIEW Compare CLI is installed:

   ```powershell
   Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'
   ```

2. If not found, install LabVIEW 2025 Q3 or later
3. Alternative installations are not supported due to canonical path policy

### Integration Tests Fail with "Base VI not found" or "Head VI not found"

**Cause:** Repository variables not set or VI files don't exist on runner

**Solution:**

1. Verify environment variables are set:

   ```powershell
   $env:LV_BASE_VI
   $env:LV_HEAD_VI
   ```

2. Check files exist:

   ```powershell
   Test-Path $env:LV_BASE_VI
   Test-Path $env:LV_HEAD_VI
   ```

3. Update repository variables if paths are incorrect

### Workflow Dispatch Fails from PR Comments

**Cause:** Missing `GH_ADMIN_TOKEN` secret or insufficient permissions

**Solution:**

1. Verify `GH_ADMIN_TOKEN` secret is set in repository settings
2. Ensure PAT has `repo` and `actions:write` scopes
3. Only OWNER, MEMBER, or COLLABORATOR can trigger workflows

### Self-Hosted Runner Not Picking Up Jobs

**Cause:** Runner not properly labeled or not online

**Solution:**

1. Verify runner is online in Settings → Actions → Runners
2. Check runner has labels: `self-hosted`, `Windows`, `X64`
3. Restart runner service if needed

## Continuous Integration Best Practices

### For Development

1. **Run unit tests locally** before pushing:

   ```powershell
   ./tools/Run-Pester.ps1
   ```

2. **Test with Integration** when changing CLI interaction:

   ```powershell
   ./tools/Run-Pester.ps1 -IncludeIntegration
   ```

3. **Use PR comments** for quick validation:
   - `/run unit` - Fast feedback on logic changes
   - `/run pester-selfhosted` - Full validation with real CLI

### For Pull Requests

1. **Label PRs appropriately:**
   - Add `test-integration` label for Integration test coverage
   - Add `smoke` label for smoke test validation

2. **Review test results** in PR checks and artifacts

3. **Address failures** before merging

### For Releases

1. Unit tests must pass on GitHub-hosted runners
2. Integration tests should pass on self-hosted runners
3. Smoke tests validate end-to-end functionality
4. All linting checks (markdown, actionlint) must pass

## Monitoring and Maintenance

### Regular Checks

- **Weekly:** Verify self-hosted runner is online and responsive
- **Monthly:** Update Pester module if new version available
- **Quarterly:** Review and update test VI files for comprehensive coverage

### Runner Health

Monitor runner logs for:

- Disk space warnings
- Unexpected job failures
- Performance degradation

### Test VI Maintenance

Ensure test VI files remain:

- Different from each other (for diff detection)
- Valid and loadable by LabVIEW CLI
- Representative of typical use cases

## Additional Resources

- [LabVIEW Compare CLI Documentation](https://www.ni.com/docs/en-US/bundle/labview/page/compare-vi-cli.html)
- [GitHub Actions Self-Hosted Runners](https://docs.github.com/en/actions/hosting-your-own-runners)
- [Pester Testing Framework](https://pester.dev/)
- [PowerShell 7 Documentation](https://docs.microsoft.com/en-us/powershell/)

## Support

For issues or questions:

1. Check existing GitHub Issues
2. Review this documentation
3. Create a new issue with:
   - Runner environment details
   - Test output/logs
   - Steps to reproduce
