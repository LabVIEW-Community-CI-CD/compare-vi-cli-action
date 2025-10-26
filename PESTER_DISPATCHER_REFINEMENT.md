<!-- markdownlint-disable-next-line MD041 -->
# Pester Test Dispatcher Architecture

## Overview

This document describes the Pester test execution architecture, featuring a dual-dispatcher pattern for
running tests on both GitHub-hosted and self-hosted runners.

## Changes Made

### 1. Root-Level Test Dispatcher (`Invoke-PesterTests.ps1`)

**Purpose:** Entry point for self-hosted runner test execution via `pester-selfhosted.yml` workflow.

**Location:** Repository root

**Key Features:**

- Accepts parameters for flexible test execution:
  - `TestsPath` (default: `tests`)
  - `IncludeIntegration` (default: `false`)
  - `ResultsPath` (default: `tests/results`)
- Assumes the policy Pester version (currently v5.7.1) is pre-installed on self-hosted runners
- Generates NUnit XML and summary text files
- Provides detailed progress logging

**Usage:**

```powershell
# Called directly by pester-selfhosted.yml workflow
./Invoke-PesterTests.ps1 -TestsPath tests -IntegrationMode include -ResultsPath tests/results
```

### 2. Local Test Dispatcher (`tools/Run-Pester.ps1`)

**Purpose:** Direct test execution for GitHub-hosted workflows and local development.

**Usage:**

```powershell
# Unit tests only
./tools/Run-Pester.ps1

# Include Integration tests
./tools/Run-Pester.ps1 -IncludeIntegration
```

**Features:**

- Auto-discovers and installs Pester if not found
- Used by `test-pester.yml` and `pester-integration-on-label.yml`
- No external dependencies required

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Workflow Dispatch                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ├─────────────────────────────────┐
                              │                                 │
                    ┌─────────▼──────────┐        ┌────────────▼──────────┐
                    │  GitHub-Hosted     │        │  Self-Hosted Windows   │
                    │  (windows-latest)  │        │  [self-hosted, Win]    │
                    └─────────┬──────────┘        └────────────┬──────────┘
                              │                                 │
                    ┌─────────▼──────────┐        ┌────────────▼──────────┐
                    │  test-pester.yml   │        │ pester-selfhosted.yml │
                    │  (direct call)     │        │   (direct call)        │
                    └─────────┬──────────┘        └────────────┬──────────┘
                              │                                 │
                    ┌─────────▼──────────┐        ┌────────────▼──────────┐
                    │ tools/Run-Pester   │        │ Invoke-PesterTests.ps1 │
                    │   .ps1             │        │ (repository root)      │
                    └─────────┬──────────┘        └────────────┬──────────┘
                              │                                 │
                              └─────────────┬───────────────────┘
                                            │
                                  ┌─────────▼──────────┐
                                  │  Pester v5+ Engine │
                                  └─────────┬──────────┘
                                            │
                                  ┌─────────▼──────────┐
                                  │  tests/*.Tests.ps1 │
                                  └────────────────────┘
```

## Workflow Integration

### Self-Hosted Runner Workflow (`pester-selfhosted.yml`)

Calls the dispatcher directly without external action dependencies:

```yaml
- name: Run Pester tests via local dispatcher
  shell: pwsh
  run: |
    ./Invoke-PesterTests.ps1 `
      -TestsPath tests `
      -IncludeIntegration '${{ inputs.include_integration }}' `
```

### GitHub-Hosted Workflow (`test-pester.yml`)

Directly calls the local dispatcher:

```yaml
- name: Run unit tests
  shell: pwsh
  run: |
    if ('${{ inputs.include_integration }}' -ieq 'true') {
      ./tools/Run-Pester.ps1 -IncludeIntegration
    } else {
      ./tools/Run-Pester.ps1
    }
```

## Prerequisites

### For Self-Hosted Runners

- **Pester v5.7.1** must be pre-installed
  - Windows (elevated PowerShell):
    `Install-Module -Name Pester -RequiredVersion 5.7.1 -Force`
  - Windows (current user):
    `Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force`
  - macOS/Linux (elevated):
    `sudo pwsh -NoLogo -NoProfile -Command "Install-Module -Name Pester -RequiredVersion 5.7.1 -Force"`
  - macOS/Linux (current user):
    `pwsh -NoLogo -NoProfile -Command "Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force"`
  - Verify: `Get-Module -ListAvailable Pester`
- PowerShell 7+
- LabVIEW Compare CLI at canonical path (for Integration tests)
- Repository variables: `LV_BASE_VI`, `LV_HEAD_VI`

### For GitHub-Hosted Runners

- Pester is auto-installed by the workflow
- No additional setup required

## Testing the Setup

### Manual Dispatch

1. Navigate to Actions → "Pester (self-hosted, real CLI)"
2. Click "Run workflow"
3. Set `include_integration` to `true` or `false`
4. Run and verify artifacts are uploaded

### PR Comment Trigger

Comment on a PR:

```text
/run pester-selfhosted
```

Verifies:

- Command dispatcher workflow triggers correctly
- Open-source action is invoked
- Dispatcher script executes
- Results are uploaded as artifacts

## Validation Checklist

- [x] Root dispatcher created at `Invoke-PesterTests.ps1`
- [x] Dispatcher parameters match open-source action interface
- [x] Documentation updated (SELFHOSTED_CI_SETUP.md, IMPLEMENTATION_STATUS.md)
- [x] Workflow comments clarify dispatcher delegation
- [x] Markdown linting passes
- [x] Actionlint passes on all workflows
- [x] .gitignore updated to exclude development tools
- [ ] Integration test execution on self-hosted runner (requires hardware)
- [ ] Validation with real LabVIEW CLI (requires self-hosted setup)

## Benefits

1. **Clear Separation of Concerns:**
   - GitHub-hosted workflows use self-contained local dispatcher
   - Self-hosted workflows delegate to open-source shared action

2. **Consistent Interface:**
   - Both dispatchers accept similar parameters
   - Both generate standard NUnit XML output

3. **Maintainability:**
   - Open-source action handles environment validation
   - Repository-specific dispatcher focuses on test execution
   - Documented delegation pattern prevents confusion

4. **Flexibility:**
   - Can run tests locally with either dispatcher
   - Can trigger via workflow dispatch or PR comments
   - Supports both unit and integration tests

## Troubleshooting

### Dispatcher Not Found

**Symptom:** Open-source action fails with "script not found"

**Solution:** Ensure `Invoke-PesterTests.ps1` exists at repository root

### Pester Not Found

**Symptom:** Dispatcher fails with "Pester v5.7.1 not found"

**Solution:** Install the policy version using the option that matches your runner access:

```powershell
# Windows (elevated PowerShell)
Install-Module -Name Pester -RequiredVersion 5.7.1 -Force

# Windows (current user only)
Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force

# macOS / Linux (elevated)
sudo pwsh -NoLogo -NoProfile -Command "Install-Module -Name Pester -RequiredVersion 5.7.1 -Force"

# macOS / Linux (current user)
pwsh -NoLogo -NoProfile -Command "Install-Module -Name Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force"
```

### Parameter Mismatch

**Symptom:** Dispatcher receives unexpected parameter values

**Solution:** Verify open-source action passes parameters as strings, not booleans

## References

- [Self-Hosted CI/CD Setup Guide](./docs/SELFHOSTED_CI_SETUP.md)
- [Implementation Status](./IMPLEMENTATION_STATUS.md)
- [End-to-End Testing Guide](./docs/E2E_TESTING_GUIDE.md)
- [JSON/NDJSON Schema Helper (Test Shapes)](./docs/SCHEMA_HELPER.md)
- [Open-Source Actions Repository](https://github.com/LabVIEW-Community-CI-CD/open-source)
