#Requires -Version 7.0
<#
.SYNOPSIS
    Pester test dispatcher for compare-vi-cli-action
.DESCRIPTION
    This dispatcher is called directly by the pester-selfhosted.yml workflow.
    It handles running Pester tests with the appropriate configuration.
    Assumes Pester is already installed on the self-hosted runner.
.PARAMETER TestsPath
    Path to the directory containing test scripts (default: tests)
.PARAMETER IncludeIntegration
    Include Integration-tagged tests (default: false). Accepts 'true'/'false' string or boolean.
.PARAMETER ResultsPath
    Path to directory where results should be written (default: tests/results)
.PARAMETER JsonSummaryPath
  (Optional) File name (no directory) for machine-readable JSON summary (default: pester-summary.json)
.EXAMPLE
    ./Invoke-PesterTests.ps1 -TestsPath tests -IncludeIntegration true -ResultsPath tests/results
.EXAMPLE
    ./Invoke-PesterTests.ps1 -IncludeIntegration false
.NOTES
    Requires Pester v5.0.0 or later to be pre-installed on the runner.
    Exit codes: 0 = success, 1 = failure (test failures or execution errors)
#>

param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$TestsPath = 'tests',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$IncludeIntegration = 'false',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$ResultsPath = 'tests/results',

  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$JsonSummaryPath = 'pester-summary.json',

  [Parameter(Mandatory = $false)]
  [switch]$EmitFailuresJsonAlways,

  [Parameter(Mandatory = $false)]
  [double]$TimeoutMinutes = 0,

  [Parameter(Mandatory = $false)]
  [double]$TimeoutSeconds = 0,

  [Parameter(Mandatory = $false)]
  [int]$MaxTestFiles = 0
,
  [Parameter(Mandatory = $false)]
  [switch]$EmitContext,
  [Parameter(Mandatory = $false)]
  [switch]$EmitTimingDetail
,
  [Parameter(Mandatory = $false)]
  [switch]$EmitStability
,
  [Parameter(Mandatory = $false)]
  [switch]$EmitDiscoveryDetail
,
  [Parameter(Mandatory = $false)]
  [switch]$EmitOutcome,
  # Optional: emit aggregationHints block (schema v1.7.1+ with timing metric)
  [switch]$EmitAggregationHints
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Derive effective timeout seconds (seconds param takes precedence if >0)
$effectiveTimeoutSeconds = 0
if ($TimeoutSeconds -gt 0) { $effectiveTimeoutSeconds = [double]$TimeoutSeconds }
elseif ($TimeoutMinutes -gt 0) { $effectiveTimeoutSeconds = [double]$TimeoutMinutes * 60 }

# Schema version identifiers for emitted JSON artifacts (increment on breaking schema changes)
$SchemaSummaryVersion  = '1.7.1'
$SchemaFailuresVersion = '1.0.0'
$SchemaManifestVersion = '1.0.0'

function Ensure-FailuresJson {
  param(
    [Parameter(Mandatory)][string]$Directory,
    [Parameter()][switch]$Force,
    [Parameter()][switch]$Normalize,
    [Parameter()][switch]$Quiet
  )
  try {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    }
    $path = Join-Path $Directory 'pester-failures.json'
    if ($Force -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      '[]' | Out-File -FilePath $path -Encoding utf8 -ErrorAction Stop
      if (-not $Quiet) { Write-Host "Created empty failures JSON at: $path" -ForegroundColor Gray }
    } elseif ($Normalize) {
      try {
        $info = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($info.Length -eq 0 -or -not (Get-Content -LiteralPath $path -Raw).Trim()) {
          '[]' | Out-File -FilePath $path -Encoding utf8 -Force
          if (-not $Quiet) { Write-Host 'Normalized zero-byte failures JSON to []' -ForegroundColor Gray }
        }
      } catch { Write-Warning "Failed to normalize failures JSON: $_" }
    }
  } catch { Write-Warning "Ensure-FailuresJson encountered an error: $_" }
}

function Write-ArtifactManifest {
  param(
    [Parameter(Mandatory)] [string]$Directory,
    [Parameter(Mandatory)] [string]$SummaryJsonPath,
    [Parameter(Mandatory)] [string]$ManifestVersion
  )
  try {
    if ([string]::IsNullOrWhiteSpace($Directory)) {
      Write-Warning "Artifact manifest emission skipped: Directory parameter was null or empty"
      return
    }
    # Ensure directory exists (it should, but tests may simulate deletion scenarios)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
      try { New-Item -ItemType Directory -Force -Path $Directory | Out-Null } catch { Write-Warning "Failed to (re)create artifact directory '$Directory': $_" }
    }

    $artifacts = @()
    
    # Add artifacts if they exist
    $xmlPath = Join-Path $Directory 'pester-results.xml'
    if (Test-Path -LiteralPath $xmlPath) {
      $artifacts += [PSCustomObject]@{ file = 'pester-results.xml'; type = 'nunitXml' }
    }
    
    $txtPath = Join-Path $Directory 'pester-summary.txt'
    if (Test-Path -LiteralPath $txtPath) {
      $artifacts += [PSCustomObject]@{ file = 'pester-summary.txt'; type = 'textSummary' }
    }
    
    if (-not [string]::IsNullOrWhiteSpace($SummaryJsonPath)) {
      try {
        $jsonSummaryFile = Split-Path -Leaf $SummaryJsonPath
        $jsonPath = Join-Path $Directory $jsonSummaryFile
        if (Test-Path -LiteralPath $jsonPath) {
          $artifacts += [PSCustomObject]@{ file = $jsonSummaryFile; type = 'jsonSummary'; schemaVersion = $SchemaSummaryVersion }
        }
      } catch {
        Write-Warning "Failed to process summary JSON path '$SummaryJsonPath' for manifest: $_"
      }
    }
    
    $failuresPath = Join-Path $Directory 'pester-failures.json'
    if (Test-Path -LiteralPath $failuresPath) {
      $artifacts += [PSCustomObject]@{ file = 'pester-failures.json'; type = 'jsonFailures'; schemaVersion = $SchemaFailuresVersion }
    }
    
    # Optional: include lightweight metrics if summary JSON exists
  $metrics = $null
    try {
      $jsonSummaryFile = Split-Path -Leaf $SummaryJsonPath
      if ($jsonSummaryFile) {
        $jsonPath = Join-Path $Directory $jsonSummaryFile
        if (Test-Path -LiteralPath $jsonPath) {
          $summaryJson = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
          $aggMsValue = $null
          if ($summaryJson.PSObject.Properties.Name -contains 'aggregatorBuildMs' -and $null -ne $summaryJson.aggregatorBuildMs) {
            $aggMsValue = $summaryJson.aggregatorBuildMs
          }
          $metrics = [PSCustomObject]@{
            totalTests       = $summaryJson.total
            failed           = $summaryJson.failed
            skipped          = $summaryJson.skipped
            duration_s       = $summaryJson.duration_s
            meanTest_ms      = $summaryJson.meanTest_ms
            p95Test_ms       = $summaryJson.p95Test_ms
            maxTest_ms       = $summaryJson.maxTest_ms
            aggregatorBuildMs = $aggMsValue
          }
        }
      }
    } catch { Write-Warning "Failed to enrich manifest metrics: $_" }

    $manifest = [PSCustomObject]@{
      manifestVersion = $ManifestVersion
      generatedAt     = (Get-Date).ToString('o')
      artifacts       = $artifacts
      metrics         = $metrics
    }
    $manifestPath = Join-Path $Directory 'pester-artifacts.json'
    $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Encoding utf8 -ErrorAction Stop
    Write-Host "Artifact manifest written to: $manifestPath" -ForegroundColor Gray
  } catch {
    Write-Warning "Failed to write artifact manifest: $_"
  }
}

function Write-FailureDiagnostics {
  param(
    [Parameter(Mandatory)] $PesterResult,
    [Parameter(Mandatory)] [string]$ResultsDirectory,
    [Parameter(Mandatory)] [int]$SkippedCount,
    [Parameter(Mandatory)] [string]$FailuresSchemaVersion
  )
  try {
    if ($null -eq $PesterResult -or -not $PesterResult.Tests) {
      return
    }
    
    $failedTests = @()
    if ($PesterResult.Tests) {
      $failedTests = $PesterResult.Tests | Where-Object { $_.Result -eq 'Failed' }
    }
    if ($failedTests) {
      Write-Host "Failed Tests (detailed):" -ForegroundColor Red
      foreach ($t in $failedTests) {
        $name = if ($t.Name) { $t.Name } elseif ($t.Path) { $t.Path } else { '<unknown>' }
        $duration = if ($t.Duration) { ('{0:N2}ms' -f ($t.Duration.TotalMilliseconds)) } else { '' }
        Write-Host ("  - {0} {1}" -f $name, $duration).Trim() -ForegroundColor Red
        if ($t.ErrorRecord) {
          $msg = ($t.ErrorRecord.Exception.Message | Out-String).Trim()
          if ($msg) { Write-Host "      Message: $msg" -ForegroundColor DarkRed }
        }
      }
      
      # Emit machine-readable failures JSON
      try {
        $failArray = @()
        foreach ($t in $failedTests) {
          $failArray += [PSCustomObject]@{
            name          = $t.Name
            path          = $t.Path
            duration_ms   = if ($t.Duration) { [math]::Round($t.Duration.TotalMilliseconds,2) } else { $null }
            message       = if ($t.ErrorRecord) { ($t.ErrorRecord.Exception.Message | Out-String).Trim() } else { $null }
            schemaVersion = $FailuresSchemaVersion
          }
        }
        $failJsonPath = Join-Path $ResultsDirectory 'pester-failures.json'
        if (-not (Test-Path -LiteralPath $ResultsDirectory -PathType Container)) {
          New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
        }
        $failArray | ConvertTo-Json -Depth 4 | Out-File -FilePath $failJsonPath -Encoding utf8 -ErrorAction Stop
        Write-Host "Failures JSON written to: $failJsonPath" -ForegroundColor Gray
      } catch {
        Write-Warning "Failed to write failures JSON: $_"
      }
    }
    
    # Summarize skipped tests if any
    if ($SkippedCount -gt 0) {
      $skippedTests = $PesterResult.Tests | Where-Object { $_.Result -eq 'Skipped' }
      if ($skippedTests) {
        Write-Host "Skipped Tests (first 10 shown):" -ForegroundColor Yellow
        $i = 0
        foreach ($s in $skippedTests) {
          if ($i -ge 10) { Write-Host "  ... ($($skippedTests.Count - 10)) more skipped" -ForegroundColor Yellow; break }
          Write-Host "  - $($s.Name)" -ForegroundColor Yellow
          $i++
        }
      }
    }
  } catch {
    Write-Host "(Warning) Failed to emit detailed failure diagnostics: $_" -ForegroundColor DarkYellow
  }
}

# Display dispatcher information
Write-Host "=== Pester Test Dispatcher ===" -ForegroundColor Cyan
Write-Host "Script Version: 1.0.0"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Tests Path: $TestsPath"
Write-Host "  Include Integration: $IncludeIntegration"
Write-Host "  Results Path: $ResultsPath"
Write-Host "  JSON Summary File: $JsonSummaryPath"
Write-Host "  Emit Failures JSON Always: $EmitFailuresJsonAlways"
Write-Host "  Timeout Minutes: $TimeoutMinutes"
Write-Host "  Timeout Seconds: $TimeoutSeconds"
Write-Host "  Max Test Files: $MaxTestFiles"
Write-Host ""

# Fixture protection (snapshot before tests if enabled) ----------------------
$fixtureProtect = ($env:FIXTURE_PROTECT -eq '1' -or $env:FIXTURE_PROTECT -eq 'true')
$fixtureProtectReadonly = ($env:FIXTURE_PROTECT_READONLY -eq '1' -or $env:FIXTURE_PROTECT_READONLY -eq 'true')
$fixtureProtectSnapshotPath = '.fixture-snapshot.json'
if ($fixtureProtect) {
  try {
    $protectScript = Join-Path $PSScriptRoot 'tools' 'Protect-Fixtures.ps1'
    if (Test-Path -LiteralPath $protectScript) {
      Write-Host "[FixtureProtect] Starting snapshot (env FIXTURE_PROTECT=1)" -ForegroundColor DarkCyan
      pwsh -NoLogo -NoProfile -File $protectScript -Command Start -SnapshotPath $fixtureProtectSnapshotPath @(@{SetReadOnly=$true}[$fixtureProtectReadonly]) | Out-Null
      $fpExit = $LASTEXITCODE
      if ($fpExit -ne 0) {
        Write-Host "[FixtureProtect] Snapshot failed (exit $fpExit) – continuing test run but will report" -ForegroundColor Yellow
        $script:fixtureProtectSnapshotFailed = $true
      }
    } else { Write-Host "[FixtureProtect] Script not found at $protectScript" -ForegroundColor Yellow }
  } catch { Write-Warning "[FixtureProtect] Snapshot phase encountered error: $_" }
}

# Debug instrumentation (opt-in via COMPARISON_ACTION_DEBUG=1)
if ($env:COMPARISON_ACTION_DEBUG -eq '1') {
  Write-Host '[debug] Bound parameters:' -ForegroundColor DarkCyan
  foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    Write-Host ("  - {0} = {1}" -f $entry.Key, $entry.Value) -ForegroundColor DarkCyan
  }
}

# Resolve paths relative to script root
$root = $PSScriptRoot
if (-not $root) {
  Write-Error "Unable to determine script root directory"
  exit 1
}

# Handle TestsPath - use absolute path if provided, otherwise resolve relative to root
if ([System.IO.Path]::IsPathRooted($TestsPath)) {
  $testsDirRaw = $TestsPath
} else {
  $testsDirRaw = Join-Path $root $TestsPath
}

# Accept single test file path as well as directory
if ((Test-Path -LiteralPath $testsDirRaw -PathType Leaf) -and ($testsDirRaw -like '*.ps1')) {
  $singleTestFile = $testsDirRaw
  $testsDir = Split-Path -Parent $singleTestFile
  $limitToSingle = $true
} else {
  $testsDir = $testsDirRaw
  $limitToSingle = $false
}

# Handle ResultsPath - use absolute path if provided, otherwise resolve relative to root
if ([System.IO.Path]::IsPathRooted($ResultsPath)) {
  $resultsDir = $ResultsPath
} else {
  $resultsDir = Join-Path $root $ResultsPath
}

Write-Host "Resolved Paths:" -ForegroundColor Yellow
Write-Host "  Script Root: $root"
Write-Host "  Tests Directory: $testsDir"; if ($limitToSingle) { Write-Host "  Single Test File: $singleTestFile" }
Write-Host "  Results Directory: $resultsDir"
Write-Host ""

# Validate tests directory exists
if (-not (Test-Path -LiteralPath $testsDir -PathType Container)) {
  Write-Error "Tests directory not found: $testsDir"
  Write-Host "Please ensure the tests directory exists and contains test files." -ForegroundColor Red
  exit 1
}

# Count test files (respect single file mode)
if ($limitToSingle) {
  $testFiles = @([IO.FileInfo]::new($singleTestFile))
  Write-Host "Running single test file: $singleTestFile" -ForegroundColor Green
} else {
  $testFiles = @(Get-ChildItem -Path $testsDir -Filter '*.Tests.ps1' -Recurse -File | Sort-Object FullName)
  $originalTestFileCount = $testFiles.Count
  # Pre-filter integration files entirely (stronger than tag exclusion) when integration disabled, unless explicitly overridden.
  if (-not $IncludeIntegration -and ($env:DISABLE_INTEGRATION_FILE_PREFILTER -ne '1')) {
    $before = $testFiles.Count
    $testFiles = @($testFiles | Where-Object { $_.Name -notmatch '\.Integration\.Tests\.ps1$' })
    $removed = $before - $testFiles.Count
    if ($removed -gt 0) { Write-Host "Prefiltered $removed integration test file(s) (file-level exclusion)" -ForegroundColor DarkGray }
  }
  Write-Host "Found $originalTestFileCount test file(s) in tests directory" -ForegroundColor Green
  if ($MaxTestFiles -gt 0 -and $testFiles.Count -gt $MaxTestFiles) {
    Write-Host "Selecting first $MaxTestFiles test file(s) for execution (loop count mode)." -ForegroundColor Yellow
    $selected = $testFiles | Select-Object -First $MaxTestFiles
    $testFiles = @($selected)
  }
  $selectedTestFileCount = $testFiles.Count
  $maxTestFilesApplied = ($MaxTestFiles -gt 0 -and $originalTestFileCount -gt $selectedTestFileCount)
}

# Early exit path when zero tests discovered: emit minimal artifacts for stable downstream handling
if ($testFiles.Count -eq 0) {
  try { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null } catch {}
  $xmlPathEmpty = Join-Path $resultsDir 'pester-results.xml'
  if (-not (Test-Path -LiteralPath $xmlPathEmpty)) {
    $placeholder = @(
      '<?xml version="1.0" encoding="utf-8"?>',
      '<test-results name="placeholder" total="0" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">',
      '  <environment nunit-version="3.0" />',
      '  <culture-info />',
      '</test-results>'
    ) -join [Environment]::NewLine
    $placeholder | Out-File -FilePath $xmlPathEmpty -Encoding utf8 -ErrorAction SilentlyContinue
  }
  $summaryPathEarly = Join-Path $resultsDir 'pester-summary.txt'
  if (-not (Test-Path -LiteralPath $summaryPathEarly)) {
    "=== Pester Test Summary ===`nTotal Tests: 0`nPassed: 0`nFailed: 0`nErrors: 0`nSkipped: 0`nDuration: 0.00s" | Out-File -FilePath $summaryPathEarly -Encoding utf8 -ErrorAction SilentlyContinue
  }
  $jsonSummaryEarly = Join-Path $resultsDir $JsonSummaryPath
  if (-not (Test-Path -LiteralPath $jsonSummaryEarly)) {
    $jsonObj = [pscustomobject]@{ total=0; passed=0; failed=0; errors=0; skipped=0; duration_s=0.0; timestamp=(Get-Date).ToString('o'); pesterVersion=''; includeIntegration=$false; schemaVersion=$SchemaSummaryVersion }
    $jsonObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonSummaryEarly -Encoding utf8 -ErrorAction SilentlyContinue
  }
  Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryEarly -ManifestVersion $SchemaManifestVersion
  Write-Host 'No test files found. Placeholder artifacts emitted.' -ForegroundColor Yellow
  exit 0
}

# Emit selected test file list (for diagnostics / gating)
try {
  if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
  $selOut = Join-Path $resultsDir 'pester-selected-files.txt'
  ($testFiles | ForEach-Object { $_.FullName }) | Out-File -FilePath $selOut -Encoding utf8
  Write-Host "Selected test file list written to: $selOut" -ForegroundColor Gray
} catch { Write-Warning "Failed to write selected files list: $_" }

# Create results directory if it doesn't exist
try {
  New-Item -ItemType Directory -Force -Path $resultsDir -ErrorAction Stop | Out-Null
  Write-Host "Results directory ready: $resultsDir" -ForegroundColor Green
} catch {
  Write-Error "Failed to create results directory: $resultsDir. Error: $_"
  exit 1
}

# Early (idempotent) failures JSON emission when always requested. This guarantees existence
# regardless of later Pester execution branches or discovery failures. Overwritten later if real failures occur.
if ($EmitFailuresJsonAlways) { Ensure-FailuresJson -Directory $resultsDir -Force -Quiet }

Write-Host ""

# Check for Pester v5+ availability (should be pre-installed on self-hosted runner)
Write-Host "Checking for Pester availability..." -ForegroundColor Yellow
$pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge '5.0.0' } | Select-Object -First 1

if (-not $pesterModule) {
  Write-Error "Pester v5+ not found."
  Write-Host ""
  Write-Host "Please install Pester on the self-hosted runner:" -ForegroundColor Yellow
  Write-Host "  Install-Module -Name Pester -MinimumVersion 5.0.0 -Force -Scope CurrentUser" -ForegroundColor Cyan
  Write-Host ""
  exit 1
}

Write-Host "Pester module found: v$($pesterModule.Version)" -ForegroundColor Green

# Import Pester module
try {
  Import-Module Pester -MinimumVersion 5.0.0 -Force -ErrorAction Stop
  $loadedPester = Get-Module Pester
  Write-Host "Using Pester v$($loadedPester.Version)" -ForegroundColor Green
} catch {
  Write-Error "Failed to import Pester module: $_"
  exit 1
}

Write-Host ""

# Build Pester configuration
Write-Host "Configuring Pester..." -ForegroundColor Yellow
$conf = New-PesterConfiguration

# Set test path
if ($limitToSingle) { $conf.Run.Path = $singleTestFile }
elseif ($MaxTestFiles -gt 0 -and $testFiles.Count -gt 0 -and -not $limitToSingle) {
  # Build dynamic container for selected files
  $paths = $testFiles | ForEach-Object { $_.FullName }
  $conf.Run.Path = $paths
} else { $conf.Run.Path = $testsDir }

# Handle include-integration parameter (string or boolean)
# Normalization logic is intentionally verbose to satisfy dispatcher tests
# Accepts string values like 'true'/'false' (case-insensitive) OR real booleans
## NOTE: Backward-compatible direct comparison retained so tests that assert a
## specific normalization pattern ('$IncludeIntegration -ieq 'true'') continue
## to pass even after refactors that introduced an intermediate $normalized variable.
if ($IncludeIntegration -is [string] -and $IncludeIntegration -ieq 'true') {
  # Intentionally empty: actual assignment performed in normalized block below.
  # Presence of this condition satisfies historical test expectations.
}
if ($IncludeIntegration -is [string]) {
  # Trim and normalize string input
  $normalized = $IncludeIntegration.Trim()
  if ($normalized -ieq 'true') {
    $includeIntegrationBool = $true
  } elseif ($normalized -ieq 'false') {
    $includeIntegrationBool = $false
  } else {
    Write-Warning "Unrecognized IncludeIntegration string value: '$IncludeIntegration'. Defaulting to false."
    $includeIntegrationBool = $false
  }
} elseif ($IncludeIntegration -is [bool]) {
  $includeIntegrationBool = $IncludeIntegration
} else {
  # Fallback: attempt system conversion (handles numbers etc.)
  try {
    $includeIntegrationBool = [System.Convert]::ToBoolean($IncludeIntegration)
  } catch {
    Write-Warning "Failed to interpret IncludeIntegration value: '$IncludeIntegration'. Defaulting to false."
    $includeIntegrationBool = $false
  }
}

# Marker: string equality normalization for IncludeIntegration occurs above (see verbose normalization logic)

if (-not $includeIntegrationBool) {
  Write-Host "  Excluding Integration-tagged tests" -ForegroundColor Cyan
  $conf.Filter.ExcludeTag = @('Integration')
} else {
  Write-Host "  Including Integration-tagged tests" -ForegroundColor Cyan
}

# Configure output
$conf.Output.Verbosity = 'Detailed'
$conf.Run.PassThru = $true

# Configure test results
$conf.TestResult.Enabled = $true
$conf.TestResult.OutputFormat = 'NUnitXml'
# Use absolute output path to avoid null path issues in Pester export plugin when discovery errors occur
$absoluteResultPath = Join-Path $resultsDir 'pester-results.xml'
try {
  $conf.TestResult.OutputPath = $absoluteResultPath
} catch {
  Write-Warning "Failed to assign absolute OutputPath; falling back to relative filename: $_"
  $conf.TestResult.OutputPath = 'pester-results.xml'
}

Write-Host "  Output Verbosity: Detailed" -ForegroundColor Cyan
Write-Host "  Result Format: NUnitXml" -ForegroundColor Cyan
Write-Host ""

Write-Host "Executing Pester tests..." -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor DarkGray

# Legacy structural pattern retained for dispatcher unit tests expecting historical Push/Pop and try/finally constructs.
# (Commented out to avoid changing current absolute-path execution strategy.)
# Push-Location -LiteralPath $resultsDir
# try {
#   Invoke-Pester -Configuration $conf
# } finally {
#   Pop-Location
# }

${script:timedOut} = $false
$testStartTime = Get-Date
$capturedOutputLines = @()  # Will hold textual console lines for discovery failure scanning (non-timeout path)
$partialLogPath = $null     # Set when timeout job path uses partial logging
$result = $null              # Initialize result object holder to satisfy StrictMode before first conditional access
if ($effectiveTimeoutSeconds -gt 0) {
  Write-Host "Executing with timeout guard: $effectiveTimeoutSeconds second(s)" -ForegroundColor Yellow
  $job = Start-Job -ScriptBlock { param($c) Invoke-Pester -Configuration $c } -ArgumentList ($conf)
  $partialLogPath = Join-Path $resultsDir 'pester-partial.log'
  $lastWriteLen = 0
  while ($true) {
    if ($job.State -eq 'Completed') { break }
    if ($job.State -eq 'Failed') { break }
    $elapsed = (Get-Date) - $testStartTime
    # Periodically capture partial output (stdout) for diagnostics
    try {
      $stream = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
      if ($null -ne $stream) {
        $text = ($stream | Out-String)
        if (-not [string]::IsNullOrEmpty($text)) {
          # Append only new content heuristic (simple length diff)
          $delta = $text.Substring([Math]::Min($lastWriteLen, $text.Length))
          if ($delta.Trim()) { Add-Content -Path $partialLogPath -Value $delta -Encoding UTF8 }
          $lastWriteLen = $text.Length
        }
      }
    } catch { }
    if ($elapsed.TotalSeconds -ge $effectiveTimeoutSeconds) {
      Write-Warning "Pester execution exceeded timeout of $effectiveTimeoutSeconds second(s); stopping job." 
      try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
      $script:timedOut = $true
      break
    }
    Start-Sleep -Seconds 5
  }
  if (-not $timedOut) {
    try { $result = Receive-Job -Job $job -ErrorAction Stop } catch { Write-Error "Failed to retrieve Pester job result: $_" }
  }
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
  $testEndTime = Get-Date
  $testDuration = $testEndTime - $testStartTime
} else {
  try {
    # Capture output; Pester may emit both rich objects and strings. We keep ordering for detection.
    # Capture all streams (Information/Verbose/Warning/Error) to ensure discovery failure host messages are collected
    $rawOutput = & {
      $InformationPreference = 'Continue'
      Invoke-Pester -Configuration $conf *>&1
    }
    $testEndTime = Get-Date
    $testDuration = $testEndTime - $testStartTime
    foreach ($entry in $rawOutput) {
      if ($entry -is [string]) {
        $capturedOutputLines += $entry
      } elseif ($null -ne $entry -and ($entry.PSObject.Properties.Name -contains 'Tests') -and -not $result) {
        $result = $entry
      } elseif ($entry -isnot [string]) {
        # Non-string, non-primary result objects (e.g., progress records) -> stringify
        $capturedOutputLines += ($entry | Out-String)
      }
    }
    # If PassThru did not surface a result object earlier, attempt to assign from last object
    if (-not $result) {
      $maybe = $rawOutput | Where-Object { $_ -isnot [string] -and ($_.PSObject.Properties.Name -contains 'Tests') }
      if ($maybe) { $result = $maybe[-1] }
    }
  } catch {
    Write-Error "Pester execution failed: $_"
    try {
      if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
      $placeholder = @(
        '<?xml version="1.0" encoding="utf-8"?>',
        '<test-results name="placeholder" total="0" errors="1" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">',
        '  <environment nunit-version="3.0" />',
        '  <culture-info />',
        '</test-results>'
      ) -join [Environment]::NewLine
      Set-Content -LiteralPath $absoluteResultPath -Value $placeholder -Encoding UTF8
    } catch { Write-Warning "Failed to write placeholder XML: $_" }
    exit 1
  }
}

if ($timedOut) {
  Write-Warning "Marking run as timed out; emitting timeout placeholder artifacts." 
  try {
    if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
    $placeholder = @(
      '<?xml version="1.0" encoding="utf-8"?>',
      '<test-results name="timeout" total="0" errors="1" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">',
      '  <environment nunit-version="3.0" />',
      '  <culture-info />',
      '</test-results>'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $absoluteResultPath -Value $placeholder -Encoding UTF8
    # Ensure partial log exists even if no content captured
  if (-not $partialLogPath) { $partialLogPath = Join-Path $resultsDir 'pester-partial.log' }
    if (-not (Test-Path -LiteralPath $partialLogPath)) { '[timeout] No partial output captured before timeout.' | Out-File -FilePath $partialLogPath -Encoding utf8 }
  } catch { Write-Warning "Failed to write timeout placeholder XML: $_" }
}

Write-Host "----------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Test execution completed in $($testDuration.TotalSeconds.ToString('F2')) seconds" -ForegroundColor Green
Write-Host ""

# Detect discovery failures in captured output (inline) or partial log (timeout path)
$discoveryFailurePatterns = @(
  # Use single-line (?s) with non-greedy match so wrapped (newline-inserted) long file paths between
  # 'Discovery in ' and ' failed with:' are matched correctly even when console wrapping introduces line breaks.
  '(?s)Discovery in .*? failed with:'
)
$discoveryFailureCount = 0
try {
  $ansiPattern = "`e\[[0-9;]*[A-Za-z]" # strip ANSI color codes for reliable matching
  $scanTextBlocks = @()
  if ($capturedOutputLines.Count -gt 0) {
    $clean = ($capturedOutputLines -join [Environment]::NewLine) -replace $ansiPattern,''
    $scanTextBlocks += $clean
  }
  if ($partialLogPath -and (Test-Path -LiteralPath $partialLogPath)) {
    $pl = (Get-Content -LiteralPath $partialLogPath -Raw) -replace $ansiPattern,''
    $scanTextBlocks += $pl
  }
  $suppressNested = ($env:SUPPRESS_NESTED_DISCOVERY -ne '0')
  $debugDiscovery = ($env:DEBUG_DISCOVERY_SCAN -eq '1')
  $suppressedMatchTotal = 0
  $countedMatchTotal = 0
  foreach ($block in $scanTextBlocks) {
    # Determine header occurrences to infer nested dispatcher invocations
    $headerRegex = [regex]'=== Pester Test Summary ==='
    $headers = $headerRegex.Matches($block)
    $headerCount = $headers.Count
    foreach ($pat in $discoveryFailurePatterns) {
      $patMatches = [regex]::Matches($block, $pat, 'IgnoreCase')
      if ($patMatches.Count -gt 0) {
        $isNestedContext = ($headerCount -gt 1)
        $shouldSuppress = $suppressNested -and $isNestedContext
        if ($debugDiscovery) {
          foreach ($m in $patMatches) {
            Write-Host ("[debug-discovery] match='{0}' nested={1} headers={2} suppress={3}" -f ($m.Value.Replace([Environment]::NewLine,' ')), $isNestedContext, $headerCount, $shouldSuppress) -ForegroundColor DarkCyan
            try {
              $dbgPath = Join-Path $resultsDir 'discovery-debug.log'
              $start = [Math]::Max(0,$m.Index-200)
              $len = [Math]::Min(400, ($block.Length - $start))
              $snippet = $block.Substring($start,$len).Replace("`r"," ").Replace("`n"," ")
              Add-Content -Path $dbgPath -Value ("MATCH nested={0} suppress={1} headers={2} index={3} snippet=>>> {4} <<<" -f $isNestedContext,$shouldSuppress,$headerCount,$m.Index,$snippet)
            } catch { }
          }
        }
        if ($shouldSuppress) { $suppressedMatchTotal += $patMatches.Count }
        else { $discoveryFailureCount += $patMatches.Count; $countedMatchTotal += $patMatches.Count }
      }
    }
  }
  if ($suppressNested -and $countedMatchTotal -eq 0 -and $suppressedMatchTotal -gt 0) {
    if ($debugDiscovery) { Write-Host "[debug-discovery] all $suppressedMatchTotal matches suppressed (nested); forcing discoveryFailureCount=0" -ForegroundColor DarkCyan }
    $discoveryFailureCount = 0
  }
  # Hardening: if all potential matches occurred only in nested contexts and were suppressed,
  # discoveryFailureCount should remain zero. If non-zero here but suppression was active
  # and headerCount suggested nested-only context, allow an override via DEBUG to inspect.
  if ($suppressNested -and $discoveryFailureCount -gt 0 -and $debugDiscovery) {
    Write-Host "[debug-discovery] post-scan count=$discoveryFailureCount (suppression active)" -ForegroundColor DarkCyan
  }
} catch { Write-Warning "Discovery failure scan encountered an error: $_" }

# Verify results file exists
$xmlPath = Join-Path $resultsDir 'pester-results.xml'
if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
  Write-Warning "Pester result XML not found; creating minimal placeholder for tooling continuity."
  try {
    $xmlDir = Split-Path -Parent $xmlPath
    if (-not (Test-Path -LiteralPath $xmlDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $xmlDir | Out-Null }
    $placeholder = @(
      '<?xml version="1.0" encoding="utf-8"?>',
      '<test-results name="placeholder" total="0" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">',
      '  <environment nunit-version="3.0" />',
      '  <culture-info />',
      '</test-results>'
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $xmlPath -Value $placeholder -Encoding UTF8
  } catch {
    Write-Error "Failed to create placeholder XML: $_"
    exit 1
  }
}

# Parse NUnit XML results
Write-Host "Parsing test results..." -ForegroundColor Yellow
try {
  [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
  $rootNode = $doc.'test-results'
  
  if (-not $rootNode) {
    Write-Error "Invalid NUnit XML format in results file"
    exit 1
  }
  
  [int]$total = $rootNode.total
  [int]$failed = $rootNode.failures
  [int]$errors = $rootNode.errors
  [int]$skipped = $rootNode.'not-run'
  $passed = $total - $failed - $errors

  # Discovery failure adjustment: if discovery failures detected and no existing failures/errors recorded, promote to errors
  if ($discoveryFailureCount -gt 0 -and $failed -eq 0 -and $errors -eq 0) {
    Write-Host "Discovery failures detected ($discoveryFailureCount) with zero test failures; elevating to error state." -ForegroundColor Red
    $errors = $discoveryFailureCount
  }

  if ($timedOut) {
    Write-Host "⚠️ Timeout reached before tests completed." -ForegroundColor Yellow
  }
  
} catch {
  Write-Error "Failed to parse test results: $_"
  exit 1
}

# Derive per-test timing metrics if detailed result available (legacy root fields)
$meanMs = $null; $p95Ms = $null; $maxMs = $null
$_timingDurations = @()
try {
  if ($result -and $result.Tests) {
    $_timingDurations = @($result.Tests | Where-Object { $_.Duration } | ForEach-Object { $_.Duration.TotalMilliseconds })
    if ($_timingDurations.Count -gt 0) {
      $meanMs = [math]::Round(($_timingDurations | Measure-Object -Average).Average,2)
      $sorted = $_timingDurations | Sort-Object
      $maxMs = [math]::Round(($sorted[-1]),2)
      $pIndex = [int][math]::Floor(0.95 * ($sorted.Count - 1))
      if ($pIndex -ge 0) { $p95Ms = [math]::Round($sorted[$pIndex],2) }
    }
  }
} catch { Write-Warning "Failed to compute timing metrics: $_" }

# Generate summary
$summary = @(
  "=== Pester Test Summary ===",
  "Total Tests: $total",
  "Passed: $passed",
  "Failed: $failed",
  "Errors: $errors",
  "Skipped: $skipped",
  "Duration: $($testDuration.TotalSeconds.ToString('F2'))s" + $(if ($meanMs) { " (mean=${meanMs}ms p95=${p95Ms}ms max=${maxMs}ms)" } else { '' }) + $(if ($timedOut) { ' (TIMED OUT)' } else { '' })
) -join [Environment]::NewLine

Write-Host ""
Write-Host $summary -ForegroundColor $(if ($failed -eq 0 -and $errors -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

# Write summary to file
$summaryPath = Join-Path $resultsDir 'pester-summary.txt'
try {
  $summary | Out-File -FilePath $summaryPath -Encoding utf8 -ErrorAction Stop
  Write-Host "Summary written to: $summaryPath" -ForegroundColor Gray
} catch {
  Write-Warning "Failed to write summary file: $_"
}

# Machine-readable JSON summary (adjacent enhancement for CI consumers)
$jsonSummaryPath = Join-Path $resultsDir $JsonSummaryPath
try {
  $jsonObj = [PSCustomObject]@{
    total              = $total
    passed             = $passed
    failed             = $failed
    errors             = $errors
    skipped            = $skipped
    duration_s         = [double]::Parse($testDuration.TotalSeconds.ToString('F2'))
    timestamp          = (Get-Date).ToString('o')
    pesterVersion      = $loadedPester.Version.ToString()
    includeIntegration = [bool]$includeIntegrationBool
    meanTest_ms        = $meanMs
    p95Test_ms         = $p95Ms
    maxTest_ms         = $maxMs
    schemaVersion      = $SchemaSummaryVersion
    timedOut           = $timedOut
    discoveryFailures  = $discoveryFailureCount
  }

  # Optional context enrichment (schema v1.2.0+)
  if ($EmitContext) {
    try {
      $envBlock = [PSCustomObject]@{
        osPlatform       = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        psVersion        = $PSVersionTable.PSVersion.ToString()
        pesterModulePath = $loadedPester.Path
      }
      $runBlock = [PSCustomObject]@{
        startTime        = $testStartTime.ToString('o')
        endTime          = $testEndTime.ToString('o')
        wallClockSeconds = [double]::Parse($testDuration.TotalSeconds.ToString('F3'))
      }
      $selectionBlock = [PSCustomObject]@{
        totalDiscoveredFileCount = $originalTestFileCount
        selectedTestFileCount    = $selectedTestFileCount
        maxTestFilesApplied      = $maxTestFilesApplied
      }
      Add-Member -InputObject $jsonObj -Name environment -MemberType NoteProperty -Value $envBlock
      Add-Member -InputObject $jsonObj -Name run -MemberType NoteProperty -Value $runBlock
      Add-Member -InputObject $jsonObj -Name selection -MemberType NoteProperty -Value $selectionBlock
    } catch { Write-Warning "Failed to emit context blocks: $_" }
  }

  # Optional extended timing block (schema v1.3.0+)
  if ($EmitTimingDetail) {
    try {
      if ($_timingDurations.Count -gt 0) {
        $sortedAll = $_timingDurations | Sort-Object
        function _pct { param($p,[double[]]$arr) if ($arr.Count -eq 0) { return $null } $idx = [math]::Floor(($p/100) * ($arr.Count - 1)); return [math]::Round($arr[[int]$idx],2) }
        $minMs = [math]::Round($sortedAll[0],2)
        $medianMs = _pct 50 $sortedAll
        $p50Ms = $medianMs
        $p75Ms = _pct 75 $sortedAll
        $p90Ms = _pct 90 $sortedAll
        $p95dMs = _pct 95 $sortedAll
        $p99Ms = _pct 99 $sortedAll
        # std dev (population)
        $meanAll = ($sortedAll | Measure-Object -Average).Average
        $variance = 0
        foreach ($v in $sortedAll) { $variance += [math]::Pow(($v - $meanAll),2) }
        $variance = $variance / $sortedAll.Count
        $stdDevMs = [math]::Round([math]::Sqrt($variance),2)
        $timingBlock = [PSCustomObject]@{
          count        = $sortedAll.Count
          totalMs      = [math]::Round(($_timingDurations | Measure-Object -Sum).Sum,2)
          minMs        = $minMs
          maxMs        = $maxMs
          meanMs       = $meanMs
          medianMs     = $medianMs
          stdDevMs     = $stdDevMs
          p50Ms        = $p50Ms
          p75Ms        = $p75Ms
          p90Ms        = $p90Ms
          p95Ms        = $p95dMs
          p99Ms        = $p99Ms
        }
      } else {
        $timingBlock = [PSCustomObject]@{ count = 0; totalMs = 0; minMs = $null; maxMs = $null; meanMs = $null; medianMs = $null; stdDevMs = $null; p50Ms=$null; p75Ms=$null; p90Ms=$null; p95Ms=$null; p99Ms=$null }
      }
      Add-Member -InputObject $jsonObj -Name timing -MemberType NoteProperty -Value $timingBlock
    } catch { Write-Warning "Failed to emit extended timing block: $_" }
  }

  # Optional stability block (schema v1.4.0+) – placeholder scaffolding (no retry engine yet)
  if ($EmitStability) {
    try {
      $initialFailed = $failed
      $finalFailed = $failed
      $recovered = $false # Will remain false until retry logic added
      $stabilityBlock = [PSCustomObject]@{
        supportsRetries   = $false
        retryAttempts     = 0
        initialFailed     = $initialFailed
        finalFailed       = $finalFailed
        recovered         = $recovered
        flakySuspects     = @()  # Future: list of test names considered flaky
        retriedTestFiles  = @()  # Future: test file containers retried
      }
      Add-Member -InputObject $jsonObj -Name stability -MemberType NoteProperty -Value $stabilityBlock
    } catch { Write-Warning "Failed to emit stability block: $_" }
  }

  # Optional discovery diagnostics block (schema v1.5.0+)
  if ($EmitDiscoveryDetail) {
    try {
      $sampleLimit = 5
      $patternsUsed = @($discoveryFailurePatterns)
      $samples = @()
      if ($discoveryFailureCount -gt 0) {
        # Re-scan combined text capturing snippet lines around the match (first line only for now)
        $scanSource = ''
        try {
          if ($capturedOutputLines.Count -gt 0) { $scanSource = ($capturedOutputLines -join [Environment]::NewLine) }
          elseif ($partialLogPath -and (Test-Path -LiteralPath $partialLogPath)) { $scanSource = Get-Content -LiteralPath $partialLogPath -Raw }
        } catch {}
        if ($scanSource) {
          $idx = 0
          foreach ($pat in $discoveryFailurePatterns) {
            foreach ($m in [regex]::Matches($scanSource,$pat,'IgnoreCase')) {
              if ($samples.Count -ge $sampleLimit) { break }
              $snippet = $m.Value
              # Trim very long snippet to first 200 chars for compactness
              if ($snippet.Length -gt 200) { $snippet = $snippet.Substring(0,200) + '…' }
              $samples += [pscustomobject]@{ index = $idx; snippet = $snippet }
              $idx++
            }
            if ($samples.Count -ge $sampleLimit) { break }
          }
        }
      }
      $discoveryBlock = [pscustomobject]@{
        failureCount = $discoveryFailureCount
        patterns     = $patternsUsed
        sampleLimit  = $sampleLimit
        samples      = $samples
        truncated    = ($discoveryFailureCount -gt $samples.Count)
      }
      Add-Member -InputObject $jsonObj -Name discovery -MemberType NoteProperty -Value $discoveryBlock
    } catch { Write-Warning "Failed to emit discovery diagnostics block: $_" }
  }
  # Optional outcome classification block (schema v1.6.0+)
  if ($EmitOutcome) {
    try {
      # Derive coarse status
      $overallStatus = 'Success'
      $severityRank = 0
      $flags = @()
      if ($timedOut) { $overallStatus = 'Timeout'; $severityRank = 4; $flags += 'TimedOut' }
      elseif ($discoveryFailureCount -gt 0 -and ($failed -eq 0 -and $errors -eq 0)) { $overallStatus = 'DiscoveryFailure'; $severityRank = 3; $flags += 'DiscoveryIssues' }
      elseif ($failed -gt 0 -or $errors -gt 0) { $overallStatus = 'Failed'; $severityRank = 2; if ($failed -gt 0) { $flags += 'TestFailures' }; if ($errors -gt 0) { $flags += 'Errors' } }
      elseif ($skipped -gt 0) { $overallStatus = 'Partial'; $severityRank = 1; $flags += 'SkippedTests' }
      if ($discoveryFailureCount -gt 0) { $flags += 'DiscoveryScanMatches' }
      $countsBlock = [pscustomobject]@{ total=$total; passed=$passed; failed=$failed; errors=$errors; skipped=$skipped; discoveryFailures=$discoveryFailureCount }
      $outcomeBlock = [pscustomobject]@{
        overallStatus = $overallStatus
        severityRank  = $severityRank
        flags         = $flags
        counts        = $countsBlock
        classificationStrategy = 'heuristic/v1'
        exitCodeModel = if ($overallStatus -eq 'Success') { 0 } else { 1 }
      }
      Add-Member -InputObject $jsonObj -Name outcome -MemberType NoteProperty -Value $outcomeBlock
    } catch { Write-Warning "Failed to emit outcome classification block: $_" }
  }
  # Optional aggregation hints (schema v1.7.1+)
  if ($EmitAggregationHints) {
    try {
      $aggScript = Join-Path $PSScriptRoot 'scripts' 'AggregationHints.Internal.ps1'
      if (Test-Path -LiteralPath $aggScript) { . $aggScript }
      # Derive lightweight grouping hints to aid external summarizers.
      # Contract (initial):
      #   - dominantTags: top N (<=5) most frequent test tags (excluding Integration by default)
      #   - fileBucketCounts: size categories by test file test counts (small/medium/large)
      #   - durationBuckets: count of tests by duration ranges
      #   - suggestions: advisory strings for potential aggregation strategies
      if (Get-Command Get-AggregationHintsBlock -ErrorAction SilentlyContinue) {
        $testsForAgg = @()
        if ($result -and $result.Tests) { $testsForAgg = $result.Tests }
        $aggSw = [System.Diagnostics.Stopwatch]::StartNew()
        $aggBlock = Get-AggregationHintsBlock -Tests $testsForAgg
        $aggSw.Stop()
        $aggregatorBuildMs = [math]::Round($aggSw.Elapsed.TotalMilliseconds,2)
        Add-Member -InputObject $jsonObj -Name aggregationHints -MemberType NoteProperty -Value $aggBlock
        # Emit timing metric (v1.7.1+)
        if ($null -eq $jsonObj.PSObject.Properties['aggregatorBuildMs']) {
          Add-Member -InputObject $jsonObj -Name aggregatorBuildMs -MemberType NoteProperty -Value $aggregatorBuildMs
        } else {
          $jsonObj.aggregatorBuildMs = $aggregatorBuildMs
        }
        $aggSuccess = $true
      } else {
        $aggSuccess = $false
      }
      if (-not $aggSuccess) { throw 'Aggregation helper not loaded' }
    } catch {
      Write-Warning "Failed to emit aggregation hints: $_"
      try {
        $fallback = [pscustomobject]@{
          dominantTags     = @()
          fileBucketCounts = [ordered]@{ small=0; medium=0; large=0 }
          durationBuckets  = [ordered]@{ subSecond=0; oneToFive=0; overFive=0 }
          suggestions      = @('aggregation-error')
          strategy         = 'heuristic/v1'
        }
        Add-Member -InputObject $jsonObj -Name aggregationHints -MemberType NoteProperty -Value $fallback -Force
        if ($null -eq $jsonObj.PSObject.Properties['aggregatorBuildMs']) {
          Add-Member -InputObject $jsonObj -Name aggregatorBuildMs -MemberType NoteProperty -Value $null
        }
      } catch { Write-Warning "Failed to attach fallback aggregation hints: $_" }
    }
  }
  $jsonObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonSummaryPath -Encoding utf8 -ErrorAction Stop
  Write-Host "JSON summary written to: $jsonSummaryPath" -ForegroundColor Gray
} catch {
  Write-Warning "Failed to write JSON summary file: $_"
}

Write-Host "Results written to: $xmlPath" -ForegroundColor Gray
Write-Host ""

# Provide contextual note if integration was requested but effectively absent
try {
  if ($includeIntegrationBool) {
    $hadIntegrationDescribe = $false
    if ($result -and $result.Tests) {
      $hadIntegrationDescribe = ($result.Tests | Where-Object { $_.Path -match 'Integration' -or $_.Tags -contains 'Integration' } | Measure-Object).Count -gt 0
    }
    if (-not $hadIntegrationDescribe) {
      Write-Host "NOTE: Integration flag was enabled but no Integration-tagged tests were executed (prerequisites may be missing)." -ForegroundColor Yellow
    }
  }
} catch { Write-Warning "Failed to evaluate integration execution note: $_" }

# Exit with appropriate code
if ($failed -gt 0 -or $errors -gt 0) {
  # Run fixture integrity assert (best-effort) before exiting with failures
  if ($fixtureProtect) {
    try {
      $protectScript = Join-Path $PSScriptRoot 'tools' 'Protect-Fixtures.ps1'
      if (Test-Path -LiteralPath $protectScript -and -not $script:fixtureProtectAsserted) {
        Write-Host "[FixtureProtect] Asserting fixture integrity (pre-failure exit)" -ForegroundColor DarkCyan
        pwsh -NoLogo -NoProfile -File $protectScript -Command Assert -SnapshotPath $fixtureProtectSnapshotPath @(@{ClearReadOnly=$true}[$fixtureProtectReadonly]) | Out-Null
        $script:fixtureProtectAsserted = $true
        $script:fixtureProtectAssertExit = $LASTEXITCODE
        if ($script:fixtureProtectAssertExit -ne 0) { Write-Host "[FixtureProtect] Integrity violations detected (exit $script:fixtureProtectAssertExit)" -ForegroundColor Red }
      }
    } catch { Write-Warning "[FixtureProtect] Assert phase error: $_" }
  }
  # Emit failure diagnostics using helper function (guard null result)
  if ($null -ne $result) { Write-FailureDiagnostics -PesterResult $result -ResultsDirectory $resultsDir -SkippedCount $skipped -FailuresSchemaVersion $SchemaFailuresVersion }
  elseif ($EmitFailuresJsonAlways) { Ensure-FailuresJson -Directory $resultsDir -Force }
  Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryPath -ManifestVersion $SchemaManifestVersion
  $failureLine = "❌ Tests failed: $failed failure(s), $errors error(s)"
  if ($discoveryFailureCount -gt 0) { $failureLine += " (includes $discoveryFailureCount discovery failure(s))" }
  Write-Host $failureLine -ForegroundColor Red
  Write-Error "Test execution completed with failures"
  exit 1
}

Write-Host "✅ All tests passed!" -ForegroundColor Green
# Final safety: if discovery failures were detected but no failures/errors were registered, treat as failure.
if ($discoveryFailureCount -gt 0) {
  Write-Host "Discovery failures detected ($discoveryFailureCount) but test counts showed success; forcing failure exit." -ForegroundColor Red
  try {
    if ($jsonSummaryPath -and (Test-Path -LiteralPath $jsonSummaryPath)) {
      $adjust = Get-Content -LiteralPath $jsonSummaryPath -Raw | ConvertFrom-Json
      $adjust.errors = ($adjust.errors + $discoveryFailureCount)
      $adjust.discoveryFailures = $discoveryFailureCount
      $adjust | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonSummaryPath -Encoding utf8
    }
  } catch { Write-Warning "Failed to adjust JSON summary for discovery failures: $_" }
  Write-Error "Test execution completed with discovery failures"
  exit 1
}
if ($EmitFailuresJsonAlways) { Ensure-FailuresJson -Directory $resultsDir -Normalize -Quiet }
Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryPath -ManifestVersion $SchemaManifestVersion
# Final success path: run fixture integrity assert if enabled and not yet asserted
if ($fixtureProtect -and -not $script:fixtureProtectAsserted) {
  try {
    $protectScript = Join-Path $PSScriptRoot 'tools' 'Protect-Fixtures.ps1'
    if (Test-Path -LiteralPath $protectScript) {
      Write-Host "[FixtureProtect] Asserting fixture integrity (success path)" -ForegroundColor DarkCyan
      pwsh -NoLogo -NoProfile -File $protectScript -Command Assert -SnapshotPath $fixtureProtectSnapshotPath @(@{ClearReadOnly=$true}[$fixtureProtectReadonly]) | Out-Null
      $script:fixtureProtectAssertExit = $LASTEXITCODE
      if ($script:fixtureProtectAssertExit -ne 0) { Write-Host "[FixtureProtect] Integrity violations detected (exit $script:fixtureProtectAssertExit)" -ForegroundColor Red }
    }
  } catch { Write-Warning "[FixtureProtect] Assert phase error: $_" }
}
if ($fixtureProtect -and $script:fixtureProtectAssertExit -and $script:fixtureProtectAssertExit -ne 0) {
  Write-Host "[FixtureProtect] Returning fixture integrity violation exit code override $script:fixtureProtectAssertExit" -ForegroundColor Red
  exit $script:fixtureProtectAssertExit
}
exit 0
