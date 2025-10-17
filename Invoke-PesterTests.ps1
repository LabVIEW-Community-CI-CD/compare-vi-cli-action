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
.PARAMETER IntegrationMode
    Controls how Integration-tagged tests are handled. Options: auto (default), include, exclude.
.PARAMETER IncludeIntegration
    [Deprecated] Legacy boolean switch to include Integration-tagged tests. Prefer -IntegrationMode.
.PARAMETER ResultsPath
    Path to directory where results should be written (default: tests/results)
.PARAMETER JsonSummaryPath
  (Optional) File name (no directory) for machine-readable JSON summary (default: pester-summary.json)
.EXAMPLE
    ./Invoke-PesterTests.ps1 -TestsPath tests -IntegrationMode include -ResultsPath tests/results
.EXAMPLE
    ./Invoke-PesterTests.ps1 -IntegrationMode exclude
.NOTES
    Requires Pester v5.0.0 or later to be pre-installed on the runner.
    Exit codes: 0 = success, 1 = failure (test failures or execution errors)
#>

param(
  [Parameter(Mandatory = $false)]
  [ValidateNotNullOrEmpty()]
  [string]$TestsPath = 'tests',

  [Parameter(Mandatory = $false)]
  [ValidateSet('auto','include','exclude')]
  [string]$IntegrationMode = 'auto',

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
  # Internal helper to clear dispatcher guard crumbs without running Pester
  [Parameter(Mandatory = $false)]
  [switch]$GuardResetOnly,
  # Use a Node/TypeScript-backed discovery manifest (falls back to PS scan);
  # when Integration is excluded, pre-filters files marked with Integration tags
  [Parameter(Mandatory = $false)]
  [switch]$UseDiscoveryManifest,

  [Parameter(Mandatory = $false)]
  [double]$TimeoutMinutes = 0,

  [Parameter(Mandatory = $false)]
  [double]$TimeoutSeconds = 0,

  [Parameter(Mandatory = $false)]
  [int]$MaxTestFiles = 0
,
  # Optional include/exclude patterns for test file selection (wildcards). If a pattern contains '/' or '\\',
  # it is matched against the full path; otherwise it is matched against the filename.
  [Parameter(Mandatory = $false)]
  [string[]]$IncludePatterns,
  [Parameter(Mandatory = $false)]
  [string[]]$ExcludePatterns,

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
  # Stream Pester output to console while still capturing
  [Parameter(Mandatory = $false)]
  [switch]$LiveOutput,
  # Optional: emit aggregationHints block (schema v1.7.1+ with timing metric)
  [switch]$EmitAggregationHints,

  # Opt-in: ensure LabVIEW is not left running before/after tests
  [Parameter(Mandatory = $false)]
  [switch]$CleanLabVIEW,

  # Opt-in: also close LabVIEW after tests complete
  [Parameter(Mandatory = $false)]
  [switch]$CleanAfter,

  # Opt-in: track artifacts created/modified/deleted by the test run
  [Parameter(Mandatory = $false)]
  [switch]$TrackArtifacts,
  # Optional glob/paths (relative to repo root or absolute) to include in tracking
  [Parameter(Mandatory = $false)]
  [string[]]$ArtifactGlobs,

  # Leak detection: detect lingering LabVIEW/LVCompare processes or Pester jobs
  [Parameter(Mandatory = $false)]
  [switch]$DetectLeaks,
  # When set, fail the run if leaks are detected
  [Parameter(Mandatory = $false)]
  [switch]$FailOnLeaks,

  # Leak detection options (additive):
  # - Custom process name patterns (wildcards allowed) to consider as leaks (default: 'LVCompare','LabVIEW')
  [Parameter(Mandatory = $false)]
  [string[]]$LeakProcessPatterns,
  # - Grace period (seconds) to wait before final leak check (allows natural shutdown)
  [Parameter(Mandatory = $false)]
  [double]$LeakGraceSeconds = 0,
  # - Attempt automatic cleanup of detected leaks (stop processes and jobs)
  [Parameter(Mandatory = $false)]
  [switch]$KillLeaks
  ,
  # Emit diagnostics summarizing the shapes/types of objects in $result.Tests
  [Parameter(Mandatory = $false)]
  [switch]$EmitResultShapeDiagnostics
,
  # Opt-out: prevent writing diagnostics to GitHub Step Summary even if available
  [Parameter(Mandatory = $false)]
  [switch]$DisableStepSummary
,
  [Parameter(Mandatory = $false)]
  [switch]$SingleInvoker
,
  [Parameter(Mandatory = $false)]
  [ValidateSet('soft','strict')]
  [string]$Isolation = 'soft'
,
  [Parameter(Mandatory = $false)]
  [switch]$DryRun
,
  [Parameter(Mandatory = $false)]
  [int]$TopSlow = 0
,
  [Parameter(Mandatory = $false)]
  [int]$MaxFileSeconds = 0
,
  [Parameter(Mandatory = $false)]
  [switch]$ContinueOnTimeout
,
  [Parameter(Mandatory = $false)]
  [switch]$EmitIts
)

$dispatcherSelectionModule = Join-Path $PSScriptRoot 'tools' 'Dispatcher' 'TestSelection.psm1'
if (Test-Path -LiteralPath $dispatcherSelectionModule) {
  Import-Module $dispatcherSelectionModule -Force
}

$labviewPidTrackerModule = Join-Path $PSScriptRoot 'tools' 'LabVIEWPidTracker.psm1'
$labviewPidTrackerLoaded = $false
$script:labviewPidContextResolver = $null
if (Test-Path -LiteralPath $labviewPidTrackerModule -PathType Leaf) {
  try {
    Import-Module $labviewPidTrackerModule -Force
    $labviewPidTrackerLoaded = $true
    try {
      $script:labviewPidContextResolver = Get-Command -Name Resolve-LabVIEWPidContext -ErrorAction Stop
    } catch {
      $script:labviewPidContextResolver = $null
    }
  } catch {
    Write-Warning ("Failed to import LabVIEWPidTracker module: {0}" -f $_.Exception.Message)
  }
}
$script:labviewPidTrackerState = $null
$script:labviewPidTrackerPath = $null
$script:labviewPidTrackerFinalState = $null
$script:labviewPidTrackerFinalized = $false
$script:labviewPidTrackerFinalizedSource = $null
$script:labviewPidTrackerFinalizedContext = $null
$script:labviewPidTrackerFinalizedContextSource = $null

function _Normalize-LabVIEWPidContext {
  param([object]$Value)

  if ($null -eq $Value) { return $null }

  $resolver = $script:labviewPidContextResolver
  if (-not $resolver -and $labviewPidTrackerLoaded) {
    try {
      $resolver = Get-Command -Name Resolve-LabVIEWPidContext -ErrorAction Stop
      $script:labviewPidContextResolver = $resolver
    } catch {
      $resolver = $null
    }
  }

  if ($resolver) {
    try {
      $resolved = & $resolver -Input $Value
      if ($resolved) { return $resolved }
      return $resolved
    } catch {}
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $pairs = @()
    foreach ($key in $Value.Keys) {
      if ($null -eq $key) { continue }
      try {
        $name = [string]$key
      } catch {
        continue
      }
      $pairs += [pscustomobject]@{ Name = $name; Value = $Value[$key] }
    }

    $ordered = [ordered]@{}
    $orderedPairs = $pairs |
      Where-Object { $_ -and $_.Name } |
      Sort-Object -Property Name -CaseSensitive

    foreach ($pair in $orderedPairs) {
      if ($ordered.Contains($pair.Name)) { continue }
      $ordered[$pair.Name] = $pair.Value
    }

    if ($ordered.Count -gt 0) { return [pscustomobject]$ordered }
    return $null
  }

  if ($Value -is [pscustomobject]) { return $Value }
  return $Value
}

function _Finalize-LabVIEWPidTracker {
  param(
    [object]$Context,
    [string]$Source = 'dispatcher:final'
  )

  if (-not $labviewPidTrackerLoaded) { return $null }
  if (-not $script:labviewPidTrackerPath) { return $null }
  if ($script:labviewPidTrackerFinalized) { return $script:labviewPidTrackerFinalState }

  try {
    $args = @{
      TrackerPath = $script:labviewPidTrackerPath
      Source      = $Source
    }
    $pidForFinal = $null
    if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid']) {
      $pidForFinal = $script:labviewPidTrackerState.Pid
    }
    if ($pidForFinal) { $args['Pid'] = $pidForFinal }
    if ($PSBoundParameters.ContainsKey('Context') -and $null -ne $Context) { $args['Context'] = $Context }

    $final = Stop-LabVIEWPidTracker @args
    $script:labviewPidTrackerFinalState = $final
    $script:labviewPidTrackerFinalized = $true
    $script:labviewPidTrackerFinalizedSource = $Source
    if ($final -and $final.PSObject.Properties['Context'] -and $final.Context) {
      $script:labviewPidTrackerFinalizedContext = _Normalize-LabVIEWPidContext -Value $final.Context
      $script:labviewPidTrackerFinalizedContextSource = 'tracker'
    } elseif ($PSBoundParameters.ContainsKey('Context') -and $null -ne $Context) {
      $script:labviewPidTrackerFinalizedContext = _Normalize-LabVIEWPidContext -Value $Context
      $script:labviewPidTrackerFinalizedContextSource = $Source
    } else {
      $script:labviewPidTrackerFinalizedContext = $null
      $script:labviewPidTrackerFinalizedContextSource = $null
    }
    return $final
  } catch {
    Write-Warning ("LabVIEW PID tracker finalization failed: {0}" -f $_.Exception.Message)
    return $null
  }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Default for includeIntegrationBool to avoid uninitialized usage during early helper calls
if (-not (Get-Variable -Name includeIntegrationBool -Scope Script -ErrorAction SilentlyContinue)) {
  $script:includeIntegrationBool = $false
}

function Test-EnvTruthy {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Value.Trim() -match '^(?i:1|true|yes|on)$')
}

# Env toggle support: CLEAN_LABVIEW=1 and/or CLEAN_AFTER=1 act as implicit switches
if (-not $CleanLabVIEW) {
  $CleanLabVIEW = Test-EnvTruthy $env:CLEAN_LV_BEFORE
  if (-not $CleanLabVIEW) { $CleanLabVIEW = Test-EnvTruthy $env:CLEAN_LABVIEW }
}
if (-not $CleanAfter)   {
  $CleanAfter = Test-EnvTruthy $env:CLEAN_LV_AFTER
  if (-not $CleanAfter) { $CleanAfter = Test-EnvTruthy $env:CLEAN_AFTER }
}
if (-not $TrackArtifacts) { $TrackArtifacts = ($env:SCAN_ARTIFACTS -eq '1') }
if (-not $ArtifactGlobs -and $env:ARTIFACT_GLOBS) { $ArtifactGlobs = ($env:ARTIFACT_GLOBS -split ';|,') }
if (-not $DetectLeaks) { $DetectLeaks = ($env:DETECT_LEAKS -eq '1') }

[string]$__SingleInvokerRequested = if ($SingleInvoker) { '1' } elseif ($env:SINGLE_INVOKER -eq '1') { '1' } else { '0' }
$disableSingleInvoker = Test-EnvTruthy $env:DISABLE_SINGLE_INVOKER
if (-not $FailOnLeaks) { $FailOnLeaks = ($env:FAIL_ON_LEAKS -eq '1') }
if (-not $LeakProcessPatterns -and $env:LEAK_PROCESS_PATTERNS) { $LeakProcessPatterns = ($env:LEAK_PROCESS_PATTERNS -split ';|,') }
if ($env:LEAK_GRACE_SECONDS) {
  try { $LeakGraceSeconds = [double]$env:LEAK_GRACE_SECONDS } catch {}
}
if (-not $KillLeaks) { $KillLeaks = ($env:KILL_LEAKS -eq '1') }

# Optional: allow explicit opt-in to clean LVCompare alongside LabVIEW during cleanup
$includeLVCompare = Test-EnvTruthy $env:CLEAN_LV_INCLUDE_COMPARE
if (-not $includeLVCompare) { $includeLVCompare = Test-EnvTruthy $env:CLEAN_LVCOMPARE }
$script:CleanLVCompare = $includeLVCompare
# Helper to interpret truthy env toggles (1/true/yes/on)
function _IsTruthyEnv {
  param([string]$Value)
  return (Test-EnvTruthy $Value)
}
if (-not $EmitResultShapeDiagnostics) { $EmitResultShapeDiagnostics = (_IsTruthyEnv $env:EMIT_RESULT_SHAPES) }
if (-not $DisableStepSummary) { $DisableStepSummary = (_IsTruthyEnv $env:DISABLE_STEP_SUMMARY) }

function _Interpret-LegacyIncludeIntegration {
  param(
    [object]$Value,
    [switch]$WarnOnUnrecognized
  )

  if ($null -eq $Value) { return $null }
  if ($Value -is [bool]) { return [bool]$Value }

  try {
    $text = $Value.ToString()
  } catch {
    return $null
  }

  $normalized = $text.Trim()
  if ($normalized.Length -eq 0) { return $null }

  $lower = $normalized.ToLowerInvariant()
  switch ($lower) {
    'true' { return $true }
    'false' { return $false }
    '1' { return $true }
    '0' { return $false }
    'yes' { return $true }
    'no' { return $false }
    'y' { return $true }
    'n' { return $false }
    'on' { return $true }
    'off' { return $false }
    'include' { return $true }
    'exclude' { return $false }
    'auto' { return $null }
    default {
      if ($WarnOnUnrecognized) {
        Write-Warning "Unrecognized IncludeIntegration value: '$Value'. Defaulting to exclude."
      }
      return $false
    }
  }
}

function _Resolve-IntegrationMode {
  param(
    [string]$RequestedMode,
    [bool]$RequestedExplicit,
    [object]$LegacyBool,
    [bool]$LegacyExplicit
  )

  if ($RequestedExplicit) { return $RequestedMode }
  if ($LegacyExplicit) {
    if ($LegacyBool -eq $true) { return 'include' }
    if ($LegacyBool -eq $false) { return 'exclude' }
    return 'auto'
  }
  return $RequestedMode
}

function _Resolve-AutoIntegrationPreference {
  param(
    [bool]$Default = $false
  )

  $envPriority = @(
    @{ Name = 'INCLUDE_INTEGRATION';        Label = 'env:INCLUDE_INTEGRATION' },
    @{ Name = 'INPUT_INCLUDE_INTEGRATION'; Label = 'env:INPUT_INCLUDE_INTEGRATION' },
    @{ Name = 'GITHUB_INPUT_INCLUDE_INTEGRATION'; Label = 'env:GITHUB_INPUT_INCLUDE_INTEGRATION' },
    @{ Name = 'EV_INCLUDE_INTEGRATION';    Label = 'env:EV_INCLUDE_INTEGRATION' },
    @{ Name = 'CI_INCLUDE_INTEGRATION';    Label = 'env:CI_INCLUDE_INTEGRATION' },
    @{ Name = 'GH_INCLUDE_INTEGRATION';    Label = 'env:GH_INCLUDE_INTEGRATION' },
    @{ Name = 'include_integration';       Label = 'env:include_integration' }
  )

  foreach ($entry in $envPriority) {
    try {
      $raw = [System.Environment]::GetEnvironmentVariable($entry.Name)
    } catch {
      continue
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $parsed = _Interpret-LegacyIncludeIntegration -Value $raw
    if ($null -ne $parsed) {
      return [pscustomobject]@{
        Include = [bool]$parsed
        Source  = ("{0}={1}" -f $entry.Label, $raw)
      }
    }
  }

  return [pscustomobject]@{
    Include = [bool]$Default
    Source  = 'default:auto'
  }
}

$legacyIncludeSpecified = $PSBoundParameters.ContainsKey('IncludeIntegration')
$modeParameterSpecified = $PSBoundParameters.ContainsKey('IntegrationMode')
$legacyNormalizedValue = $null

if ($legacyIncludeSpecified) {
  $warnValue = -not $modeParameterSpecified
  $legacyNormalizedValue = _Interpret-LegacyIncludeIntegration -Value $IncludeIntegration -WarnOnUnrecognized:$warnValue
  Write-Warning "IncludeIntegration is deprecated; use -IntegrationMode include|exclude|auto."
  if ($modeParameterSpecified) {
    Write-Warning "IncludeIntegration argument is ignored because IntegrationMode was supplied."
  }
}

$resolvedIntegrationMode = _Resolve-IntegrationMode -RequestedMode $IntegrationMode -RequestedExplicit:$modeParameterSpecified -LegacyBool:$legacyNormalizedValue -LegacyExplicit:$legacyIncludeSpecified

if ($modeParameterSpecified -and $legacyIncludeSpecified -and $legacyNormalizedValue -ne $null) {
  $legacyMode = if ($legacyNormalizedValue) { 'include' } else { 'exclude' }
  if ($legacyMode -ne $resolvedIntegrationMode) {
    Write-Warning ("IntegrationMode '{0}' overrides legacy IncludeIntegration value '{1}'." -f $IntegrationMode, $IncludeIntegration)
  }
}

switch ($resolvedIntegrationMode) {
  'include' {
    $script:includeIntegrationBool = $true
    $script:integrationModeReason = 'mode:include'
  }
  'exclude' {
    $script:includeIntegrationBool = $false
    $script:integrationModeReason = 'mode:exclude'
  }
  default {
    $autoDecision = _Resolve-AutoIntegrationPreference -Default:$false
    $script:includeIntegrationBool = [bool]$autoDecision.Include
    $script:integrationModeReason = "auto:$($autoDecision.Source)"
  }
}
$script:integrationModeResolved = $resolvedIntegrationMode
$includeIntegrationBool = [bool]$script:includeIntegrationBool
$script:fastModeTemporarilySet = $false
if (-not $includeIntegrationBool) {
  $fastPesterPresent = $false
  $fastTestsPresent = $false
  try { if (Get-Item -Path Env:FAST_PESTER -ErrorAction Stop) { $fastPesterPresent = $true } } catch {}
  try { if (Get-Item -Path Env:FAST_TESTS -ErrorAction Stop) { $fastTestsPresent = $true } } catch {}
  if (-not $fastPesterPresent -and -not $fastTestsPresent) {
    $env:FAST_PESTER = '1'
    $script:fastModeTemporarilySet = $true
  }
}

# Session lock support (optional)
$sessionLockEnabled = $false
try { if ($env:SESSION_LOCK_ENABLED -match '^(?i:1|true|yes|on)$') { $sessionLockEnabled = $true } } catch {}
if (-not $sessionLockEnabled) { try { if ($env:CLAIM_PESTER_LOCK -match '^(?i:1|true|yes|on)$') { $sessionLockEnabled = $true } } catch {} }
$lockGroup = 'pester-selfhosted'
if ($sessionLockEnabled -and $env:SESSION_LOCK_GROUP) { $lockGroup = $env:SESSION_LOCK_GROUP }
$lockAcquired = $false
$lockForce = $false
try { if ($env:SESSION_LOCK_FORCE -match '^(?i:1|true|yes|on)$') { $lockForce = $true } } catch {}
$sessionLockStrict = $false
try {
  if ($env:SESSION_LOCK_STRICT) {
    $sessionLockStrict = (_IsTruthyEnv $env:SESSION_LOCK_STRICT)
  } elseif ($env:GITHUB_ACTIONS -eq 'true') {
    $sessionLockStrict = $true
  }
} catch {}
$localDispatcherMode = (_IsTruthyEnv $env:LOCAL_DISPATCHER)

function Invoke-SessionLock {
  param([string]$Action,[string]$Group,[switch]$Force)
  $scriptPath = Join-Path (Get-Location) 'tools/Session-Lock.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) { return $false }
  $invokeArgs = @('-Action', $Action, '-Group', $Group)
  if ($Force) { $invokeArgs += '-ForceTakeover' }
  try {
    & $scriptPath @invokeArgs | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch {
    Write-Warning "Session lock $Action failed: $($_.Exception.Message)"
    return $false
  }
}

# Derive effective timeout seconds (seconds param takes precedence if >0)
$effectiveTimeoutSeconds = 0
if ($TimeoutSeconds -gt 0) { $effectiveTimeoutSeconds = [double]$TimeoutSeconds }
elseif ($TimeoutMinutes -gt 0) { $effectiveTimeoutSeconds = [double]$TimeoutMinutes * 60 }

# Schema version identifiers for emitted JSON artifacts (increment on breaking schema changes)
$SchemaSummaryVersion  = '1.7.1'
$SchemaFailuresVersion = '1.0.0'
$SchemaManifestVersion = '1.0.0'
${SchemaLeakReportVersion} = '1.0.0'
${SchemaDiagnosticsVersion} = '1.1.0'

if ($localDispatcherMode) {
  Write-Host "::notice::Local dispatcher mode (reduced verbosity, soft session lock)" -ForegroundColor DarkGray
}

if ($sessionLockEnabled) {
  Write-Host "::notice::Attempting to acquire session lock '$lockGroup'" -ForegroundColor DarkGray
  if ($lockForce) { Write-Host "::notice::Session lock force takeover enabled" -ForegroundColor DarkGray }
  $lockAcquired = Invoke-SessionLock -Action 'Acquire' -Group $lockGroup -Force:$lockForce
  if (-not $lockAcquired) {
    if ($sessionLockStrict) {
      throw "Failed to acquire session lock '$lockGroup'. Set SESSION_LOCK_FORCE=1 to allow takeover or unset SESSION_LOCK_ENABLED."
    } else {
      Write-Warning "Session lock acquire failed; continuing without lock (SESSION_LOCK_STRICT disabled, LOCAL_DISPATCHER=$localDispatcherMode)."
      $sessionLockEnabled = $false
    }
  }
}

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
      } catch {
        Write-Warning "Failed to normalize failures JSON: $_"
      }
    }
  } catch {
    Write-Warning "Ensure-FailuresJson encountered an error: $_"
  }
}

function Test-ResultsDirectoryWritable {
  param(
    [Parameter(Mandatory)][string]$Path
  )
  try {
    $item = $null
    if (Test-Path -LiteralPath $Path) {
      $item = Get-Item -LiteralPath $Path -ErrorAction Stop
      if (-not $item.PSIsContainer) {
        throw [InvalidOperationException]::new("Results path points to a file: $Path")
      }
    } else {
      $item = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop
    }

    $probe = Join-Path $Path ('write-check-' + ([guid]::NewGuid().ToString('N')) + '.tmp')
    try {
      Set-Content -LiteralPath $probe -Value 'probe' -Encoding UTF8 -ErrorAction Stop
    } catch {
      throw [InvalidOperationException]::new("Results directory is not writable: $Path. $($_.Exception.Message)")
    } finally {
      try { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {
    throw $_
  }
}

function Clear-DispatcherGuardCrumb {
  param(
    [Parameter(Mandatory)][string]$Root
  )
  try {
    $guardDir = Join-Path $Root 'tests/results/_diagnostics'
    $guardPath = Join-Path $guardDir 'guard.json'
    if (Test-Path -LiteralPath $guardPath -PathType Leaf) {
      Remove-Item -LiteralPath $guardPath -Force -ErrorAction Stop
      Write-Host "[guard] Cleared stale dispatcher guard crumb: $guardPath" -ForegroundColor DarkGray
    }
  } catch {
    Write-Warning ("[guard] Failed to clear stale dispatcher guard crumb: {0}" -f $_.Exception.Message)
  }
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
    # Include rendered compare report(s) if present
    $cmpPath = Join-Path $Directory 'compare-report.html'
    if (Test-Path -LiteralPath $cmpPath) {
      $artifacts += [PSCustomObject]@{ file = 'compare-report.html'; type = 'htmlCompare' }
    }
    # Include results index if present
    $idxPath = Join-Path $Directory 'results-index.html'
    if (Test-Path -LiteralPath $idxPath) {
      $artifacts += [PSCustomObject]@{ file = 'results-index.html'; type = 'htmlIndex' }
    }
    try {
      $extraHtml = @(Get-ChildItem -LiteralPath $Directory -Filter '*compare-report*.html' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'compare-report.html' })
      foreach ($h in $extraHtml) {
        $artifacts += [PSCustomObject]@{ file = $h.Name; type = 'htmlCompare' }
      }
    } catch {}
    
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
    $trailPath = Join-Path $Directory 'pester-artifacts-trail.json'
    if (Test-Path -LiteralPath $trailPath) {
      $artifacts += [PSCustomObject]@{ file = 'pester-artifacts-trail.json'; type = 'jsonTrail' }
    }
    $sessionIdx = Join-Path $Directory 'session-index.json'
    if (Test-Path -LiteralPath $sessionIdx) {
      $artifacts += [PSCustomObject]@{ file = 'session-index.json'; type = 'jsonSessionIndex' }
    }
    $leakPath = Join-Path $Directory 'pester-leak-report.json'
    if (Test-Path -LiteralPath $leakPath) {
      $artifacts += [PSCustomObject]@{ file = 'pester-leak-report.json'; type = 'jsonLeaks'; schemaVersion = $SchemaLeakReportVersion }
    }
    # Optional diagnostics files (result shapes)
    $diagTxt = Join-Path $Directory 'result-shapes.txt'
    if (Test-Path -LiteralPath $diagTxt) {
      $artifacts += [PSCustomObject]@{ file = 'result-shapes.txt'; type = 'textDiagnostics' }
    }
    $diagJson = Join-Path $Directory 'result-shapes.json'
    if (Test-Path -LiteralPath $diagJson) {
      $artifacts += [PSCustomObject]@{ file = 'result-shapes.json'; type = 'jsonDiagnostics'; schemaVersion = ${SchemaDiagnosticsVersion} }
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
Write-Host ("  Integration Mode: {0}" -f $script:integrationModeResolved)
Write-Host ("  Include Integration: {0}" -f ([bool]$includeIntegrationBool))
if ($script:integrationModeReason) { Write-Host ("    Mode Source: {0}" -f $script:integrationModeReason) -ForegroundColor DarkGray }
if ($legacyIncludeSpecified) { Write-Host ("  Legacy IncludeIntegration Argument: {0}" -f $IncludeIntegration) -ForegroundColor DarkGray }
Write-Host "  Results Path: $ResultsPath"
Write-Host "  JSON Summary File: $JsonSummaryPath"
Write-Host "  Emit Failures JSON Always: $EmitFailuresJsonAlways"
Write-Host "  Timeout Minutes: $TimeoutMinutes"
Write-Host "  Timeout Seconds: $TimeoutSeconds"
Write-Host "  Max Test Files: $MaxTestFiles"
Write-Host "  Clean LabVIEW before: $CleanLabVIEW"
Write-Host "  Clean after run: $CleanAfter"
Write-Host "  Track Artifacts: $TrackArtifacts"
if ($ArtifactGlobs) { Write-Host ("  Artifact Roots: {0}" -f ($ArtifactGlobs -join ', ')) }
Write-Host "  Detect Leaks: $DetectLeaks"
Write-Host "  Fail On Leaks: $FailOnLeaks"
if ($DetectLeaks) {
  $dbgLeakTargets = if ($LeakProcessPatterns -and $LeakProcessPatterns.Count -gt 0) { $LeakProcessPatterns } else { @('LVCompare','LabVIEW') }
  Write-Host ("  Leak Targets: {0}" -f ($dbgLeakTargets -join ', '))
  Write-Host ("  Leak Grace Seconds: {0}" -f $LeakGraceSeconds)
  Write-Host ("  Kill Leaks: {0}" -f $KillLeaks)
}
Write-Host ""

if ($disableSingleInvoker) {
  if ($__SingleInvokerRequested -eq '1' -or $localDispatcherMode) {
    Write-Host '::notice::Single-invoker disabled via DISABLE_SINGLE_INVOKER=1.' -ForegroundColor DarkGray
  }
  $script:UseSingleInvoker = $false
}
elseif ($__SingleInvokerRequested -eq '1') {
  try {
    $modPath = Join-Path $PSScriptRoot 'scripts/Pester-Invoker.psm1'
    if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) { $modPath = Join-Path $PSScriptRoot 'Pester-Invoker.psm1' }
    if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) { throw "Pester-Invoker.psm1 not found" }
    Import-Module $modPath -Force
  } catch {
    Write-Error ("Single-invoker requested but module import failed: {0}" -f $_.Exception.Message)
    exit 1
  }
  $script:UseSingleInvoker = $true
  Write-Host "Single-invoker mode: step-based outer loop will run via scripts/Pester-Invoker.psm1" -ForegroundColor Yellow
}
elseif ($localDispatcherMode) {
  # Local dispatcher implies non-CI, prefer single-invoker to avoid Start-Job fan-out
  try {
    $modPath = Join-Path $PSScriptRoot 'scripts/Pester-Invoker.psm1'
    if (-not (Test-Path -LiteralPath $modPath -PathType Leaf)) { $modPath = Join-Path $PSScriptRoot 'Pester-Invoker.psm1' }
    if (Test-Path -LiteralPath $modPath -PathType Leaf) {
      Import-Module $modPath -Force
      $script:UseSingleInvoker = $true
      Write-Host "::notice::Local dispatcher forcing single-invoker (avoids Start-Job)" -ForegroundColor DarkGray
    } else {
      Write-Host "::notice::Local dispatcher requested single-invoker, but module not found; continuing normal path" -ForegroundColor DarkYellow
    }
  } catch {
    Write-Host "::notice::Local dispatcher single-invoker import failed: $($_.Exception.Message)" -ForegroundColor DarkYellow
  }
}
if (-not (Test-Path Variable:\script:UseSingleInvoker)) {
  $script:UseSingleInvoker = $false
} elseif (-not $script:UseSingleInvoker) {
  $script:UseSingleInvoker = $false
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

Clear-DispatcherGuardCrumb -Root $root

if ($GuardResetOnly) {
  Write-Host '[guard] Guard reset only mode requested; exiting before dispatcher startup.' -ForegroundColor DarkGray
  exit 0
}

try {
  Test-ResultsDirectoryWritable -Path $resultsDir
} catch {
  $guardMsg = $_.Exception.Message
  try {
    $diagDir = Join-Path $root 'tests/results/_diagnostics'
    if (-not (Test-Path -LiteralPath $diagDir -PathType Container)) {
      New-Item -ItemType Directory -Force -Path $diagDir | Out-Null
    }
    $crumb = [pscustomobject]@{
      schema = 'dispatcher-results-guard/v1'
      at     = (Get-Date).ToString('o')
      path   = $resultsDir
      message= $guardMsg
    }
    $crumb | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $diagDir 'guard.json') -Encoding utf8
  } catch {}
  Write-Error ($guardMsg + ' (guard crumb: tests/results/_diagnostics/guard.json)')
  exit 1
}

if ($labviewPidTrackerLoaded) {
  $trackerPath = Join-Path $resultsDir '_agent' 'labview-pid.json'
  $script:labviewPidTrackerPath = $trackerPath
  $script:labviewPidTrackerFinalState = $null
  $script:labviewPidTrackerFinalized = $false
  $script:labviewPidTrackerFinalizedSource = $null
  $script:labviewPidTrackerFinalizedContext = $null
  $script:labviewPidTrackerFinalizedContextSource = $null
  try {
    $script:labviewPidTrackerState = Start-LabVIEWPidTracker -TrackerPath $trackerPath -Source 'dispatcher:init'
    if ($script:labviewPidTrackerState) {
      if ($script:labviewPidTrackerState.Pid) {
        $modeText = if ($script:labviewPidTrackerState.Reused) { 'Reusing existing' } else { 'Tracking detected' }
        Write-Host ("[labview-pid] {0} LabVIEW.exe PID {1}." -f $modeText, $script:labviewPidTrackerState.Pid) -ForegroundColor DarkGray
      } else {
        Write-Host '[labview-pid] LabVIEW.exe not running at tracker initialization.' -ForegroundColor DarkGray
      }
    }
  } catch {
    Write-Warning ("LabVIEW PID tracker initialization failed: {0}" -f $_.Exception.Message)
  }
  try {
    if (-not (Get-Variable -Name labviewPidTrackerFinalizer -Scope Script -ErrorAction SilentlyContinue)) {
      $script:labviewPidTrackerFinalizer = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PSEngineEvent]::Exiting) -Action {
        $context = [ordered]@{ stage = 'engine-exit'; reason = 'engine-event' }
        $finalTracker = _Finalize-LabVIEWPidTracker -Context $context -Source 'dispatcher:engine-exit'
        if ($finalTracker -and $script:labviewPidTrackerFinalizedSource -eq 'dispatcher:engine-exit') {
          if ($finalTracker.Pid) {
            if ($finalTracker.Running) {
              Write-Host ("[labview-pid] LabVIEW.exe PID {0} still running at dispatcher exit." -f $finalTracker.Pid) -ForegroundColor DarkGray
            } else {
              Write-Host ("[labview-pid] LabVIEW.exe PID {0} not running at dispatcher exit." -f $finalTracker.Pid) -ForegroundColor DarkGray
            }
          }
        }
      }
    }
  } catch {
    Write-Warning ("Failed to register LabVIEW PID tracker finalizer: {0}" -f $_.Exception.Message)
  }
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

# Lightweight helpers to close LVCompare/LabVIEW (Windows-only). Best-effort; never throw.
function _Stop-ProcsSafely {
  param([string[]]$Names)
  foreach ($n in $Names) {
    try { Stop-Process -Name $n -Force -ErrorAction SilentlyContinue } catch {}
  }
}
function _Report-Procs {
  param([string[]]$Names)
  try {
    $live = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $Names -contains $_.ProcessName })
    if ($live.Count -gt 0) {
      $list = ($live | Select-Object -First 5 | ForEach-Object { "{0}(PID {1})" -f $_.ProcessName,$_.Id }) -join ', '
      Write-Host "[proc] still running: $list" -ForegroundColor DarkYellow
    } else {
      Write-Host "[proc] none running: $($Names -join ', ')" -ForegroundColor DarkGray
    }
  } catch {}
}

# Summarize targeted processes (for diagnostics in artifact trail)
function _Get-ProcsSummary {
  param([string[]]$Names)
  try {
    $live = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $Names -contains $_.ProcessName })
    $arr = @()
    foreach ($p in $live) { $arr += [pscustomobject]@{ name=$p.ProcessName; pid=$p.Id; startTime=$p.StartTime } }
    return $arr
  } catch { return @() }
}

# Find processes by name patterns (wildcards allowed, case-insensitive)
function _Find-ProcsByPattern {
  param([string[]]$Patterns)
  try {
    if (-not $Patterns -or $Patterns.Count -eq 0) { return @() }
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    $hits = @()
    foreach ($p in $all) {
      foreach ($pat in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pat)) { continue }
        if ($p.ProcessName -like $pat) { $hits += $p; break }
      }
    }
    return $hits
  } catch { return @() }
}

# Stop jobs safely matching Pester-related names
function _Stop-JobsSafely {
  param([System.Collections.IEnumerable]$Jobs)
  foreach ($j in $Jobs) {
    try { Stop-Job -Job $j -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } catch {}
  }
}

# Resolve artifact roots against repo root
function _Resolve-ArtifactRoots {
  param([string[]]$Roots,[string]$Base)
  $uniq = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($r in $Roots) {
    if ([string]::IsNullOrWhiteSpace($r)) { continue }
    $path = if ([System.IO.Path]::IsPathRooted($r)) { $r } else { Join-Path $Base $r }
    try { $full = (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).Path } catch { $full = $path }
    [void]$uniq.Add($full)
  }
  return @($uniq)
}

# Build file snapshot with SHA256 (best-effort)
function _Build-Snapshot {
  param([string[]]$Roots,[string]$Base)
  $index = @{}
  foreach ($dir in $Roots) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      try {
        $rel = if ($f.FullName.StartsWith($Base,[System.StringComparison]::OrdinalIgnoreCase)) { $f.FullName.Substring($Base.Length).TrimStart('\\','/') } else { $f.FullName }
        $hash = $null
        try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
        $index[$rel] = [pscustomobject]@{ path=$rel; length=$f.Length; lastWrite=($f.LastWriteTimeUtc.ToString('o')); sha256=$hash }
      } catch {}
    }
  }
  return $index
}

# Hard gate: never start tests while LabVIEW.exe is running
$labviewOpen = @(_Find-ProcsByPattern -Patterns @('LabVIEW') )
if ($labviewOpen.Count -gt 0) {
  Write-Warning ("Detected running LabVIEW.exe processes: {0}" -f (($labviewOpen | ForEach-Object { $_.Id }) -join ','))
  Write-Host 'Attempting to stop LabVIEW.exe before starting tests (policy: LVCompare-only interface)' -ForegroundColor Yellow
  _Stop-ProcsSafely -Names @('LabVIEW')
  # Wait briefly and re-check
  $deadlinesec = 10
  $t0 = Get-Date
  do {
    Start-Sleep -Milliseconds 250
    $labviewOpen = @(_Find-ProcsByPattern -Patterns @('LabVIEW') )
  } while ($labviewOpen.Count -gt 0 -and ((Get-Date) - $t0).TotalSeconds -lt $deadlinesec)
  if ($labviewOpen.Count -gt 0) {
    Write-Error 'LabVIEW.exe is still running after best-effort stop; aborting to avoid unstable run.'
    exit 1
  }
}

function Write-SessionIndex {
  param(
    [Parameter(Mandatory)] [string]$ResultsDirectory,
    [Parameter(Mandatory)] [string]$SummaryJsonPath
  )
  try {
    if (-not (Test-Path -LiteralPath $ResultsDirectory -PathType Container)) { return }
    $idx = [ordered]@{
      schema           = 'session-index/v1'
      schemaVersion    = '1.0.0'
      generatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
      resultsDir       = $ResultsDirectory
      includeIntegration = [bool]$includeIntegrationBool
      integrationMode    = $script:integrationModeResolved
      integrationSource  = $script:integrationModeReason
      files            = [ordered]@{}
    }
    $runnerProfile = $null
    try {
      if (-not (Get-Command -Name Get-RunnerProfile -ErrorAction SilentlyContinue)) {
        $repoRoot = Split-Path -Parent $PSCommandPath
        $runnerModule = Join-Path $repoRoot 'tools/RunnerProfile.psm1'
        if (Test-Path -LiteralPath $runnerModule -PathType Leaf) {
          Import-Module $runnerModule -Force
        }
      }
      if (Get-Command -Name Get-RunnerProfile -ErrorAction SilentlyContinue) {
        $runnerProfile = Get-RunnerProfile
      }
    } catch {}
    $addIf = {
      param($name,$file)
      $p = Join-Path $ResultsDirectory $file
      if (Test-Path -LiteralPath $p -PathType Leaf) { $idx.files[$name] = $file }
    }
    & $addIf 'pesterResultsXml' 'pester-results.xml'
    & $addIf 'pesterSummaryTxt' 'pester-summary.txt'
    $jsonLeaf = Split-Path -Leaf $SummaryJsonPath
    if ($jsonLeaf) {
      & $addIf 'pesterSummaryJson' $jsonLeaf
      # Optional: attach summary counts for convenience
      try {
        $sumPath = Join-Path $ResultsDirectory $jsonLeaf
        if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
          $s = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop
          $idx['summary'] = [ordered]@{
            total       = $s.total
            passed      = $s.passed
            failed      = $s.failed
            errors      = $s.errors
            skipped     = $s.skipped
            duration_s  = $s.duration_s
            meanTest_ms = $s.meanTest_ms
            p95Test_ms  = $s.p95Test_ms
            maxTest_ms  = $s.maxTest_ms
            schemaVersion = $s.schemaVersion
          }
          # Derive simple session status and pre-render a concise step-summary block
          $status = if (($s.failed -gt 0) -or ($s.errors -gt 0)) { 'fail' } else { 'ok' }
          $idx['status'] = $status
          # Compute repo-relative results path when possible
          $resRel = $ResultsDirectory
          try {
            $cwd = (Get-Location).Path
            if ($resRel.StartsWith($cwd,[System.StringComparison]::OrdinalIgnoreCase)) {
              $rel = $resRel.Substring($cwd.Length).TrimStart('\\','/')
              if (-not [string]::IsNullOrWhiteSpace($rel)) { $resRel = $rel }
            }
          } catch {}
          $lines = @()
          $lines += '### Session Overview'
          $lines += ''
          $lines += ("- Status: {0}" -f $status)
          $lines += ("- Total: {0} | Passed: {1} | Failed: {2} | Errors: {3} | Skipped: {4}" -f $s.total,$s.passed,$s.failed,$s.errors,$s.skipped)
          $lines += ("- Duration (s): {0}" -f $s.duration_s)
          $lines += ("- Include Integration: {0}" -f [bool]$includeIntegrationBool)
          $lines += ("- Integration Mode: {0}" -f $script:integrationModeResolved)
          if ($script:integrationModeReason) { $lines += ("- Integration Source: {0}" -f $script:integrationModeReason) }
          $lines += ''
          $lines += 'Artifacts (paths):'
          $present = @()
          foreach ($k in @('pesterSummaryJson','pesterResultsXml','pesterSummaryTxt','artifactManifestJson','artifactTrailJson','leakReportJson','compareReportHtml','resultsIndexHtml')) {
            if ($idx.files[$k]) { $present += (Join-Path $resRel $idx.files[$k]) }
          }
          foreach ($p in $present) { $lines += ("- {0}" -f $p) }
          $runnerNameForSummary = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'name' -and $runnerProfile.name) { $runnerProfile.name } else { $env:RUNNER_NAME }
          $runnerOsForSummary = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'os' -and $runnerProfile.os) { $runnerProfile.os } else { $env:RUNNER_OS }
          $runnerArchForSummary = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'arch' -and $runnerProfile.arch) { $runnerProfile.arch } else { $env:RUNNER_ARCH }
          $runnerEnvSummary = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'environment' -and $runnerProfile.environment) { $runnerProfile.environment } else { $env:RUNNER_ENVIRONMENT }
          $runnerMachineSummary = if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'machine' -and $runnerProfile.machine) { $runnerProfile.machine } else { [System.Environment]::MachineName }
          $runnerLabelsSummary = @()
          try {
            if ($runnerProfile -and $runnerProfile.PSObject.Properties.Name -contains 'labels') {
              $runnerLabelsSummary = @($runnerProfile.labels | Where-Object { $_ -and $_ -ne '' })
            } elseif (Get-Command -Name Get-RunnerLabels -ErrorAction SilentlyContinue) {
              $runnerLabelsSummary = @(Get-RunnerLabels | Where-Object { $_ -and $_ -ne '' })
            }
          } catch {}
          if ($runnerNameForSummary -or $runnerOsForSummary -or $runnerArchForSummary -or $runnerEnvSummary -or $runnerMachineSummary -or ($runnerLabelsSummary -and $runnerLabelsSummary.Count -gt 0)) {
            $lines += ''
            $lines += '### Runner'
            $lines += ''
            if ($runnerNameForSummary) { $lines += ("- Name: {0}" -f $runnerNameForSummary) }
            if ($runnerOsForSummary -and $runnerArchForSummary) {
              $lines += ("- OS/Arch: {0}/{1}" -f $runnerOsForSummary,$runnerArchForSummary)
            } elseif ($runnerOsForSummary) {
              $lines += ("- OS: {0}" -f $runnerOsForSummary)
            } elseif ($runnerArchForSummary) {
              $lines += ("- Arch: {0}" -f $runnerArchForSummary)
            }
            if ($runnerEnvSummary) { $lines += ("- Environment: {0}" -f $runnerEnvSummary) }
            if ($runnerMachineSummary) { $lines += ("- Machine: {0}" -f $runnerMachineSummary) }
            if ($runnerLabelsSummary -and $runnerLabelsSummary.Count -gt 0) {
              $lines += ("- Labels: {0}" -f (($runnerLabelsSummary | Select-Object -Unique) -join ', '))
            }
          }
          $idx['stepSummary'] = ($lines -join "`n")
        }
      } catch {}
    }
    & $addIf 'pesterFailuresJson' 'pester-failures.json'
    & $addIf 'artifactManifestJson' 'pester-artifacts.json'
    & $addIf 'artifactTrailJson' 'pester-artifacts-trail.json'
    & $addIf 'leakReportJson' 'pester-leak-report.json'
    & $addIf 'compareReportHtml' 'compare-report.html'
    & $addIf 'resultsIndexHtml' 'results-index.html'
    try {
      $driftRoot = Join-Path (Get-Location) 'results/fixture-drift'
      if (Test-Path -LiteralPath $driftRoot -PathType Container) {
        $dirs = Get-ChildItem -LiteralPath $driftRoot -Directory
        $tsDirs = @($dirs | Where-Object { $_.Name -match '^[0-9]{8}T[0-9]{6}Z$' })
        $latest = if ($tsDirs.Count -gt 0) { $tsDirs | Sort-Object Name -Descending | Select-Object -First 1 } else { $dirs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 }
        if ($latest) {
          $sumPath = Join-Path $latest.FullName 'drift-summary.json'
          $status = $null
          if (Test-Path -LiteralPath $sumPath) {
            try { $j = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop; $status = $j.status } catch {}
          }
          $idx['drift'] = [ordered]@{
            latestRunDir  = $latest.FullName
            latestSummary = (Test-Path -LiteralPath $sumPath) ? $sumPath : $null
            status        = $status
          }
        }
      }
    } catch {}
    # Optional run context (CI / GitHub)
    try {
      $runContext = [ordered]@{
        repository  = $env:GITHUB_REPOSITORY
        ref         = (if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } else { $env:GITHUB_REF })
        commitSha   = $env:GITHUB_SHA
        workflow    = $env:GITHUB_WORKFLOW
        runId       = $env:GITHUB_RUN_ID
        runAttempt  = $env:GITHUB_RUN_ATTEMPT
      }
      if ($env:GITHUB_JOB) { $runContext['job'] = $env:GITHUB_JOB }
      if ($env:RUNNER_NAME) { $runContext['runner'] = $env:RUNNER_NAME }
      if ($env:RUNNER_OS) { $runContext['runnerOS'] = $env:RUNNER_OS }
      if ($env:RUNNER_ARCH) { $runContext['runnerArch'] = $env:RUNNER_ARCH }
      if ($env:RUNNER_ENVIRONMENT) { $runContext['runnerEnvironment'] = $env:RUNNER_ENVIRONMENT }
      $machineName = try { [System.Environment]::MachineName } catch { $null }
      if ($machineName) { $runContext['runnerMachine'] = $machineName }
      if ($env:RUNNER_TRACKING_ID) { $runContext['runnerTrackingId'] = $env:RUNNER_TRACKING_ID }
      if ($env:ImageOS) { $runContext['runnerImageOS'] = $env:ImageOS }
      if ($env:ImageVersion) { $runContext['runnerImageVersion'] = $env:ImageVersion }
      if ($runnerProfile) {
        $map = @{
          name         = 'runner'
          os           = 'runnerOS'
          arch         = 'runnerArch'
          environment  = 'runnerEnvironment'
          machine      = 'runnerMachine'
          trackingId   = 'runnerTrackingId'
          imageOS      = 'runnerImageOS'
          imageVersion = 'runnerImageVersion'
        }
        foreach ($entry in $map.GetEnumerator()) {
          $source = $entry.Key
          $target = $entry.Value
          if ($runnerProfile.PSObject.Properties.Name -contains $source) {
            $value = $runnerProfile.$source
            if ($null -ne $value -and "$value" -ne '') {
              $runContext[$target] = $value
            }
          }
        }
        if ($runnerProfile.PSObject.Properties.Name -contains 'labels') {
          $labelValues = @($runnerProfile.labels | Where-Object { $_ -and $_ -ne '' })
          if ($labelValues.Count -gt 0) { $runContext['runnerLabels'] = $labelValues }
        }
      } elseif (Get-Command -Name Get-RunnerLabels -ErrorAction SilentlyContinue) {
        try {
          $labelsFallback = @(Get-RunnerLabels | Where-Object { $_ -and $_ -ne '' })
          if ($labelsFallback.Count -gt 0) { $runContext['runnerLabels'] = $labelsFallback }
        } catch {}
      }
      $idx['runContext'] = $runContext
      # Optional well-known URLs for convenience (UI pages)
      if ($env:GITHUB_REPOSITORY) {
        $repoUrl = "https://github.com/$($env:GITHUB_REPOSITORY)"
        $urls = [ordered]@{ repository = $repoUrl }
        if ($env:GITHUB_RUN_ID) { $urls.run = "$repoUrl/actions/runs/$($env:GITHUB_RUN_ID)" }
        if ($env:GITHUB_SHA)     { $urls.commit = "$repoUrl/commit/$($env:GITHUB_SHA)" }
        # If PR number can be parsed from ref (refs/pull/{n}/...), include a PR URL
        try {
          $ref = $env:GITHUB_REF
          if ($ref -and $ref -match 'refs/pull/(?<num>\d+)/') {
            $urls.pullRequest = "$repoUrl/pull/$($Matches.num)"
          }
        } catch {}
        $idx['urls'] = $urls
      }
    } catch {}

    # Handshake markers (optional): find latest marker and attach to runContext
    try {
      $handshakeFiles = @(Get-ChildItem -Path $ResultsDirectory -Recurse -Filter 'handshake-*.json' -File -ErrorAction SilentlyContinue)
      if ($handshakeFiles.Count -gt 0) {
        $hsSorted = @($handshakeFiles | Sort-Object LastWriteTimeUtc)
        $last = $hsSorted[-1]
        $lastRel = try { ($last.FullName).Substring(((Get-Location).Path).Length).TrimStart('\\','/') } catch { $last.Name }
        $lastJson = $null
        try { $lastJson = Get-Content -LiteralPath $last.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
        $lastPhase = if ($lastJson.name) { [string]$lastJson.name } else { [string]([IO.Path]::GetFileNameWithoutExtension($last.Name) -replace '^handshake-','') }
        $lastAtUtc = if ($lastJson.atUtc) { [string]$lastJson.atUtc } else { $last.LastWriteTimeUtc.ToString('o') }
        $lastStatus = if ($lastJson.status) { [string]$lastJson.status } else { $null }
        $markerRel = @()
        foreach ($f in $hsSorted) {
          $rp = try { ($f.FullName).Substring(((Get-Location).Path).Length).TrimStart('\\','/') } catch { $f.Name }
          $markerRel += $rp
        }
        if (-not $idx['runContext']) { $idx['runContext'] = [ordered]@{} }
        $idx.runContext['handshake'] = [ordered]@{
          lastPhase   = $lastPhase
          lastAtUtc   = $lastAtUtc
          lastStatus  = $lastStatus
          markerPaths = $markerRel
        }
        # Extend step summary with handshake excerpt if present
        try {
          $handshakeLines = @()
          $handshakeLines += ("- Handshake Last Phase: {0}" -f $lastPhase)
          if ($lastStatus) { $handshakeLines += ("- Handshake Last Status: {0}" -f $lastStatus) }
          $firstTwo = @($markerRel | Select-Object -First 2)
          foreach ($m in $firstTwo) { $handshakeLines += ("- Marker: {0}" -f $m) }
          if ($idx['stepSummary']) { $idx['stepSummary'] = $idx['stepSummary'] + "`n`n" + ($handshakeLines -join "`n") } else { $idx['stepSummary'] = ($handshakeLines -join "`n") }
        } catch {}
      }
    } catch {}

    $dest = Join-Path $ResultsDirectory 'session-index.json'
    $idx | ConvertTo-Json -Depth 6 | Out-File -FilePath $dest -Encoding utf8 -ErrorAction Stop
    Write-Host "Session index written to: $dest" -ForegroundColor Gray
  } catch { Write-Warning "Failed to write session index: $_" }
}

# Optional pre-clean of LabVIEW if explicitly requested
if ($CleanLabVIEW) {
  Write-Host "Pre-run cleanup: stopping LabVIEW.exe" -ForegroundColor DarkGray
  _Stop-ProcsSafely -Names @('LabVIEW')
  Start-Sleep -Milliseconds 200
  _Report-Procs -Names @('LabVIEW')
}

# Artifact tracking pre-snapshot (optional)
$script:artifactTrail = $null
$preIndex = $null
$artifactRoots = @()
if ($TrackArtifacts) {
  if (-not $ArtifactGlobs -or $ArtifactGlobs.Count -eq 0) {
    $ArtifactGlobs = @('tests/results','results','tmp-agg/results','scratch-schema-test/results')
  }
  $artifactRoots = _Resolve-ArtifactRoots -Roots $ArtifactGlobs -Base $root
  try { $preIndex = _Build-Snapshot -Roots $artifactRoots -Base $root } catch { $preIndex = @{} }
}

# Count test files (respect single file mode)
if ($limitToSingle) {
  $testFiles = @([IO.FileInfo]::new($singleTestFile))
  Write-Host "Running single test file: $singleTestFile" -ForegroundColor Green
} else {
  $testFiles = @(Get-ChildItem -Path $testsDir -Filter '*.Tests.ps1' -Recurse -File | Sort-Object FullName)
  $originalTestFileCount = $testFiles.Count
  # Pre-filter integration files entirely (stronger than tag exclusion) when integration disabled, unless explicitly overridden.
  if (-not $includeIntegrationBool -and ($env:DISABLE_INTEGRATION_FILE_PREFILTER -ne '1')) {
    $before = $testFiles.Count
    $testFiles = @($testFiles | Where-Object { $_.Name -notmatch '\.Integration\.Tests\.ps1$' })
    $removed = $before - $testFiles.Count
    if ($removed -gt 0) { Write-Host "Prefiltered $removed integration test file(s) (file-level exclusion)" -ForegroundColor DarkGray }
  }

  # Optional: Derive test manifest (TypeScript) and pre-exclude Integration-tagged files
  $manifestPath = Join-Path $resultsDir '_agent/test-manifest.json'
  $usedNodeDiscovery = $false
  if ($UseDiscoveryManifest) {
    try {
      $npm = Get-Command npm -ErrorAction SilentlyContinue
      if ($npm) {
        Write-Host 'Deriving test manifest via TypeScript (node tools/npm/run-script.mjs tests:discover)...' -ForegroundColor DarkGray
        & $npm.Path run tests:discover --silent | Write-Host
        $usedNodeDiscovery = $true
      } else {
        Write-Host 'npm CLI not found; falling back to PowerShell discovery scan.' -ForegroundColor DarkYellow
      }
    } catch {
      Write-Warning "TypeScript discovery failed or unavailable: $_"
    }
  }
  # PowerShell fallback manifest writer (only if Node discovery not used)
  if (-not $usedNodeDiscovery -and $UseDiscoveryManifest) {
    try {
      $entries = @()
      foreach ($f in $testFiles) {
        $text = try { Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { '' }
        $isInt = if ($text) { ($text -match '(?im)-Tag\s*(?:''Integration''|"Integration"|Integration\b)') } else { $false }
        $entries += [pscustomobject]@{
          path = ($f.FullName.Substring(((Get-Location).Path).Length)).TrimStart('\\','/')
          fullPath = $f.FullName
          tags = @($isInt ? 'Integration' : @())
        }
      }
      $manifest = [pscustomobject]@{
        schema = 'pester-test-manifest/v1'
        generatedAt = (Get-Date).ToString('o')
        root = (Get-Location).Path
        testsDir = (Resolve-Path -LiteralPath $testsDir).Path
        counts = [pscustomobject]@{
          total = $entries.Count
          integration = @($entries | Where-Object { $_.tags -contains 'Integration' }).Count
          unit = @($entries | Where-Object { $_.tags.Count -eq 0 }).Count
        }
        files = $entries
      }
      $outDir = Split-Path -Parent $manifestPath
      if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
      $manifest | ConvertTo-Json -Depth 5 | Out-File -FilePath $manifestPath -Encoding utf8
      Write-Host ("PowerShell discovery wrote manifest: {0}" -f $manifestPath) -ForegroundColor DarkGray
    } catch {
      Write-Warning "Failed to write fallback discovery manifest: $_"
    }
  }

  # If manifest exists and integration disabled, pre-exclude files with Integration tag
  if (-not $includeIntegrationBool -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    try {
      $m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
      $intPaths = @($m.files | Where-Object { $_.tags -and ($_.tags -contains 'Integration') } | ForEach-Object { $_.fullPath })
      if ($intPaths.Count -gt 0) {
        $set = New-Object System.Collections.Generic.HashSet[string]
        foreach($p in $intPaths){ [void]$set.Add(($p.ToLowerInvariant())) }
        $before = $testFiles.Count
        $testFiles = @($testFiles | Where-Object { -not $set.Contains($_.FullName.ToLowerInvariant()) })
        $removed = $before - $testFiles.Count
        if ($removed -gt 0) { Write-Host ("Manifest pre-excluded {0} Integration file(s)." -f $removed) -ForegroundColor Cyan }
      }
    } catch {
      Write-Warning "Failed to apply manifest-based pre-exclusion: $_"
    }
  }

  # Fallback: when manifest isn't used, perform content-based tag prefilter for Integration
  if (-not $includeIntegrationBool -and ($env:DISABLE_INTEGRATION_TAG_PREFILTER -ne '1') -and (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf))) {
    $beforeTag = $testFiles.Count
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($f in $testFiles) {
      $nameIsIntegration = ($f.Name -match '\.Integration\.Tests\.ps1$')
      if ($nameIsIntegration) { continue }
      $text = try { Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { '' }
      $hasTag = $false
      if ($text) { $hasTag = ($text -match '(?im)-Tag\s*(?:''Integration''|"Integration"|Integration\b)') }
      if (-not $hasTag) { [void]$filtered.Add($f) }
    }
    $testFiles = @($filtered.ToArray())
    $removedTag = $beforeTag - $testFiles.Count
    if ($removedTag -gt 0) { Write-Host ("Content pre-excluded {0} Integration-tagged file(s)." -f $removedTag) -ForegroundColor Cyan }
  }
  # Apply IncludePatterns/ExcludePatterns if provided using shared selector logic
  $patternFilters = Invoke-DispatcherIncludeExcludeFilter `
    -Files $testFiles `
    -IncludePatterns $IncludePatterns `
    -ExcludePatterns $ExcludePatterns
  $testFiles = @($patternFilters.Files)
  if ($patternFilters.Include.Applied) {
    $includePatternsText = if ($patternFilters.Include.Patterns) { ($patternFilters.Include.Patterns -join ', ') } else { '' }
    Write-Host (
      "Applied IncludePatterns ({0}) -> kept {1}/{2} file(s)" -f $includePatternsText, $patternFilters.Include.After, $patternFilters.Include.Before
    ) -ForegroundColor DarkGray
  }
  if ($patternFilters.Exclude.Applied -and $patternFilters.Exclude.Removed -gt 0) {
    $excludePatternsText = if ($patternFilters.Exclude.Patterns) { ($patternFilters.Exclude.Patterns -join ', ') } else { '' }
    Write-Host (
      "Applied ExcludePatterns ({0}) -> removed {1} file(s)" -f $excludePatternsText, $patternFilters.Exclude.Removed
    ) -ForegroundColor DarkGray
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

$patternSelfTestSuppressed = $false
$suppressPatternSelfTest = Test-EnvTruthy $env:SUPPRESS_PATTERN_SELFTEST
if ($suppressPatternSelfTest)
{
  $patternSelfTestLeaf = 'Invoke-PesterTests.Patterns.Tests.ps1'
  if (-not (Get-Variable -Name originalTestFileCount -Scope Script -ErrorAction SilentlyContinue))
  {
    $originalTestFileCount = $testFiles.Count
  }

  $suppressionResult = Invoke-DispatcherPatternSelfTestSuppression -Files $testFiles -PatternSelfTestLeaf $patternSelfTestLeaf -SingleTestFile $singleTestFile -LimitToSingle:$limitToSingle
  $testFiles = @($suppressionResult.Files)
  $removedBySuppress = $suppressionResult.Removed
  if ($removedBySuppress -gt 0)
  {
    $patternSelfTestSuppressed = $true
    Write-Host (
      "[patterns] SUPPRESS_PATTERN_SELFTEST=1 removed {0} pattern self-test file(s) from execution." -f $removedBySuppress
    ) -ForegroundColor DarkGray

    if ($suppressionResult.SingleCleared)
    {
      Write-Host '[patterns] Clearing single-test selection for pattern self-test (suppressed).' -ForegroundColor DarkGray
      $limitToSingle = $false
      $singleTestFile = $null
    }
  }
}

if (-not (Get-Variable -Name maxTestFilesApplied -ErrorAction SilentlyContinue)) {
  $maxTestFilesApplied = $false
}

if (-not (Get-Variable -Name originalTestFileCount -Scope Script -ErrorAction SilentlyContinue)) {
  $originalTestFileCount = $testFiles.Count
}
$selectedTestPaths = @($testFiles | ForEach-Object { $_.FullName })
$selectionReasons = New-Object System.Collections.Generic.List[string]
if ($IncludePatterns -and $IncludePatterns.Count -gt 0) { [void]$selectionReasons.Add('IncludePatterns') }
if ($ExcludePatterns -and $ExcludePatterns.Count -gt 0) { [void]$selectionReasons.Add('ExcludePatterns') }
if ($maxTestFilesApplied) { [void]$selectionReasons.Add('MaxTestFiles') }
if ($selectedTestPaths.Count -lt $originalTestFileCount) { [void]$selectionReasons.Add('SelectionReduced') }
if ($patternSelfTestSuppressed) { [void]$selectionReasons.Add('SuppressPatternSelfTest') }

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
    $jsonObj = [pscustomobject]@{
      total             = 0
      passed            = 0
      failed            = 0
      errors            = 0
      skipped           = 0
      duration_s        = 0.0
      timestamp         = (Get-Date).ToString('o')
      pesterVersion     = ''
      includeIntegration= [bool]$includeIntegrationBool
      integrationMode   = $script:integrationModeResolved
      integrationSource = $script:integrationModeReason
      meanTest_ms       = $null
      p95Test_ms        = $null
      maxTest_ms        = $null
      timedOut          = $false
      discoveryFailures = 0
      schemaVersion     = $SchemaSummaryVersion
    }
    $jsonObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonSummaryEarly -Encoding utf8 -ErrorAction SilentlyContinue
  }

  # Optional: run leak detection even when no tests discovered
  if ($DetectLeaks) {
    try {
      $leakTargets = if ($LeakProcessPatterns -and $LeakProcessPatterns.Count -gt 0) { $LeakProcessPatterns } else { @('LVCompare','LabVIEW') }
      $procsBeforeLeak = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } })
      $jobsBeforeLeak = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } })
      $waitedMs = 0
      if ($LeakGraceSeconds -gt 0) { $ms = [int]([math]::Round($LeakGraceSeconds*1000)); Start-Sleep -Milliseconds $ms; $waitedMs = $ms }
      $procsAfter = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } })
      $pesterJobs = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } })
      $runningJobs = @($pesterJobs | Where-Object { $_.state -eq 'Running' -or $_.state -eq 'NotStarted' })
      $leakDetected = (($procsAfter.Count -gt 0) -or ($runningJobs.Count -gt 0))
      $actions=@(); $killed=@(); $stoppedJobs=@()
      if ($leakDetected -and $KillLeaks) {
        try { foreach ($p in (_Find-ProcsByPattern -Patterns $leakTargets)) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $killed += [pscustomobject]@{ name=$p.ProcessName; pid=$p.Id } } catch {} } if ($killed.Count -gt 0) { $actions += ("killedProcs:{0}" -f $killed.Count) } } catch {}
        try { $jobsForStop = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' }); foreach ($j in $jobsForStop) { $stoppedJobs += [pscustomobject]@{ id=$j.Id; name=$j.Name; state=$j.State } }; _Stop-JobsSafely -Jobs $jobsForStop; if ($jobsForStop.Count -gt 0) { $actions += ("stoppedJobs:{0}" -f $jobsForStop.Count) } } catch {}
        try { $procsAfter = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } }) } catch {}
        try { $pesterJobs = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } }) } catch {}
        $runningJobs = @($pesterJobs | Where-Object { $_.state -eq 'Running' -or $_.state -eq 'NotStarted' })
        $leakDetected = (($procsAfter.Count -gt 0) -or ($runningJobs.Count -gt 0))
      }
      $leakReport = [pscustomobject]@{
        schema         = 'pester-leak-report/v1'
        schemaVersion  = ${SchemaLeakReportVersion}
        generatedAt    = (Get-Date).ToString('o')
        targets        = $leakTargets
        graceSeconds   = $LeakGraceSeconds
        waitedMs       = $waitedMs
        procsBefore    = $procsBeforeLeak
        procsAfter     = $procsAfter
        runningJobs    = $runningJobs
        allJobs        = $pesterJobs
        jobsBefore     = $jobsBeforeLeak
        leakDetected   = $leakDetected
        actions        = $actions
        killedProcs    = $killed
        stoppedJobs    = $stoppedJobs
        notes          = @('Leak = LabVIEW/LVCompare (or configured targets) still running or Pester jobs still active after test run')
      }
      $leakPathOut = Join-Path $resultsDir 'pester-leak-report.json'
      $leakReport | ConvertTo-Json -Depth 6 | Out-File -FilePath $leakPathOut -Encoding utf8 -ErrorAction SilentlyContinue
      if ($leakDetected -and $FailOnLeaks) { Write-Error 'Failing run due to detected leaks (processes/jobs)'; exit 1 }
    } catch { Write-Warning "Leak detection (early-exit) failed: $_" }
  }
  Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryEarly -ManifestVersion $SchemaManifestVersion
  Write-SessionIndex -ResultsDirectory $resultsDir -SummaryJsonPath $jsonSummaryEarly
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

# Optional notice-only guard (off by default)
$script:stuckGuardEnabled = ($env:STUCK_GUARD -eq '1')
$script:hbSec = 15
try { if ($env:LVCI_HEARTBEAT_SEC) { $script:hbSec = [int]$env:LVCI_HEARTBEAT_SEC } } catch { $script:hbSec = 15 }
$script:hbPath = Join-Path $resultsDir 'pester-heartbeat.ndjson'
function _Write-HeartbeatLine {
  param([string]$Type)
  if (-not $script:stuckGuardEnabled) { return }
  try {
    $dir = Split-Path -Parent $script:hbPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $line = @{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); type = $Type } | ConvertTo-Json -Compress
    Add-Content -Path $script:hbPath -Value $line -Encoding UTF8
  } catch {}
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
if ($limitToSingle) {
  $conf.Run.Path = $singleTestFile
}
elseif (-not $limitToSingle -and $selectedTestPaths.Count -gt 0 -and $selectionReasons.Count -gt 0) {
  # Use explicit file list when selection differs from the baseline directory scan
  $conf.Run.Path = $selectedTestPaths
  Write-Host ("  Using explicit test file list ({0})" -f ($selectionReasons -join ', ')) -ForegroundColor Cyan
}
else {
  $conf.Run.Path = $testsDir
}

# Apply integration-tag filtering based on resolved mode
if (-not $includeIntegrationBool) {
  Write-Host "  Excluding Integration-tagged tests" -ForegroundColor Cyan
  $conf.Filter.ExcludeTag = @('Integration')
} else {
  Write-Host "  Including Integration-tagged tests" -ForegroundColor Cyan
}

# Configure output
if ($localDispatcherMode) {
  $conf.Output.Verbosity = 'Normal'
} else {
  $conf.Output.Verbosity = 'Detailed'
}
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

try {
  $verbosity = $conf.Output.Verbosity
} catch { $verbosity = 'Detailed' }
Write-Host ("  Output Verbosity: {0}" -f $verbosity) -ForegroundColor Cyan
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
try {
if (-not $script:UseSingleInvoker) {
  if ($script:stuckGuardEnabled) { _Write-HeartbeatLine 'start' }
  if ($effectiveTimeoutSeconds -gt 0) {
    if ($localDispatcherMode) {
      Write-Host "::notice::Local dispatcher bypassing Start-Job timeout guard; running inline" -ForegroundColor DarkGray
      try {
        $rawOutput = & {
          $InformationPreference = 'Continue'
          Invoke-Pester -Configuration $conf *>&1
        }
        $testEndTime = Get-Date
        $testDuration = $testEndTime - $testStartTime
        foreach ($entry in $rawOutput) {
          if ($entry -is [string]) {
            $capturedOutputLines += $entry
            if ($LiveOutput) { Write-Host $entry }
          } elseif ($null -ne $entry -and ($entry.PSObject.Properties.Name -contains 'Tests') -and -not $result) {
            $result = $entry
          } elseif ($entry -isnot [string]) {
            $textEntry = ($entry | Out-String)
            $capturedOutputLines += $textEntry
            if ($LiveOutput -and $textEntry) { Write-Host $textEntry }
          }
        }
        if (-not $result) {
          $maybe = $rawOutput | Where-Object { $_ -isnot [string] -and ($_.PSObject.Properties.Name -contains 'Tests') }
          if ($maybe) { $result = $maybe[-1] }
        }
      } catch {
        if ($script:stuckGuardEnabled) { _Write-HeartbeatLine 'error'; _Write-HeartbeatLine 'stop' }
        Write-Error "Pester execution failed (inline local-bypass): $_"
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
    } else {
      Write-Host "Executing with timeout guard: $effectiveTimeoutSeconds second(s)" -ForegroundColor Yellow
      if ($localDispatcherMode) { Write-Host "::warning::Local dispatcher unexpected: entering Start-Job path" -ForegroundColor Yellow }
      $job = Start-Job -ScriptBlock { param($c) Invoke-Pester -Configuration $c } -ArgumentList ($conf)
      $partialLogPath = Join-Path $resultsDir 'pester-partial.log'
      $lastWriteLen = 0
      $lastHeartbeat = Get-Date
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
             if ($delta.Trim()) {
               Add-Content -Path $partialLogPath -Value $delta -Encoding UTF8
               if ($LiveOutput) { Write-Host $delta }
             }
             $lastWriteLen = $text.Length
           }
         }
      } catch { }
      if ($script:stuckGuardEnabled) {
        $now = Get-Date
        if ((($now - $lastHeartbeat).TotalSeconds) -ge $script:hbSec) {
          _Write-HeartbeatLine 'beat'
          $lastHeartbeat = $now
        }
      }
      if ($elapsed.TotalSeconds -ge $effectiveTimeoutSeconds) {
        Write-Warning "Pester execution exceeded timeout of $effectiveTimeoutSeconds second(s); stopping job." 
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
        $script:timedOut = $true
        break
      }
      Start-Sleep -Seconds 5
      }
      if (-not $script:timedOut) {
        try { $result = Receive-Job -Job $job -ErrorAction Stop } catch { Write-Error "Failed to retrieve Pester job result: $_" }
      }
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
      $testEndTime = Get-Date
      $testDuration = $testEndTime - $testStartTime
      if ($script:stuckGuardEnabled) {
        if ($script:timedOut) {
          _Write-HeartbeatLine 'timeout'
        } else {
          _Write-HeartbeatLine 'stop'
        }
      }
    }
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
          if ($LiveOutput) { Write-Host $entry }
        } elseif ($null -ne $entry -and ($entry.PSObject.Properties.Name -contains 'Tests') -and -not $result) {
          $result = $entry
        } elseif ($entry -isnot [string]) {
          # Non-string, non-primary result objects (e.g., progress records) -> stringify
          $textEntry = ($entry | Out-String)
          $capturedOutputLines += $textEntry
          if ($LiveOutput -and $textEntry) { Write-Host $textEntry }
        }
      }
      # If PassThru did not surface a result object earlier, attempt to assign from last object
      if (-not $result) {
        $maybe = $rawOutput | Where-Object { $_ -isnot [string] -and ($_.PSObject.Properties.Name -contains 'Tests') }
        if ($maybe) { $result = $maybe[-1] }
      }
    } catch {
      if ($script:stuckGuardEnabled) {
        _Write-HeartbeatLine 'error'
        _Write-HeartbeatLine 'stop'
      }
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
    if ($script:stuckGuardEnabled) { _Write-HeartbeatLine 'stop' }
  }
} else {
  # Single-invoker outer loop path
  Write-Host "[single-invoker] Running step-based outer loop..." -ForegroundColor Yellow
  $testStartTime = Get-Date
  if ($script:stuckGuardEnabled) { _Write-HeartbeatLine 'start' }

  function _Is-IntegrationFile {
    param([System.IO.FileInfo]$File)
    try {
      $content = Get-Content -LiteralPath $File.FullName -TotalCount 200 -ErrorAction Stop | Out-String
      # Detect explicit Integration tag usage on Describe/Context lines only (case-insensitive)
      $pattern = '(?im)^\s*(Describe|Context)\b.*-Tag\s*(?:''Integration''|"Integration"|Integration\b)'
      return ([regex]::IsMatch($content, $pattern))
    } catch { return $false }
  }

  $invSession = New-PesterInvokerSession -ResultsRoot $resultsDir -Isolation $Isolation
  $unitFiles = @()
  $integrationFiles = @()
  foreach ($f in $testFiles) {
    if (_Is-IntegrationFile -File $f) { $integrationFiles += $f } else { $unitFiles += $f }
  }

  $failedFilesList = New-Object System.Collections.Generic.List[string]
  $allResults = New-Object System.Collections.Generic.List[psobject]
  $aggregate = [ordered]@{ passed=0; failed=0; skipped=0; errors=0 }

  function _Run-Files {
    param([System.IO.FileInfo[]]$Files,[string]$Category)
    $localFails = 0
    foreach ($file in $Files) {
      $res = Invoke-PesterFile -Session $invSession -File $file.FullName -Category $Category -EmitIts:$EmitIts -MaxSeconds $MaxFileSeconds
      $allResults.Add($res) | Out-Null
      $aggregate.passed  += [int]$res.Counts.passed
      $aggregate.failed  += [int]$res.Counts.failed
      $aggregate.skipped += [int]$res.Counts.skipped
      $aggregate.errors  += [int]$res.Counts.errors
      if ($res.TimedOut -or $res.Counts.failed -gt 0 -or $res.Counts.errors -gt 0) {
        $failedFilesList.Add($file.FullName) | Out-Null
        $localFails++
      }
    }
    return $localFails
  }

  $unitFailCount = _Run-Files -Files $unitFiles -Category 'Unit'
  $intFailCount  = 0
  if ($includeIntegrationBool -and $unitFailCount -eq 0 -and $integrationFiles.Count -gt 0) {
    $intFailCount = _Run-Files -Files $integrationFiles -Category 'Integration'
  } elseif ($includeIntegrationBool -and $unitFailCount -gt 0) {
    Write-Host "[single-invoker] Skipping Integration due to Unit failures." -ForegroundColor Yellow
  }

  $sorted = @($allResults | Sort-Object -Property DurationMs -Descending)
  $topSlowList = if ($sorted.Count -gt 5) { $sorted[0..4] } else { $sorted }
  Complete-PesterInvokerSession -Session $invSession -FailedFiles $failedFilesList -TopSlow $topSlowList | Out-Null

  # Emit a minimal NUnit XML root with aggregated totals for downstream parsers
  try {
    if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
    $totalAgg = [int]($aggregate.passed + $aggregate.failed + $aggregate.errors + $aggregate.skipped)
    $xmlAgg = @(
      '<?xml version="1.0" encoding="utf-8"?>',
      ('<test-results name="single-invoker" total="{0}" errors="{1}" failures="{2}" not-run="{3}" inconclusive="0" ignored="0" skipped="{3}" invalid="0">' -f $totalAgg,$aggregate.errors,$aggregate.failed,$aggregate.skipped),
      '  <environment nunit-version="3.0" />',
      '  <culture-info />',
      '</test-results>'
    ) -join [Environment]::NewLine
    $xmlOutPath = Join-Path $resultsDir 'pester-results.xml'
    Set-Content -LiteralPath $xmlOutPath -Value $xmlAgg -Encoding UTF8
  } catch { Write-Warning "[single-invoker] Failed to write aggregated NUnit XML: $_" }

  $testEndTime = Get-Date
  $testDuration = $testEndTime - $testStartTime
  if ($script:stuckGuardEnabled) { _Write-HeartbeatLine 'stop' }
  
  # Emit minimal JSON summary so downstream artifact/indices have data without running the classic path
  try {
    $jsonSummaryPath = Join-Path $resultsDir $JsonSummaryPath
    $loadedPester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    $jsonObj = [PSCustomObject]@{
      total              = [int]($aggregate.passed + $aggregate.failed + $aggregate.errors + $aggregate.skipped)
      passed             = [int]$aggregate.passed
      failed             = [int]$aggregate.failed
      errors             = [int]$aggregate.errors
      skipped            = [int]$aggregate.skipped
      duration_s         = [math]::Round($testDuration.TotalSeconds, 6)
      timestamp          = (Get-Date).ToString('o')
      pesterVersion      = $loadedPester.Version.ToString()
      includeIntegration = [bool]$includeIntegrationBool
      schemaVersion      = $SchemaSummaryVersion
      timedOut           = $false
      discoveryFailures  = 0
    }
    if (-not (Test-Path -LiteralPath $resultsDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null }
    $jsonObj | ConvertTo-Json -Depth 4 | Out-File -FilePath $jsonSummaryPath -Encoding utf8 -ErrorAction Stop
  } catch { Write-Warning "[single-invoker] Failed to write JSON summary: $_" }

  # Write artifact manifest and session index for parity
  try { Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath $jsonSummaryPath -ManifestVersion $SchemaManifestVersion } catch {}
  try { Write-SessionIndex -ResultsDirectory $resultsDir -SummaryJsonPath $jsonSummaryPath } catch {}

  # Print concise outcome and exit early to avoid re-entering the classic path
  $failTotal = [int]($aggregate.failed + $aggregate.errors)
  if ($failTotal -gt 0) {
    Write-Host ("? Tests failed: failures={0} errors={1}" -f $aggregate.failed,$aggregate.errors) -ForegroundColor Red
    # Optional cleanup per policy
    if ($CleanAfter) { _Stop-ProcsSafely -Names @('LabVIEW'); if ($script:CleanLVCompare) { _Stop-ProcsSafely -Names @('LVCompare') } }
    if ($sessionLockEnabled -and $lockAcquired) { try { Invoke-SessionLock -Action 'Release' -Group $lockGroup | Out-Null } catch {} }
    exit 1
  }
  Write-Host "? All tests passed!" -ForegroundColor Green
  if ($CleanAfter) { _Stop-ProcsSafely -Names @('LabVIEW'); if ($script:CleanLVCompare) { _Stop-ProcsSafely -Names @('LVCompare') } }
  if ($sessionLockEnabled -and $lockAcquired) { try { Invoke-SessionLock -Action 'Release' -Group $lockGroup | Out-Null } catch {} }
  exit 0
}

if ($script:timedOut) {
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

# Artifact tracking post-snapshot and delta
if ($TrackArtifacts) {
  try {
    $postIndex = _Build-Snapshot -Roots $artifactRoots -Base $root
    $preKeys = @($preIndex.Keys)
    $postKeys = @($postIndex.Keys)
    $created = @($postKeys | Where-Object { $preKeys -notcontains $_ } | Sort-Object)
    $deleted = @($preKeys | Where-Object { $postKeys -notcontains $_ } | Sort-Object)
    $modified = @()
    foreach ($k in ($postKeys | Where-Object { $preKeys -contains $_ })) {
      $a = $preIndex[$k]; $b = $postIndex[$k]
      if ($null -eq $a -or $null -eq $b) { continue }
      if ($a.length -ne $b.length -or $a.sha256 -ne $b.sha256 -or $a.lastWrite -ne $b.lastWrite) { $modified += $k }
    }
    $script:artifactTrail = [pscustomobject]@{
      schema       = 'pester-artifact-trail/v1'
      generatedAt  = (Get-Date).ToString('o')
      scanRoots    = $artifactRoots
      basePath     = $root
      hashAlgorithm= 'SHA256'
      preCount     = $preIndex.Count
      postCount    = $postIndex.Count
      created      = @($created | ForEach-Object { $postIndex[$_] })
      deleted      = @($deleted | ForEach-Object { $preIndex[$_] })
      modified     = @($modified | Sort-Object | ForEach-Object { [pscustomobject]@{ path=$_; before=$preIndex[$_]; after=$postIndex[$_] } })
      procsBefore  = @(_Get-ProcsSummary -Names @('LVCompare','LabVIEW'))
      procsAfter   = @()
    }
  } catch { Write-Warning "Artifact trail build failed: $_" }
}

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

  if ($script:timedOut) {
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
      $sorted = @($_timingDurations | Sort-Object)
      $maxMs = [math]::Round(($sorted[-1]),2)
      $pIndex = [int][math]::Floor(0.95 * ($sorted.Count - 1))
      if ($pIndex -ge 0) { $p95Ms = [math]::Round($sorted[$pIndex],2) }
    }
  }
} catch { Write-Warning "Failed to compute timing metrics: $_" }

# Record LabVIEW PID tracker state with Pester totals
if ($labviewPidTrackerLoaded -and $script:labviewPidTrackerPath) {
  try {
    $context = [ordered]@{
      stage             = 'post-summary'
      total             = $total
      failed            = $failed
      errors            = $errors
      skipped           = $skipped
      discoveryFailures = $discoveryFailureCount
      timedOut          = [bool]$script:timedOut
    }
    if ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
      $context['pid'] = $script:labviewPidTrackerState.Pid
    }
    $trackerState = _Finalize-LabVIEWPidTracker -Context $context -Source 'dispatcher:summary'
    if ($trackerState -and $script:labviewPidTrackerFinalizedSource -eq 'dispatcher:summary') {
      if ($trackerState.Pid) {
        $status = if ($trackerState.Running) { 'still running' } else { 'not running' }
        Write-Host ("[labview-pid] LabVIEW.exe PID {0} {1} after Pester summary." -f $trackerState.Pid,$status) -ForegroundColor DarkGray
      } else {
        Write-Host '[labview-pid] LabVIEW.exe not running at Pester summary finalization.' -ForegroundColor DarkGray
      }
    }
  } catch {
    Write-Warning ("LabVIEW PID tracker summary finalization failed: {0}" -f $_.Exception.Message)
  }
}

# Stop heartbeat (if enabled) before rendering summaries
# Generate summary
$summaryLines = @(
  "=== Pester Test Summary ===",
  "Total Tests: $total",
  "Passed: $passed",
  "Failed: $failed",
  "Errors: $errors",
  "Skipped: $skipped",
  "Duration: $($testDuration.TotalSeconds.ToString('F2'))s" + $(if ($meanMs) { " (mean=${meanMs}ms p95=${p95Ms}ms max=${maxMs}ms)" } else { '' }) + $(if ($script:timedOut) { ' (TIMED OUT)' } else { '' })
)
if ($labviewPidTrackerLoaded) {
  $trackerSummaryLine = $null
  $final = if ($script:labviewPidTrackerFinalState) { $script:labviewPidTrackerFinalState } else { $script:labviewPidTrackerState }
  $finalReused = $null
  if ($script:labviewPidTrackerFinalState -and $script:labviewPidTrackerFinalState.PSObject.Properties['Reused']) {
    try { $finalReused = [bool]$script:labviewPidTrackerFinalState.Reused } catch { $finalReused = $null }
  } elseif ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Reused']) {
    try { $finalReused = [bool]$script:labviewPidTrackerState.Reused } catch { $finalReused = $null }
  }
  $reusedLabel = if ($null -eq $finalReused) { 'reused=unknown' } else { "reused=$finalReused" }
  if ($script:labviewPidTrackerFinalState -and $script:labviewPidTrackerFinalState.Pid) {
    $stateLabel = if ($script:labviewPidTrackerFinalState.Running) { 'running' } else { 'not running' }
    $trackerSummaryLine = "LabVIEW PID Tracker: PID $($script:labviewPidTrackerFinalState.Pid) ($stateLabel, $reusedLabel)"
  } elseif ($final -and $final.PSObject.Properties['Pid'] -and $final.Pid) {
    $trackerSummaryLine = "LabVIEW PID Tracker: PID $($final.Pid) (state unavailable, $reusedLabel)"
  } else {
    $trackerSummaryLine = 'LabVIEW PID Tracker: no LabVIEW.exe detected'
  }
  if ($trackerSummaryLine) { $summaryLines += $trackerSummaryLine }
}
$summary = $summaryLines -join [Environment]::NewLine

Write-Host ""
Write-Host $summary -ForegroundColor $(if ($failed -eq 0 -and $errors -eq 0) { 'Green' } else { 'Red' })
Write-Host ""

# Emit high-level selection summary to GitHub Step Summary (if available)
if ($env:GITHUB_STEP_SUMMARY -and -not $DisableStepSummary) {
  try {
    $selectedNames = @()
    foreach ($item in $testFiles) {
      if ($null -eq $item) { continue }
      if ($item -is [System.IO.FileInfo]) {
        $selectedNames += $item.Name
      } elseif ($item -is [string]) {
        $selectedNames += (Split-Path -Leaf $item)
      } elseif ($item.PSObject.Properties['FullName']) {
        $selectedNames += (Split-Path -Leaf $item.FullName)
      }
    }
    $selectedNames = $selectedNames | Sort-Object -Unique
    $discoveryDescriptor = if ($usedNodeDiscovery) { 'manifest' } else { 'manual-scan' }
    $includeText = ([bool]$includeIntegrationBool).ToString().ToLowerInvariant()
    $modeText = if ($script:integrationModeResolved) { $script:integrationModeResolved } else { 'auto' }
    $modeSource = if ($script:integrationModeReason) { $script:integrationModeReason } else { 'auto' }
    $repoSlug = $env:GITHUB_REPOSITORY
    $refName = $env:GITHUB_REF_NAME
    $sampleId = $env:EV_SAMPLE_ID
    $workflowName = if ($env:GITHUB_WORKFLOW) { $env:GITHUB_WORKFLOW } else { 'ci-orchestrated.yml' }
    $ghCommand = "gh workflow run `"$workflowName`""
    if ($repoSlug) { $ghCommand += (" -R {0}" -f $repoSlug) }
    if ($refName) { $ghCommand += (" -r `"{0}`"" -f $refName) }
    $ghCommand += (" -f include_integration={0}" -f $includeText)
    if ($sampleId) { $ghCommand += (" -f sample_id={0}" -f $sampleId) }

    $stepSummaryLines = @()
    $stepSummaryLines += ''
    $stepSummaryLines += '### Selected Tests'
    $stepSummaryLines += ''
    if ($selectedNames.Count -eq 0) {
      $stepSummaryLines += '- (none)'
    } else {
      foreach ($name in $selectedNames) { $stepSummaryLines += ("- {0}" -f $name) }
    }
    $stepSummaryLines += ''
    $stepSummaryLines += '### Configuration'
    $stepSummaryLines += ''
    $stepSummaryLines += ("- IncludeIntegration: {0}" -f ([bool]$includeIntegrationBool))
    $stepSummaryLines += ("- Integration Mode: {0}" -f $modeText)
    $stepSummaryLines += ("- Integration Source: {0}" -f $modeSource)
    $stepSummaryLines += ("- Discovery: {0}" -f $discoveryDescriptor)
    if ($labviewPidTrackerLoaded -and $script:labviewPidTrackerPath) {
      $stepSummaryLines += ''
      $stepSummaryLines += '### LabVIEW PID Tracker'
      $stepSummaryLines += ''
      $stepSummaryLines += ("- Tracker Path: {0}" -f $script:labviewPidTrackerPath)

      $initialPid = 'none'
      $initialRunning = 'unknown'
      $initialReused = 'unknown'
      if ($script:labviewPidTrackerState) {
        if ($script:labviewPidTrackerState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerState.Pid) {
          $initialPid = $script:labviewPidTrackerState.Pid
        }
        if ($script:labviewPidTrackerState.PSObject.Properties['Running']) {
          try { $initialRunning = [bool]$script:labviewPidTrackerState.Running } catch { $initialRunning = 'unknown' }
        }
        if ($script:labviewPidTrackerState.PSObject.Properties['Reused']) {
          try { $initialReused = [bool]$script:labviewPidTrackerState.Reused } catch { $initialReused = 'unknown' }
        }
      }
      $stepSummaryLines += ("- Initial: pid={0}, running={1}, reused={2}" -f $initialPid,$initialRunning,$initialReused)

      $finalPid = 'none'
      $finalRunning = 'unknown'
      $finalReused = 'unknown'
      if ($script:labviewPidTrackerFinalState) {
        if ($script:labviewPidTrackerFinalState.PSObject.Properties['Pid'] -and $script:labviewPidTrackerFinalState.Pid) {
          $finalPid = $script:labviewPidTrackerFinalState.Pid
        }
        if ($script:labviewPidTrackerFinalState.PSObject.Properties['Running']) {
          try { $finalRunning = [bool]$script:labviewPidTrackerFinalState.Running } catch { $finalRunning = 'unknown' }
        }
        if ($script:labviewPidTrackerFinalState.PSObject.Properties['Reused']) {
          try { $finalReused = [bool]$script:labviewPidTrackerFinalState.Reused } catch { $finalReused = 'unknown' }
        } elseif ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Reused']) {
          try { $finalReused = [bool]$script:labviewPidTrackerState.Reused } catch { $finalReused = 'unknown' }
        }
      }
      $stepSummaryLines += ("- Final: pid={0}, running={1}, reused={2}" -f $finalPid,$finalRunning,$finalReused)

      $finalContext = $null
      $contextSource = $null
      if ($script:labviewPidTrackerFinalState -and $script:labviewPidTrackerFinalState.PSObject.Properties['Context'] -and $script:labviewPidTrackerFinalState.Context) {
        $finalContext = _Normalize-LabVIEWPidContext -Value $script:labviewPidTrackerFinalState.Context
        $contextSource = 'tracker'
      } elseif ($script:labviewPidTrackerFinalizedContext) {
        $finalContext = _Normalize-LabVIEWPidContext -Value $script:labviewPidTrackerFinalizedContext
        if ($script:labviewPidTrackerFinalizedContextSource) {
          $contextSource = $script:labviewPidTrackerFinalizedContextSource
        } else {
          $contextSource = 'cached'
        }
      }
      $sourceSuffix = if ($contextSource) { " ($contextSource)" } else { '' }
      if ($finalContext -and $finalContext.PSObject.Properties['stage']) {
        $stageValue = $finalContext.stage
        $stepSummaryLines += ("- Final Context Stage{0}: {1}" -f $sourceSuffix,$stageValue)
      } elseif ($finalContext) {
        $ctxKeys = @($finalContext.PSObject.Properties.Name)
        if ($ctxKeys.Count -gt 0) {
          $stepSummaryLines += ("- Final Context Keys{0}: {1}" -f $sourceSuffix,($ctxKeys -join ', '))
        }
      } elseif ($contextSource) {
        $stepSummaryLines += ("- Final Context Source: {0}" -f $contextSource)
      }
    }
    $stepSummaryLines += ''
    $stepSummaryLines += '### Re-run (gh)'
    $stepSummaryLines += ''
    $stepSummaryLines += ("- {0}" -f $ghCommand)
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($stepSummaryLines -join [Environment]::NewLine) -Encoding utf8
  } catch {
    $errMsg = $_.Exception.Message
    $warnLine = [string]::Concat('Step summary append failed: ', $errMsg)
    Write-Host $warnLine -ForegroundColor DarkYellow
  }
}

# Append optional Guard block to step summary (notice-only)
if ($script:stuckGuardEnabled -and $env:GITHUB_STEP_SUMMARY) {
  try {
    $hbCount = 0; $last = ''
    if (Test-Path -LiteralPath $script:hbPath) {
      $lines = Get-Content -LiteralPath $script:hbPath -ErrorAction SilentlyContinue
      $hbCount = @($lines | Where-Object { $_ -like '*"type":"beat"*' }).Count
      $last = $lines | Select-Object -Last 1
    }
    $g = @('### Guard','')
    $g += ('- Enabled: {0}' -f $script:stuckGuardEnabled)
    $g += ('- Heartbeats: {0}' -f $hbCount)
    if ($script:hbPath) { $g += ('- Heartbeat file: {0}' -f $script:hbPath) }
    if ($partialLogPath) { $g += ('- Partial log: {0}' -f $partialLogPath) }
    $g -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8 -ErrorAction SilentlyContinue
  } catch { Write-Host "::notice::Guard summary append failed: $_" }
}

# Optional: emit result shape diagnostics for $result.Tests (types and property presence)
if ($EmitResultShapeDiagnostics) {
  try {
    $txtPath = Join-Path $resultsDir 'result-shapes.txt'
    $jsonPath = Join-Path $resultsDir 'result-shapes.json'
    $diag = [ordered]@{
      schema       = 'pester-result-shapes/v1'
      schemaVersion= ${SchemaDiagnosticsVersion}
      generatedAt  = (Get-Date).ToString('o')
      totalEntries = 0
      byType       = @()
      overall      = [ordered]@{ hasPath=0; hasTags=0 }
    }
    if ($result -and $result.Tests) {
      $tests = @($result.Tests)
      $diag.totalEntries = $tests.Count
      $groups = $tests | Group-Object { $_.GetType().FullName }
      # deterministic ordering
      $groups = $groups | Sort-Object Name
      $overallHasPath = 0
      $overallHasTags = 0
      foreach ($g in $groups) {
        $arr = @($g.Group)
        $hasPath = @($arr | Where-Object { $_.PSObject.Properties.Name -contains 'Path' }).Count
        $hasTags = @($arr | Where-Object { $_.PSObject.Properties.Name -contains 'Tags' }).Count
        $overallHasPath += $hasPath
        $overallHasTags += $hasTags
        $typeName = ($arr[0].GetType().Name)
        $entry = [ordered]@{
          typeName   = $typeName
          typeFull   = $g.Name
          count      = $arr.Count
          hasPathCnt = $hasPath
          hasTagsCnt = $hasTags
        }
        $diag.byType += [pscustomobject]$entry
      }
      $diag.overall.hasPath = $overallHasPath
      $diag.overall.hasTags = $overallHasTags
    }
    # Write text summary
    $lines = @()
    $lines += '=== Pester Result Shapes ==='
    $lines += ("Generated: {0}" -f $diag.generatedAt)
    $lines += ("Total entries: {0}" -f $diag.totalEntries)
    if ($diag.byType.Count -gt 0) {
      $lines += 'By type:'
      foreach ($t in $diag.byType) {
        $lines += ("  - {0} ({1}): count={2}; hasPath={3}; hasTags={4}" -f $t.typeName,$t.typeFull,$t.count,$t.hasPathCnt,$t.hasTagsCnt)
      }
      $lines += ("Overall: hasPath={0}/{1}; hasTags={2}/{1}" -f $diag.overall.hasPath,$diag.totalEntries,$diag.overall.hasTags)
    } else {
      $lines += 'No result test entries available.'
    }
    Set-Content -LiteralPath $txtPath -Value ($lines -join "`n") -Encoding UTF8
    # Write JSON summary
    ($diag | ConvertTo-Json -Depth 4) | Out-File -FilePath $jsonPath -Encoding utf8 -ErrorAction Stop
    Write-Host ("Result shape diagnostics written: {0}, {1}" -f $txtPath,$jsonPath) -ForegroundColor Gray
  } catch { Write-Warning "Failed to emit result shape diagnostics: $_" }
}

# Write summary to file
$summaryPath = Join-Path $resultsDir 'pester-summary.txt'
try {
  $summary | Out-File -FilePath $summaryPath -Encoding utf8 -ErrorAction Stop
  Write-Host "Summary written to: $summaryPath" -ForegroundColor Gray
} catch {
  Write-Warning "Failed to write summary file: $_"
}

# Optional: append diagnostics footer to Pester summary
try {
  $diagJsonPath = Join-Path $resultsDir 'result-shapes.json'
  $diagTotalEntries = $null; $diagHasPath = $null; $diagHasTags = $null
  if (Test-Path -LiteralPath $diagJsonPath -PathType Leaf) {
    try {
      $diagJsonRaw = Get-Content -LiteralPath $diagJsonPath -Raw
      $diagObj = $diagJsonRaw | ConvertFrom-Json -ErrorAction Stop
      $diagTotalEntries = [int]$diagObj.totalEntries
      $diagHasPath = [int]$diagObj.overall.hasPath
      $diagHasTags = [int]$diagObj.overall.hasTags
    } catch {}
  }
  if ($null -eq $diagTotalEntries -and $result -and $result.Tests) {
    try { $testsLocal=@($result.Tests); $diagTotalEntries=$testsLocal.Count; $diagHasPath=@($testsLocal | Where-Object { $_.PSObject.Properties.Name -contains 'Path' }).Count; $diagHasTags=@($testsLocal | Where-Object { $_.PSObject.Properties.Name -contains 'Tags' }).Count } catch {}
  }
  if ($null -ne $diagTotalEntries) {
    function _pctTxt { param([int]$n,[int]$d) if ($d -le 0) { return '0%' } ('{0:P1}' -f ([double]$n/[double]$d)) }
    $pPath = _pctTxt $diagHasPath $diagTotalEntries
    $pTags = _pctTxt $diagHasTags $diagTotalEntries
    $footer = @()
    $footer += ''
    $footer += '---'
    $footer += 'Diagnostics Summary'
    $footer += ''
    $footer += ('Total entries: {0}' -f $diagTotalEntries)
    $footer += ('Has Path: {0} ({1})' -f $diagHasPath,$pPath)
    $footer += ('Has Tags: {0} ({1})' -f $diagHasTags,$pTags)
    Add-Content -LiteralPath $summaryPath -Value ($footer -join "`n") -Encoding utf8
  }
} catch { Write-Host "(warn) failed to append diagnostics footer: $_" -ForegroundColor DarkYellow }

# Persist artifact trail (if collected)
if ($TrackArtifacts -and $script:artifactTrail) {
  try {
    # Update procsAfter right before writing trail
    $script:artifactTrail.procsAfter = @(_Get-ProcsSummary -Names @('LVCompare','LabVIEW'))
    $trailPath = Join-Path $resultsDir 'pester-artifacts-trail.json'
    $script:artifactTrail | ConvertTo-Json -Depth 6 | Out-File -FilePath $trailPath -Encoding utf8 -ErrorAction Stop
    Write-Host "Artifact trail written to: $trailPath" -ForegroundColor Gray
  } catch { Write-Warning "Failed to write artifact trail: $_" }
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
    duration_s         = [math]::Round($testDuration.TotalSeconds, 6)
    timestamp          = (Get-Date).ToString('o')
    pesterVersion      = $loadedPester.Version.ToString()
    includeIntegration = [bool]$includeIntegrationBool
    meanTest_ms        = $meanMs
    p95Test_ms         = $p95Ms
    maxTest_ms         = $maxMs
    schemaVersion      = $SchemaSummaryVersion
    timedOut           = $script:timedOut
    discoveryFailures  = $discoveryFailureCount
  }

  if ($labviewPidTrackerLoaded) {
    try {
      $trackerPayload = [ordered]@{
        enabled = $true
        path    = $script:labviewPidTrackerPath
      }
      if ($script:labviewPidTrackerState) {
        $initialBlock = [ordered]@{
          pid         = if ($script:labviewPidTrackerState.Pid) { [int]$script:labviewPidTrackerState.Pid } else { $null }
          running     = [bool]$script:labviewPidTrackerState.Running
          reused      = [bool]$script:labviewPidTrackerState.Reused
          candidates  = @($script:labviewPidTrackerState.Candidates | Where-Object { $_ -ne $null })
          observation = $script:labviewPidTrackerState.Observation
        }
        $trackerPayload['initial'] = [pscustomobject]$initialBlock
      }
      if ($script:labviewPidTrackerFinalState) {
        $finalBlock = [ordered]@{
          pid         = if ($script:labviewPidTrackerFinalState.Pid) { [int]$script:labviewPidTrackerFinalState.Pid } else { $null }
          running     = [bool]$script:labviewPidTrackerFinalState.Running
          reused      = if ($script:labviewPidTrackerFinalState.PSObject.Properties['Reused']) { [bool]$script:labviewPidTrackerFinalState.Reused } elseif ($script:labviewPidTrackerState -and $script:labviewPidTrackerState.PSObject.Properties['Reused']) { [bool]$script:labviewPidTrackerState.Reused } else { $null }
          observation = $script:labviewPidTrackerFinalState.Observation
        }
        if ($script:labviewPidTrackerFinalizedSource) { $finalBlock['finalizedSource'] = $script:labviewPidTrackerFinalizedSource }
        $finalContext = $null
        $contextSource = $null
        if ($script:labviewPidTrackerFinalState.PSObject.Properties['Context'] -and $script:labviewPidTrackerFinalState.Context) {
          $finalContext = _Normalize-LabVIEWPidContext -Value $script:labviewPidTrackerFinalState.Context
          $contextSource = 'tracker'
        } elseif ($script:labviewPidTrackerFinalizedContext) {
          $finalContext = _Normalize-LabVIEWPidContext -Value $script:labviewPidTrackerFinalizedContext
          if ($script:labviewPidTrackerFinalizedContextSource) {
            $contextSource = $script:labviewPidTrackerFinalizedContextSource
          } else {
            $contextSource = 'cached'
          }
        }
        if ($finalContext) { $finalBlock['context'] = $finalContext }
        if ($contextSource) { $finalBlock['contextSource'] = $contextSource }
        $trackerPayload['final'] = [pscustomobject]$finalBlock
      }
      Add-Member -InputObject $jsonObj -Name labviewPidTracker -MemberType NoteProperty -Value ([pscustomobject]$trackerPayload)
    } catch {
      Write-Warning ("Failed to append LabVIEW PID tracker summary block: {0}" -f $_.Exception.Message)
    }
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
        $sortedAll = @($_timingDurations | Sort-Object)
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
      if ($script:timedOut) { $overallStatus = 'Timeout'; $severityRank = 4; $flags += 'TimedOut' }
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

# Best-effort: copy any compare report produced by tests into the results directory for standardized artifact pickup
try {
  $destReport = Join-Path $resultsDir 'compare-report.html'
  $candidates = @()
  $fixedCandidates = @(
    (Join-Path $root 'tests' 'results' 'integration-compare-report.html'),
    (Join-Path $root 'tests' 'results' 'compare-report.html'),
    (Join-Path $root 'tests' 'results-single' 'pr-body-compare-report.html')
  )
  foreach ($p in $fixedCandidates) { if (Test-Path -LiteralPath $p -PathType Leaf) { try { $candidates += (Get-Item -LiteralPath $p -ErrorAction SilentlyContinue) } catch {} } }
  try {
    $dynamic = Get-ChildItem -LiteralPath (Join-Path $root 'tests' 'results') -Filter '*compare-report*.html' -Recurse -File -ErrorAction SilentlyContinue
    if ($dynamic) { $candidates += $dynamic }
  } catch {}
  if ($candidates.Count -gt 0) {
    $latest = $candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    # Copy the latest to the canonical filename
    try { Copy-Item -LiteralPath $latest.FullName -Destination $destReport -Force; Write-Host ("Compare report copied to: {0}" -f $destReport) -ForegroundColor Gray } catch { Write-Warning "Failed to copy compare report: $_" }
    # Also copy all candidates preserving their base filenames to the results directory
    foreach ($cand in ($candidates | Sort-Object LastWriteTimeUtc)) {
      try {
        $destName = (Split-Path -Leaf $cand.FullName)
        $destFull = Join-Path $resultsDir $destName
        Copy-Item -LiteralPath $cand.FullName -Destination $destFull -Force -ErrorAction SilentlyContinue
      } catch { Write-Host "(warn) failed to copy extra report '$($cand.FullName)': $_" -ForegroundColor DarkYellow }
    }
    # Generate a small deterministic index HTML linking to all report variants
    try {
  $indexPath = Join-Path $resultsDir 'results-index.html'
      # Gather all report htmls in results dir (including canonical)
  $reports = @(Get-ChildItem -LiteralPath $resultsDir -Filter '*compare-report*.html' -File -ErrorAction SilentlyContinue | Sort-Object Name)
      function _HtmlEncode {
        param([string]$s)
        if ([string]::IsNullOrEmpty($s)) { return '' }
        $t = $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
        return $t
      }
      $now = (Get-Date).ToString('u')
      $lines = @()
      $lines += '<!DOCTYPE html>'
      $lines += '<html lang="en">'
      $lines += '<head><meta charset="utf-8"/><title>Compare Reports Index</title><style>body{font-family:Segoe UI,SegoeUI,Helvetica,Arial,sans-serif;margin:16px} ul{line-height:1.6} .meta{color:#666} code{background:#f5f5f5;padding:2px 4px;border-radius:3px}</style></head>'
      $lines += '<body>'
      $lines += '<h1>Compare Reports Index</h1>'
      $lines += ('<p class=''meta''>Generated at <code>{0}</code></p>' -f (_HtmlEncode $now))
      $lines += ('<p>Total reports: <strong>{0}</strong> — canonical: <code>compare-report.html</code></p>' -f $reports.Count)
      if ($reports.Count -gt 0) {
        $lines += '<ul>'
        foreach ($r in $reports) {
          $nameEnc = _HtmlEncode $r.Name
          $ts = _HtmlEncode ($r.LastWriteTimeUtc.ToString('u'))
          $size = '{0:N0} bytes' -f $r.Length
          $meta = ('last write: {0}; size: {1}' -f $ts, (_HtmlEncode $size))
          $canonicalTag = if ($r.Name -ieq 'compare-report.html') { ' <em class="meta">(canonical)</em>' } else { '' }
          $lines += ('<li><a href="{0}">{0}</a>{2} <span class=''meta''>({1})</span></li>' -f $nameEnc,$meta,$canonicalTag)
        }
        $lines += '</ul>'
      } else {
        $lines += '<p class="meta">No compare-report HTML files found in this results directory.</p>'
      }
      # Diagnostics links (if present)
      try {
        $diagTxt = Join-Path $resultsDir 'result-shapes.txt'
        $diagJson = Join-Path $resultsDir 'result-shapes.json'
        if ((Test-Path -LiteralPath $diagTxt) -or (Test-Path -LiteralPath $diagJson)) {
          $lines += '<hr/>'
          $lines += '<h3>Diagnostics</h3>'
          $lines += '<ul>'
          if (Test-Path -LiteralPath $diagTxt) { $lines += '<li><a href="result-shapes.txt">result-shapes.txt</a></li>' }
          if (Test-Path -LiteralPath $diagJson) { $lines += '<li><a href="result-shapes.json">result-shapes.json</a></li>' }
          $lines += '</ul>'
          # Optional: show a compact summary table if JSON exists
          if (Test-Path -LiteralPath $diagJson) {
            try {
              $diagObj = Get-Content -LiteralPath $diagJson -Raw | ConvertFrom-Json -ErrorAction Stop
              $total = [int]($diagObj.totalEntries)
              $hasPath = [int]($diagObj.overall.hasPath)
              $hasTags = [int]($diagObj.overall.hasTags)
              function _pct { param([int]$num,[int]$den) if ($den -le 0) { return '0%' } else { return ('{0:P1}' -f ([double]$num/[double]$den)) } }
              $pPath = _pct $hasPath $total
              $pTags = _pct $hasTags $total
              $lines += '<table style="border-collapse:collapse;margin-top:8px">'
              $lines += '<thead><tr><th style="text-align:left;padding:4px 8px;border-bottom:1px solid #e5e7eb">Metric</th><th style="text-align:right;padding:4px 8px;border-bottom:1px solid #e5e7eb">Count</th><th style="text-align:right;padding:4px 8px;border-bottom:1px solid #e5e7eb">Percent</th></tr></thead>'
              $lines += '<tbody>'
              $lines += ('<tr><td style="padding:4px 8px">Total entries</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">-</td></tr>' -f $total)
              $lines += ('<tr><td style="padding:4px 8px">Has Path</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">{1}</td></tr>' -f $hasPath,$pPath)
              $lines += ('<tr><td style="padding:4px 8px">Has Tags</td><td style="text-align:right;padding:4px 8px">{0}</td><td style="text-align:right;padding:4px 8px">{1}</td></tr>' -f $hasTags,$pTags)
              $lines += '</tbody></table>'
            } catch { }
          }
        }
      } catch {}
      $lines += '</body></html>'
      Set-Content -LiteralPath $indexPath -Value ($lines -join "`n") -Encoding UTF8
      Write-Host ("Results index written to: {0}" -f $indexPath) -ForegroundColor Gray
    } catch { Write-Host "(warn) failed to write results index: $_" -ForegroundColor DarkYellow }
  }
} catch { Write-Host "(warn) compare report copy step failed: $_" -ForegroundColor DarkYellow }

# Optional: Write diagnostics summary to GitHub Step Summary (Markdown)
try {
  $stepSummary = $env:GITHUB_STEP_SUMMARY
  if ($stepSummary -and -not $DisableStepSummary) {
    $total = $null; $hasPath = $null; $hasTags = $null
    $diagJsonPath = Join-Path $resultsDir 'result-shapes.json'
    if (Test-Path -LiteralPath $diagJsonPath -PathType Leaf) {
      try {
        $diagObj = Get-Content -LiteralPath $diagJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $total = [int]($diagObj.totalEntries)
        $hasPath = [int]($diagObj.overall.hasPath)
        $hasTags = [int]($diagObj.overall.hasTags)
      } catch {}
    }
    # Fallback: derive counts from $result.Tests when JSON not available
    if ($null -eq $total -and $result -and $result.Tests) {
      try {
        $testsLocal = @($result.Tests)
        $total = $testsLocal.Count
        $hasPath = @($testsLocal | Where-Object { $_.PSObject.Properties.Name -contains 'Path' }).Count
        $hasTags = @($testsLocal | Where-Object { $_.PSObject.Properties.Name -contains 'Tags' }).Count
      } catch {}
    }
    if ($null -ne $total) {
      function _pctMd { param([int]$n,[int]$d) if ($d -le 0) { return '0%' } ('{0:P1}' -f ([double]$n/[double]$d)) }
      $pPath = _pctMd $hasPath $total
      $pTags = _pctMd $hasTags $total
      $md = @()
      $md += '### Diagnostics Summary'
      $md += ''
      $md += '| Metric | Count | Percent |'
      $md += '|---|---:|---:|'
      $md += ("| Total entries | {0} | - |" -f $total)
      $md += ("| Has Path | {0} | {1} |" -f $hasPath,$pPath)
      $md += ("| Has Tags | {0} | {1} |" -f $hasTags,$pTags)
      $mdText = ($md -join "`n") + "`n"
      try { $dir = Split-Path -Parent $stepSummary; if ($dir) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue | Out-Null } } catch {}
      Add-Content -LiteralPath $stepSummary -Value $mdText -Encoding utf8
      Write-Host ("Step summary updated: {0}" -f $stepSummary) -ForegroundColor Gray
    }
  }
} catch { Write-Host "(warn) failed to write GitHub Step Summary: $_" -ForegroundColor DarkYellow }

# Leak detection (processes/jobs) and report
if ($DetectLeaks) {
  try {
    # Determine targets and capture pre-state
    $leakTargets = if ($LeakProcessPatterns -and $LeakProcessPatterns.Count -gt 0) { $LeakProcessPatterns } else { @('LVCompare','LabVIEW') }
    $procsBeforeLeak = @()
    try { $procsBeforeLeak = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } }) } catch {}
    $jobsBeforeLeak = @()
    try { $jobsBeforeLeak = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } }) } catch {}

    # Optional grace wait before final evaluation
    $waitedMs = 0
    if ($LeakGraceSeconds -gt 0) {
      $ms = [int]([math]::Round($LeakGraceSeconds * 1000))
      Start-Sleep -Milliseconds $ms
      $waitedMs = $ms
    }

    # Final state after grace period
    $procsAfter = @()
    try { $procsAfter = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } }) } catch {}
    $pesterJobs = @()
    try { $pesterJobs = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } }) } catch {}
    $runningJobs = @($pesterJobs | Where-Object { $_.state -eq 'Running' -or $_.state -eq 'NotStarted' })
    $leakDetected = (($procsAfter.Count -gt 0) -or ($runningJobs.Count -gt 0))

    $actions = @()
    $killed = @()
    $stoppedJobs = @()
    if ($leakDetected -and $KillLeaks) {
      # Attempt to stop leaked processes
      try {
        $procsForKill = @(_Find-ProcsByPattern -Patterns $leakTargets)
        foreach ($p in $procsForKill) {
          try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; $killed += [pscustomobject]@{ name=$p.ProcessName; pid=$p.Id } } catch {}
        }
        if ($procsForKill.Count -gt 0) { $actions += ("killedProcs:{0}" -f $procsForKill.Count) }
      } catch {}
      # Attempt to stop/remove Pester jobs
      try {
        $jobsForStop = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' })
        foreach ($j in $jobsForStop) {
          $stoppedJobs += [pscustomobject]@{ id=$j.Id; name=$j.Name; state=$j.State }
        }
        _Stop-JobsSafely -Jobs $jobsForStop
        if ($jobsForStop.Count -gt 0) { $actions += ("stoppedJobs:{0}" -f $jobsForStop.Count) }
      } catch {}
      # Recompute final state after actions
      try { $procsAfter = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } }) } catch {}
      try { $pesterJobs = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } }) } catch {}
      $runningJobs = @($pesterJobs | Where-Object { $_.state -eq 'Running' -or $_.state -eq 'NotStarted' })
      $leakDetected = (($procsAfter.Count -gt 0) -or ($runningJobs.Count -gt 0))
    }

    $leakReport = [pscustomobject]@{
      schema         = 'pester-leak-report/v1'
      schemaVersion  = ${SchemaLeakReportVersion}
      generatedAt    = (Get-Date).ToString('o')
      targets        = $leakTargets
      graceSeconds   = $LeakGraceSeconds
      waitedMs       = $waitedMs
      procsBefore    = $procsBeforeLeak
      procsAfter     = $procsAfter
      runningJobs    = $runningJobs
      allJobs        = $pesterJobs
      jobsBefore     = $jobsBeforeLeak
      leakDetected   = $leakDetected
      actions        = $actions
      killedProcs    = $killed
      stoppedJobs    = $stoppedJobs
      notes          = @('Leak = LabVIEW/LVCompare (or configured targets) still running or Pester jobs still active after test run')
    }
    $leakPathOut = Join-Path $resultsDir 'pester-leak-report.json'
    $leakReport | ConvertTo-Json -Depth 6 | Out-File -FilePath $leakPathOut -Encoding utf8 -ErrorAction Stop
    if ($leakDetected) {
      Write-Warning "Leak detected: see $leakPathOut"
      if ($FailOnLeaks) {
        Write-Error "Failing run due to detected leaks (processes/jobs)"
        exit 1
      }
    }
  } catch { Write-Warning "Leak detection failed: $_" }
}

# Provide contextual note if integration was requested but effectively absent
try {
  if ($includeIntegrationBool) {
    $hadIntegrationDescribe = $false
    if ($result -and $result.Tests) {
      $hadIntegrationDescribe = ($result.Tests | Where-Object {
        ($_.PSObject.Properties.Name -contains 'Path' -and $_.Path -match 'Integration') -or 
        ($_.PSObject.Properties.Name -contains 'Tags' -and ($_.Tags -contains 'Integration'))
      } | Measure-Object).Count -gt 0
    }
    if (-not $hadIntegrationDescribe) {
      Write-Host "NOTE: Integration flag was enabled but no Integration-tagged tests were executed (prerequisites may be missing)." -ForegroundColor Yellow
    }
  }
} catch { Write-Warning "Failed to evaluate integration execution note: $_" }

# Exit with appropriate code
if ($failed -gt 0 -or $errors -gt 0) {
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
  Write-SessionIndex -ResultsDirectory $resultsDir -SummaryJsonPath $jsonSummaryPath
  } finally {
  # Ensure any background Pester job is stopped/removed to avoid lingering runs across sessions
  try {
    if ($null -ne $job -and ($job.State -eq 'Running' -or $job.State -eq 'NotStarted')) {
      Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    }
    if ($null -ne $job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
  } catch {}
  if ($CleanAfter) {
    Write-Host "Post-run cleanup: stopping LabVIEW.exe" -ForegroundColor DarkGray
    _Stop-ProcsSafely -Names @('LabVIEW')
    if ($script:CleanLVCompare) {
      Write-Host "Opt-in: also stopping LVCompare.exe (CLEAN_LVCOMPARE=1)" -ForegroundColor DarkGray
      _Stop-ProcsSafely -Names @('LVCompare')
    }
    Start-Sleep -Milliseconds 200
    $namesToReport = @('LabVIEW'); if ($script:CleanLVCompare) { $namesToReport += 'LVCompare' }
    _Report-Procs -Names $namesToReport
  }
  # Always write a leak report adjacent to results if one isn't present yet
  try {
    if ($resultsDir -and (Test-Path -LiteralPath $resultsDir -PathType Container)) {
      $finalLeakPath = Join-Path $resultsDir 'pester-leak-report.json'
      if (-not (Test-Path -LiteralPath $finalLeakPath)) {
        $leakTargets = if ($LeakProcessPatterns -and $LeakProcessPatterns.Count -gt 0) { $LeakProcessPatterns } else { @('LVCompare','LabVIEW') }
        $procsNow = @(_Find-ProcsByPattern -Patterns $leakTargets | ForEach-Object { [pscustomobject]@{ name=$_.ProcessName; pid=$_.Id; startTime=$_.StartTime } })
        $jobsNow  = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Command -like '*Invoke-Pester*' -or $_.Name -like '*Pester*' } | ForEach-Object { [pscustomobject]@{ id=$_.Id; name=$_.Name; state=$_.State; hasMoreOutput=$_.HasMoreData } })
        $runningNow = @($jobsNow | Where-Object { $_.state -eq 'Running' -or $_.state -eq 'NotStarted' })
        $report = [pscustomobject]@{
          schema        = 'pester-leak-report/v1'
          schemaVersion = ${SchemaLeakReportVersion}
          generatedAt   = (Get-Date).ToString('o')
          targets       = $leakTargets
          graceSeconds  = 0
          waitedMs      = 0
          procsBefore   = @()  # not tracked in final sweep
          procsAfter    = $procsNow
          runningJobs   = $runningNow
          allJobs       = $jobsNow
          jobsBefore    = @()
          leakDetected  = (($procsNow.Count -gt 0) -or ($runningNow.Count -gt 0))
          actions       = @()
          killedProcs   = @()
          stoppedJobs   = @()
          notes         = @('Final sweep leak report to ensure artifact presence; see main leak block for full details when enabled')
        }
        $report | ConvertTo-Json -Depth 6 | Out-File -FilePath $finalLeakPath -Encoding utf8 -ErrorAction SilentlyContinue
        # Opportunistically refresh manifest to include jsonLeaks entry
        try { Write-ArtifactManifest -Directory $resultsDir -SummaryJsonPath (Join-Path $resultsDir $JsonSummaryPath) -ManifestVersion $SchemaManifestVersion } catch {}
      }
    }
  } catch { Write-Warning "Failed to emit final sweep leak report: $_" }
}
exit 0
finally {
  if ($script:fastModeTemporarilySet) {
    Remove-Item Env:FAST_PESTER -ErrorAction SilentlyContinue
  }
  if ($sessionLockEnabled -and $lockAcquired) {
    Write-Host "::notice::Releasing session lock '$lockGroup'" -ForegroundColor DarkGray
    $released = Invoke-SessionLock -Action 'Release' -Group $lockGroup
    if (-not $released) { Write-Warning "Failed to release session lock '$lockGroup'" }
  }
}






