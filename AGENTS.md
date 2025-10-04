# Developer Guide: Local Integration with Pester Test Dispatcher

## Overview

This guide helps developers integrate and run the Pester test dispatcher (`Invoke-PesterTests.ps1`) locally on their development machine. The dispatcher is designed for self-hosted Windows runners but can be used locally for testing and development.

## Quick Start

### Prerequisites

1. **PowerShell 7+**

   ```powershell
   # Check your PowerShell version
   $PSVersionTable.PSVersion
   
   # Should be 7.0 or higher
   ```

2. **Pester v5.0.0+**

   ```powershell
   # Check if Pester is installed
   Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge '5.0.0' }
   
   # Install Pester if needed
   Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser
   ```

3. **LabVIEW Compare CLI** (for Integration tests only)
   - Required path: `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`
   - Only needed if running Integration-tagged tests

### Basic Usage

#### Run Unit Tests Only (No CLI Required)

```powershell
# From repository root
./Invoke-PesterTests.ps1
```

This runs all tests except those tagged with `Integration`.

### Function Shadowing Approach (Updated)

Tests that need to simulate different installed Pester versions now use simple inline function shadowing per test (defining a temporary `Get-Module` function inside the `It` block and removing it afterwards). A previously introduced reusable helper module was removed due to restoration complexity in nested dispatcher scenarios. The inline pattern proved more reliable and easier to reason about:

```powershell
It 'simulates older Pester' {
  function Get-Module { param([switch]$ListAvailable,[string]$Name)
    if ($ListAvailable -and $Name -eq 'Pester') { return [pscustomobject]@{ Name='Pester'; Version=[version]'4.10.1' } }
    Microsoft.PowerShell.Core\Get-Module @PSBoundParameters
  }
  Test-PesterAvailable | Should -BeFalse
  Remove-Item Function:Get-Module -ErrorAction SilentlyContinue
}
```

Key guidelines:

1. Define the shadowed function inside each `It` block (keeps scope predictable).
2. Always remove it with `Remove-Item Function:Get-Module` at the end of the block.
3. Avoid cross-test reuse—duplication is intentional for isolation.
4. Prefer returning a `[pscustomobject]` with `Name` and `Version` for probe realism.
5. Keep shadows minimal—only handle the parameter shapes your probe calls.

This change eliminates brittle global or helper-managed restoration logic and ensures nested dispatcher invocations do not leak overridden functions back to the outer test context.

#### Run All Tests (Including Integration)

```powershell
# From repository root
./Invoke-PesterTests.ps1 -IncludeIntegration true
### Quick Local Smoke Test (No Integration)

Use the helper script to validate the dispatcher wiring without touching CI step summaries:

```powershell
# From repository root
./tools/Quick-DispatcherSmoke.ps1

# Optional flags
./tools/Quick-DispatcherSmoke.ps1 -Raw     # also prints raw JSON
./tools/Quick-DispatcherSmoke.ps1 -Keep    # keeps temp folder for inspection
```

Or a safe single-call one-liner using a scriptblock (avoids nested shells and quoting pitfalls):

```powershell
pwsh -NoLogo -NoProfile -Command '& {
  $ErrorActionPreference = ''Stop''
  $tmp  = [IO.Path]::Combine([IO.Path]::GetTempPath(),[guid]::NewGuid().ToString())
  $t    = Join-Path $tmp ''tests''
  $res  = Join-Path $tmp ''results''
  New-Item -ItemType Directory -Path $t -Force | Out-Null
  $mini = @(
    ''Describe ''''Mini'''' {'',
    ''  It ''''passes'''' { 1 | Should -Be 1 }'',
    ''}''
  )
  Set-Content -LiteralPath (Join-Path $t ''Mini.Tests.ps1'') -Value ($mini -join [Environment]::NewLine) -Encoding UTF8
  $root = (Get-Location).Path
  $env:DISABLE_STEP_SUMMARY = ''1''
  & (Join-Path $root ''Invoke-PesterTests.ps1'') -TestsPath $t -ResultsPath $res | Out-Null
  $sp = Join-Path $res ''pester-summary.json''
  if (Test-Path $sp) { Get-Content -LiteralPath $sp -Raw | Write-Output }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}'
```

```

**Note:** Requires LabVIEW CLI and environment variables `LV_BASE_VI` and `LV_HEAD_VI` to be set.

#### Custom Test Path

```powershell
# Run tests from a specific directory
./Invoke-PesterTests.ps1 -TestsPath "tests" -ResultsPath "my-results"
```

## Local Development Workflow

### 1. Initial Setup

```powershell
# Clone the repository
git clone https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git
cd compare-vi-cli-action

# Verify PowerShell version
pwsh --version

# Install Pester if needed
Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser

# Verify Pester installation
Get-Module -ListAvailable Pester
```

### 2. Running Tests During Development

#### Quick Test Run (Unit Tests Only)

```powershell
# Run all unit tests
./Invoke-PesterTests.ps1

# Or use the local dispatcher with auto-install
./tools/Run-Pester.ps1
```

#### Test Specific Files

```powershell
# Run only CompareVI tests
./tools/Run-Pester.ps1 -Path tests/CompareVI.Tests.ps1

# Run dispatcher tests
./tools/Run-Pester.ps1 -Path tests/Invoke-PesterTests.Tests.ps1
```

#### Debugging Failed Tests

```powershell
# Run with verbose output
./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results

# Results will be in:
# - tests/results/pester-results.xml (NUnit XML)
# - tests/results/pester-summary.txt (Human-readable summary)

# View the summary
Get-Content tests/results/pester-summary.txt
```

### 3. Integration Testing Setup

For Integration tests that require the LabVIEW CLI:

```powershell
# Set environment variables
$env:LV_BASE_VI = "C:\Path\To\Your\TestVIs\VI1.vi"
$env:LV_HEAD_VI = "C:\Path\To\Your\TestVIs\VI2.vi"

# Verify CLI exists
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'

# Run integration tests
./Invoke-PesterTests.ps1 -IncludeIntegration true
```

## Dispatcher Architecture

### Dispatcher Comparison

| Feature | `Invoke-PesterTests.ps1` | `tools/Run-Pester.ps1` |
|---------|-------------------------|------------------------|
| Location | Repository root | `tools/` directory |
| Use Case | Self-hosted runners, local testing | GitHub-hosted runners, local dev |
| Pester Install | Assumes pre-installed | Auto-installs if needed |
| Parameter Style | Named parameters | Switch parameters |
| Output Format | Color-coded, structured | Standard output |
| Error Handling | Comprehensive validation | Basic validation |

### When to Use Each Dispatcher

**Use `Invoke-PesterTests.ps1` when:**

- Testing the self-hosted runner workflow locally
- You want detailed, color-coded output
- Pester is already installed
- You need parameter flexibility

**Use `tools/Run-Pester.ps1` when:**

- Quick local testing during development
- You don't have Pester installed (auto-installs)
- You want minimal setup

## Common Scenarios

### Scenario 1: Test a New Feature

```powershell
# 1. Create your test file in tests/
New-Item tests/MyFeature.Tests.ps1

# 2. Write your tests (see examples in existing test files)

# 3. Run tests to verify
./Invoke-PesterTests.ps1

# 4. Check results
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ All tests passed!" -ForegroundColor Green
} else {
    Write-Host "❌ Tests failed. Check tests/results/ for details" -ForegroundColor Red
}
```

### Scenario 2: Debug Failing Tests

```powershell
# Run with detailed output
./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results

# Open results in your editor
code tests/results/pester-results.xml
code tests/results/pester-summary.txt

# Or use Pester's built-in debugging
./tools/Run-Pester.ps1 -Path tests/MyFeature.Tests.ps1 -Output Detailed
```

### Scenario 3: Validate Dispatcher Changes

```powershell
# Run the dispatcher's own test suite
./Invoke-PesterTests.ps1 -TestsPath tests -ResultsPath tests/results

# Or specifically run dispatcher tests
./tools/Run-Pester.ps1 -Path tests/Invoke-PesterTests.Tests.ps1

# The dispatcher tests validate:
# - Parameter handling
# - Path resolution
# - Error handling
# - Output formatting
# - Exit codes
```

### Scenario 4: Test Before Pushing

```powershell
# Run all unit tests (fast, no CLI needed)
./Invoke-PesterTests.ps1

# If you have LabVIEW CLI, run integration tests too
$env:LV_BASE_VI = "C:\TestVIs\Empty.vi"
$env:LV_HEAD_VI = "C:\TestVIs\Modified.vi"
./Invoke-PesterTests.ps1 -IncludeIntegration true

# Verify all workflows pass actionlint
./actionlint .github/workflows/*.yml

# Verify markdown files pass linting
markdownlint-cli2 "**/*.md"
```

## Troubleshooting

### Pester Not Found

**Error:** `Pester v5+ not found`

**Solution:**

```powershell
Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser
```

### Tests Directory Not Found

**Error:** `Tests directory not found`

**Solution:**

```powershell
# Ensure you're running from repository root
cd /path/to/compare-vi-cli-action

# Or specify full path
./Invoke-PesterTests.ps1 -TestsPath "C:\path\to\compare-vi-cli-action\tests"
```

### Integration Tests Fail

**Error:** `LVCompare.exe not found` or `LV_BASE_VI not set`

**Solution:**

```powershell
# 1. Verify CLI installation
Test-Path 'C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe'

# 2. Set environment variables
$env:LV_BASE_VI = "C:\TestVIs\VI1.vi"
$env:LV_HEAD_VI = "C:\TestVIs\VI2.vi"

# 3. Run without integration tests if CLI not available
./Invoke-PesterTests.ps1 -IncludeIntegration false
```

### PowerShell Version Error

**Error:** `#Requires -Version 7.0`

**Solution:**

```powershell
# Download and install PowerShell 7+
# https://github.com/PowerShell/PowerShell/releases

# Or use the local dispatcher which supports PS 5.1+
./tools/Run-Pester.ps1
```

## Advanced Usage

### Custom Test Filtering

```powershell
# The dispatcher supports Pester's tag-based filtering
# Tags are defined in test files like: -Tag 'Unit', 'Integration'

# Run only Unit tests (default)
./Invoke-PesterTests.ps1 -IncludeIntegration false

# Run all tests including Integration
./Invoke-PesterTests.ps1 -IncludeIntegration true
```

### Parallel Test Execution

```powershell
# For faster test execution, you can run multiple test files in parallel
# This requires modifying the dispatcher or using Pester directly

# Example: Run Pester with parallel execution
Import-Module Pester
$config = New-PesterConfiguration
$config.Run.Path = 'tests'
$config.Filter.ExcludeTag = 'Integration'
$config.Output.Verbosity = 'Detailed'
# Note: Parallel execution requires Pester 5.2+
Invoke-Pester -Configuration $config
```

### CI/CD Simulation

```powershell
# Simulate the self-hosted runner workflow locally

# 1. Ensure environment matches runner
$env:LV_BASE_VI = $vars.LV_BASE_VI
$env:LV_HEAD_VI = $vars.LV_HEAD_VI

# 2. Run the dispatcher as the workflow does
./Invoke-PesterTests.ps1 `
  -TestsPath tests `
  -IncludeIntegration 'true' `
  -ResultsPath tests/results

# 3. Verify exit code
if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ CI simulation passed"
} else {
    Write-Host "❌ CI simulation failed with exit code: $LASTEXITCODE"
}
```

## Output Interpretation

### Dispatcher Output Structure

```text
=== Pester Test Dispatcher ===
Script Version: 1.0.0
PowerShell Version: 7.x.x

Configuration:
  Tests Path: tests
  Include Integration: false
  Results Path: tests/results

Resolved Paths:
  Script Root: C:\...\compare-vi-cli-action
  Tests Directory: C:\...\compare-vi-cli-action\tests
  Results Directory: C:\...\compare-vi-cli-action\tests\results

Found X test file(s) in tests directory
Results directory ready: ...

Checking for Pester availability...
Pester module found: v5.x.x
Using Pester v5.x.x

Configuring Pester...
  Excluding Integration-tagged tests
  Output Verbosity: Detailed
  Result Format: NUnitXml

Executing Pester tests...
----------------------------------------
[Pester test output here]
----------------------------------------

Test execution completed in X.XX seconds

Parsing test results...

=== Pester Test Summary ===
Total Tests: X
Passed: X
Failed: 0
Errors: 0
Skipped: X
Duration: X.XXs

Summary written to: ...\pester-summary.txt
Results written to: ...\pester-results.xml

✅ All tests passed!
```

### Exit Codes

- `0`: All tests passed
- `1`: Test failures, errors, or execution problems

### Result Files

1. **`tests/results/pester-results.xml`**
   - NUnit XML format
   - Compatible with CI/CD tools
   - Contains detailed test results

2. **`tests/results/pester-summary.txt`**
   - Human-readable summary
   - Quick overview of test results
   - Includes duration and counts

## Integration with IDEs

### Visual Studio Code

```jsonc
// .vscode/tasks.json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Run Unit Tests",
      "type": "shell",
      "command": "pwsh",
      "args": ["-File", "./Invoke-PesterTests.ps1"],
      "group": {
        "kind": "test",
        "isDefault": true
      },
      "presentation": {
        "reveal": "always",
        "panel": "new"
      }
    },
    {
      "label": "Run All Tests",
      "type": "shell",
      "command": "pwsh",
      "args": [
        "-File",
        "./Invoke-PesterTests.ps1",
        "-IncludeIntegration",
        "true"
      ],
      "group": "test"
    }
  ]
}
```

### PowerShell ISE

```powershell
# Add to your profile for quick access
function Run-UnitTests {
    Push-Location "C:\path\to\compare-vi-cli-action"
    ./Invoke-PesterTests.ps1
    Pop-Location
}

function Run-AllTests {
    Push-Location "C:\path\to\compare-vi-cli-action"
    ./Invoke-PesterTests.ps1 -IncludeIntegration true
    Pop-Location
}

# Usage:
# Run-UnitTests
# Run-AllTests
```

## Best Practices

1. **Run tests before committing**

   ```powershell
   ./Invoke-PesterTests.ps1
   if ($LASTEXITCODE -eq 0) { git commit -m "Your message" }
   ```

2. **Keep tests fast**
   - Unit tests should run in seconds
   - Use Integration tag for slow tests
   - Mock external dependencies

3. **Isolate test data**
   - Use `$TestDrive` for temporary files
   - Don't rely on files outside the repository
   - Clean up after tests

4. **Document test requirements**
   - Tag Integration tests appropriately
   - Document required environment variables
   - Provide mock/stub options

5. **Review test output**
   - Check `tests/results/` after runs
   - Investigate warnings and skipped tests
   - Ensure tests are actually running

## Contributing

When adding new tests:

1. Follow existing test patterns
2. Use descriptive test names
3. Tag appropriately (`Unit` or `Integration`)
4. Add test documentation
5. Verify tests pass locally before PR

Example test structure:

```powershell
Describe 'MyFeature' -Tag 'Unit' {
  BeforeAll {
    # Setup
  }
  
  Context 'When condition X' {
    It 'should do Y' {
      # Test implementation
    }
  }
  
  AfterAll {
    # Cleanup
  }
}
```

## Additional Resources

- [Pester Documentation](https://pester.dev/)
- [Repository README](./README.md)
- [Dispatcher Architecture](./PESTER_DISPATCHER_REFINEMENT.md)
- [Self-Hosted CI Setup](./docs/SELFHOSTED_CI_SETUP.md)
- [Implementation Status](./IMPLEMENTATION_STATUS.md)
- [JSON Schema Helper (Test Shapes)](./docs/SCHEMA_HELPER.md)

## Support

For issues or questions:

1. Check this guide and documentation
2. Review existing test examples
3. Search GitHub issues
4. Create a new issue with:
   - Output from `./Invoke-PesterTests.ps1`
   - PowerShell version (`$PSVersionTable`)
   - Pester version (`Get-Module Pester`)
   - Steps to reproduce
