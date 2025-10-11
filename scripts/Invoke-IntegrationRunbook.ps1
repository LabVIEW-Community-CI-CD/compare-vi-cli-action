<#
.SYNOPSIS
  Orchestrates the Integration Runbook phases for real LVCompare validation.
.DESCRIPTION
  Provides selectable phase execution, JSON reporting, and consistent status semantics.
  Phases (logical order): Prereqs, CanonicalCli, ViInputs, Compare, Tests, Loop, Diagnostics.

  Default behavior (no switches) is to run: Prereqs, CanonicalCli, ViInputs, Compare.

.PARAMETER All
  Run all defined phases.
.PARAMETER Phases
  Comma or space separated list of phase names (case-insensitive).
.PARAMETER JsonReport
  Path to write JSON report with schema integration-runbook-v1.
.PARAMETER FailOnDiff
  If set, a diff (exit code 1) in Compare phase marks failure (default: false).
.PARAMETER IncludeIntegrationTests
  Run Integration-tagged tests during Tests phase.
.PARAMETER LoopIterations
  Override loop iterations (applies to Loop phase only).
.PARAMETER Loop
  Convenience switch to include Loop phase when not using -All or -Phases explicitly.
.PARAMETER PassThru
  Return the in-memory result object in addition to console output.
.EXAMPLE
  pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -All -JsonReport runbook.json
.EXAMPLE
  pwsh -File scripts/Invoke-IntegrationRunbook.ps1 -Phases Compare -FailOnDiff
#>
[CmdletBinding()]
param(
  [switch]$All,
  [string[]]$Phases,
  [string]$JsonReport,
  [switch]$FailOnDiff,
  [switch]$IncludeIntegrationTests,
  [int]$LoopIterations = 1,
  [switch]$Loop,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'integration-runbook-v1'
$allPhaseNames = @('Prereqs','CanonicalCli','ViInputs','Compare','Tests','Loop','Diagnostics')

function Write-PhaseBanner([string]$name) {
  Write-Host ('=' * 70) -ForegroundColor DarkGray
  Write-Host ("PHASE: $name") -ForegroundColor Cyan
  Write-Host ('-' * 70) -ForegroundColor DarkGray
}

function New-PhaseResult([string]$name){ [pscustomobject]@{ name=$name; status='Skipped'; details=@{} } }

# Determine selected phases explicitly (avoid inline ternary style that can confuse parsing in some contexts)
$selected = $null
if ($All) {
    $selected = $allPhaseNames
}
elseif ($Phases) {
    # Split comma or whitespace separated names
    $flat = $Phases -join ' '
    $selected = $flat -split '[,\s]+' | Where-Object { $_ }
}
else {
    $base = @('Prereqs','CanonicalCli','ViInputs','Compare')
    if ($Loop) { $base += 'Loop' }
    $selected = $base
}

$selected = $selected | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$invalid = $selected | Where-Object { $_ -notin $allPhaseNames }
if ($invalid) { throw "Unknown phase(s): $($invalid -join ', ')" }
$ordered = $allPhaseNames | Where-Object { $_ -in $selected }

# Result container
$results = [System.Collections.Generic.List[object]]::new()
$ctx = [pscustomobject]@{ basePath=$env:LV_BASE_VI; headPath=$env:LV_HEAD_VI; compareResult=$null }
$overallFailed = $false

#region Phase Implementations

function Invoke-PhasePrereqs {
  param($r)
  Write-PhaseBanner $r.name
  $pwshOk = ($PSVersionTable.PSVersion.Major -ge 7)
  $r.details.powerShellVersion = $PSVersionTable.PSVersion.ToString()
  $r.details.powerShellOk = $pwshOk
  if (-not $pwshOk) { $r.status='Failed'; return }
  $r.status='Passed'
}

function Invoke-PhaseCanonicalCli {
  param($r)
  Write-PhaseBanner $r.name
  $canonical = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
  $exists = Test-Path $canonical
  $r.details.canonicalPath = $canonical
  $r.details.exists = $exists
  if ($exists) { $r.status='Passed' } else { $r.status='Failed' }
}

function Invoke-PhaseViInputs {
  param($r,$ctx)
  Write-PhaseBanner $r.name
  $base = $ctx.basePath; $head = $ctx.headPath
  $r.details.base=$base; $r.details.head=$head
  $missing = @()
  if (-not $base) { $missing += 'LV_BASE_VI' }
  if (-not $head) { $missing += 'LV_HEAD_VI' }
  if ($missing) { $r.details.missing = $missing; $r.status='Failed'; return }
  $bExists = Test-Path $base; $hExists = Test-Path $head
  $r.details.baseExists=$bExists; $r.details.headExists=$hExists
  if (-not ($bExists -and $hExists)) { $r.status='Failed'; return }
  $same = (Resolve-Path $base).ProviderPath -eq (Resolve-Path $head).ProviderPath
  $r.details.pathsIdentical=$same
  $r.status = 'Passed'
}

function Invoke-PhaseCompare {
  param($r,$ctx)
  Write-PhaseBanner $r.name
  $driver = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'Invoke-LVCompare.ps1'
  $ts    = Get-Date -Format 'yyyyMMdd-HHmmss'
  $outDirRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests' 'results' 'runbook-compare'
  $outDir = Join-Path $outDirRoot $ts
  $useDriver = $false
  try { if ($env:RUNBOOK_COMPARE_DRIVER -match '^(?i:1|true|yes|on)$') { $useDriver = $true } } catch {}
  if ($useDriver -and (Test-Path -LiteralPath $driver -PathType Leaf)) {
    try {
      & $driver -BaseVi $ctx.basePath -HeadVi $ctx.headPath -OutputDir $outDir -RenderReport -JsonLogPath (Join-Path $outDir 'compare-events.ndjson') -LeakCheck -Summary | Out-Null
      $capPath = Join-Path $outDir 'lvcompare-capture.json'
      if (Test-Path -LiteralPath $capPath -PathType Leaf) {
        $cap = Get-Content -LiteralPath $capPath -Raw | ConvertFrom-Json
        $r.details.exitCode = [int]$cap.exitCode
        $r.details.durationSeconds = [double]$cap.seconds
        $r.details.command = $cap.command
        $r.details.captureJson = $capPath
        $reportPath = Join-Path $outDir 'compare-report.html'
        $r.details.reportPath = if (Test-Path -LiteralPath $reportPath) { $reportPath } else { $null }
        $r.details.diff = if ($r.details.exitCode -eq 1) { $true } elseif ($r.details.exitCode -eq 0) { $false } else { $null }
        if ($r.details.exitCode -in 0,1) {
          if ($r.details.diff -and $FailOnDiff) { $r.status='Failed' } else { $r.status='Passed' }
        } else { $r.status='Failed' }
        # Surface concise outcome
        Write-Host ("Compare Outcome: exit={0} diff={1} seconds={2}" -f $r.details.exitCode, $r.details.diff, $r.details.durationSeconds) -ForegroundColor Yellow
        if ($r.details.reportPath) { Write-Host ("Report: {0}" -f $r.details.reportPath) -ForegroundColor Gray }
        if ($env:GITHUB_STEP_SUMMARY) {
          try {
            $lines = @()
            $lines += '## Compare Outcome'
            $lines += ("- Exit: {0}" -f $r.details.exitCode)
            $lines += ("- Diff: {0}" -f $r.details.diff)
            $lines += ("- Duration: {0}s" -f $r.details.durationSeconds)
            if ($r.details.reportPath) { $lines += ("- Report: {0}" -f $r.details.reportPath) } else { $lines += '- Report: (none)' }
            $lines += ("- OutputDir: {0}" -f $outDir)
            Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8
          } catch { Write-Warning ("Failed to append Compare Outcome to step summary: {0}" -f $_.Exception.Message) }
        }
      } else {
        $r.details.error = 'Missing lvcompare-capture.json from driver.'
        $r.status='Failed'
      }
    } catch {
      $r.details.error = $_.Exception.Message
      $r.status='Failed'
    }
  }
  if (-not $useDriver -or $r.status -eq 'Failed') {
    # Fallback to legacy CompareVI path for compatibility
    $mod = Join-Path $PSScriptRoot 'CompareVI.psm1'
    if (-not (Test-Path -LiteralPath $mod)) { $mod = Join-Path (Join-Path $PSScriptRoot 'scripts') 'CompareVI.psm1' }
    if (-not (Test-Path -LiteralPath $mod)) { throw "CompareVI module not found at expected locations." }
    if (-not (Get-Command -Name Invoke-CompareVI -ErrorAction SilentlyContinue)) { Import-Module $mod -Force }
    try {
      $compare = Invoke-CompareVI -Base $ctx.basePath -Head $ctx.headPath -LvCompareArgs '-nobdcosm -nofppos -noattr' -FailOnDiff:$false
      $ctx.compareResult = $compare
      $r.details.exitCode = $compare.ExitCode
      $r.details.diff = $compare.Diff
      $r.details.durationSeconds = $compare.CompareDurationSeconds
      $r.details.shortCircuited = $compare.ShortCircuitedIdenticalPath
      if ($compare.ExitCode -eq 0 -or $compare.ExitCode -eq 1) {
        if ($compare.Diff -and $FailOnDiff) { $r.status='Failed' } else { $r.status='Passed' }
      } else {
        $r.status='Failed'
      }
    } catch {
      $r.details.error = $_.Exception.Message
      $r.status='Failed'
    }
  }
}

function Resolve-RunbookIncludePatterns {
  param(
    [string[]]$Patterns,
    [string]$TestsDir
  )
  $resolved = [System.Collections.Generic.List[string]]::new()
  if (-not $Patterns -or $Patterns.Count -eq 0) { return $resolved }
  $allTests = Get-ChildItem -Path $TestsDir -Recurse -Filter '*.Tests.ps1' -File -ErrorAction SilentlyContinue
  foreach ($pattern in $Patterns) {
    $trim = ($pattern ?? '').Trim()
    if (-not $trim) { continue }
    if ($trim -match '^[a-zA-Z]:') {
      if (Test-Path -LiteralPath $trim -PathType Leaf) {
        $resolved.Add((Resolve-Path -LiteralPath $trim -ErrorAction SilentlyContinue).ProviderPath)
      }
      continue
    }
    $normalized = $trim -replace '/', '\'
    foreach ($file in $allTests) {
      $relative = $file.FullName.Substring($TestsDir.Length).TrimStart('\')
      if ($file.Name -like $normalized -or $relative -like $normalized -or $relative -ieq $normalized) {
        $resolved.Add($file.FullName)
      }
    }
  }
  return ($resolved | Select-Object -Unique)
}

function Get-RunbookTestEntries {
  param(
    [Parameter(Mandatory)][string]$TestsDir,
    [Parameter(Mandatory)][string]$RepoRoot
  )
  $manifestPath = Join-Path $RepoRoot 'tools' 'runbook-tests.manifest.json'
  $components = [System.Collections.Generic.List[object]]::new()
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6
      foreach ($entry in @($manifest.components)) {
        if (-not $entry) { continue }
        $requiresIntegration = $false
        if ($entry.PSObject.Properties['requiresIntegration']) {
          $requiresIntegration = [bool]$entry.requiresIntegration
        }
        $expected = $null
        if ($entry.PSObject.Properties['expectedTests']) {
          $expected = [int]$entry.expectedTests
        }
        $timeoutSeconds = $null
        if ($entry.PSObject.Properties['timeoutSeconds']) {
          try { $timeoutSeconds = [double]$entry.timeoutSeconds } catch {}
        }
        $perTestSeconds = $null
        if ($entry.PSObject.Properties['perTestSeconds']) {
          try { $perTestSeconds = [double]$entry.perTestSeconds } catch {}
        }
        $components.Add([pscustomobject]@{
          name                = if ($entry.name) { [string]$entry.name } else { 'Unit' }
          includePatterns     = @($entry.includePatterns)
          expectedTests       = $expected
          requiresIntegration = $requiresIntegration
          timeoutSeconds      = $timeoutSeconds
          perTestSeconds      = $perTestSeconds
          resolvedFiles       = @()
        })
      }
    } catch {
      Write-Warning ("Failed to parse runbook test manifest at {0}: {1}" -f $manifestPath, $_.Exception.Message)
    }
  }
  if (-not ($components | Where-Object { $_.name -ieq 'Unit' })) {
    $components.Add([pscustomobject]@{
      name='Unit'; includePatterns=@(); expectedTests=$null; requiresIntegration=$false; timeoutSeconds=$null; perTestSeconds=$null; resolvedFiles=@()
    })
  }
  if (-not ($components | Where-Object { $_.name -ieq 'Integration' })) {
    $components.Add([pscustomobject]@{
      name='Integration'; includePatterns=@(); expectedTests=$null; requiresIntegration=$true; timeoutSeconds=$null; perTestSeconds=$null; resolvedFiles=@()
    })
  }
  foreach ($comp in $components) {
    if (-not $comp.includePatterns) { $comp.includePatterns = @() }
    $comp.resolvedFiles = Resolve-RunbookIncludePatterns -Patterns $comp.includePatterns -TestsDir $TestsDir
    if (-not $comp.expectedTests -and $comp.resolvedFiles) {
      $comp.expectedTests = $comp.resolvedFiles.Count
    }
    if ((-not $comp.timeoutSeconds) -and $comp.perTestSeconds -and $comp.expectedTests) {
      $comp.timeoutSeconds = [double]$comp.perTestSeconds * [double]$comp.expectedTests
    }
  }
  $catalog = [ordered]@{
    total = ($components | Where-Object { $_.expectedTests } | Measure-Object -Property expectedTests -Sum).Sum
    unit = ($components | Where-Object { (-not $_.requiresIntegration) -and $_.expectedTests } | Measure-Object -Property expectedTests -Sum).Sum
    integration = ($components | Where-Object { $_.requiresIntegration -and $_.expectedTests } | Measure-Object -Property expectedTests -Sum).Sum
  }
  foreach ($key in @('total','unit','integration')) {
    if (-not $catalog[$key]) { $catalog[$key] = 0 }
  }
  return [pscustomobject]@{
    manifestPath = $(if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $manifestPath } else { $null })
    catalog = $catalog
    components = $components
  }
}

function Invoke-RunbookTestComponent {
  param(
    [Parameter(Mandatory)][string]$ComponentName,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ResultsRoot,
    [Parameter(Mandatory)][bool]$RunEnabled,
    [Parameter(Mandatory)][bool]$IncludeIntegrationSwitch,
    [string[]]$IncludePatterns,
    [hashtable]$CountsHint,
    [string[]]$ResolvedFiles
  )
  $component = [ordered]@{
    name        = $ComponentName
    included    = $RunEnabled
    status      = 'Skipped'
    exitCode    = $null
    resultsPath = $null
    summary     = $null
    discovery   = $null
    failures    = @()
    reason      = $null
  }
  if ($CountsHint -and $CountsHint.ContainsKey('expected')) {
    $component.expectedTests = $CountsHint['expected']
  }
  $timeoutSeconds = $null
  if ($CountsHint -and $CountsHint.ContainsKey('timeoutSeconds') -and $CountsHint['timeoutSeconds']) {
    try { $timeoutSeconds = [double]$CountsHint['timeoutSeconds'] } catch {}
  }
  $perTestSeconds = $null
  if ($CountsHint -and $CountsHint.ContainsKey('perTestSeconds') -and $CountsHint['perTestSeconds']) {
    try { $perTestSeconds = [double]$CountsHint['perTestSeconds'] } catch {}
  }
  if ((-not $timeoutSeconds) -and $perTestSeconds -and $component.PSObject.Properties['expectedTests'] -and $component.expectedTests) {
    $timeoutSeconds = [double]$perTestSeconds * [double]$component.expectedTests
  }
  if ($timeoutSeconds -and $timeoutSeconds -gt 0) {
    $component.timeoutSeconds = [double]$timeoutSeconds
  }
  if ($perTestSeconds -and $perTestSeconds -gt 0) {
    $component.perTestSeconds = [double]$perTestSeconds
  }
  if (-not $RunEnabled) {
    if ($CountsHint -and $CountsHint.ContainsKey('reason')) {
      $component.reason = $CountsHint['reason']
    }
    return [pscustomobject]$component
  }
  $componentDir = Join-Path $ResultsRoot ($ComponentName.ToLowerInvariant())
  if (Test-Path -LiteralPath $componentDir) {
    Remove-Item -LiteralPath $componentDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $componentDir | Out-Null

  $invokeParams = @{
    ResultsPath          = $componentDir
    JsonSummaryPath      = 'pester-summary.json'
    UseDiscoveryManifest = $true
    EmitOutcome          = $true
    EmitContext          = $true
    EmitTimingDetail     = $true
    EmitDiscoveryDetail  = $true
    EmitAggregationHints = $true
    IncludeIntegration   = $(if ($IncludeIntegrationSwitch) { 'true' } else { 'false' })
  }
  if ($timeoutSeconds -and $timeoutSeconds -gt 0) {
    $invokeParams['TimeoutSeconds'] = [double]$timeoutSeconds
  }
  if ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
    $invokeParams['IncludePatterns'] = $IncludePatterns
    $component.selection = [ordered]@{ includePatterns = $IncludePatterns }
  }
  elseif ($ResolvedFiles -and $ResolvedFiles.Count -gt 0) {
    $invokeParams['IncludePatterns'] = $ResolvedFiles
    $component.selection = [ordered]@{ includePatterns = $ResolvedFiles }
  }
  if ($ResolvedFiles -and $ResolvedFiles.Count -gt 0) {
    $component.resolvedFiles = $ResolvedFiles
    $invokeParams['MaxTestFiles'] = [math]::Max(1, $ResolvedFiles.Count)
  }
  elseif ($IncludePatterns -and $IncludePatterns.Count -gt 0) {
    $invokeParams['MaxTestFiles'] = [math]::Max(1, $IncludePatterns.Count)
  }

  $integrationBoolSeed = $IncludeIntegrationSwitch
  Set-Variable -Name 'includeIntegrationBool' -Scope Script -Value ($integrationBoolSeed) -Force

  $scriptPath = Join-Path (Get-Location) 'Invoke-PesterTests.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath)) {
    $component.status = 'Failed'
    $component.reason = 'invoke-script-missing'
    return $component
  }

  try {
    & $scriptPath @invokeParams
    $exitCode = $LASTEXITCODE
  } catch {
    $component.status = 'Failed'
    $component.exitCode = $LASTEXITCODE
    $component.error = $_.Exception.Message
    return $component
  }

  $component.exitCode = $exitCode
  $component.resultsPath = $componentDir

  $summaryPath = Join-Path $componentDir 'pester-summary.json'
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    try {
      $component.summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 6
    } catch {
      $component.summaryError = $_.Exception.Message
    }
  }

  $failuresPath = Join-Path $componentDir 'pester-failures.json'
  if (Test-Path -LiteralPath $failuresPath -PathType Leaf) {
    try {
      $failures = Get-Content -LiteralPath $failuresPath -Raw | ConvertFrom-Json -Depth 6
      if ($failures) {
        $component.failureCount = @($failures).Count
        $component.failures = @($failures | Select-Object -First 5)
      }
    } catch {
      $component.failuresError = $_.Exception.Message
    }
  }

  $manifestPath = Join-Path $componentDir '_agent/test-manifest.json'
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
      $component.discovery = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6
    } catch {
      $component.discoveryError = $_.Exception.Message
    }
  }

  $summaryTotal = $null
  if ($component.summary -and $component.summary.PSObject.Properties['total']) {
    $summaryTotal = [int]$component.summary.total
  }

  if ($exitCode -eq 0) {
    if ($summaryTotal -eq 0) {
      $component.status = 'Skipped'
      if (-not $component.reason) { $component.reason = 'no-tests-executed' }
    } else {
      $component.status = 'Passed'
    }
  } else {
    $component.status = 'Failed'
  }

  return [pscustomobject]$component
}

function Invoke-PhaseTests {
  param($r)
  Write-PhaseBanner $r.name
  $repoRoot = (Get-Location).Path
  $testsDir = Join-Path $repoRoot 'tests'
  $resultsRoot = Join-Path $repoRoot 'tests/results'
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $runRoot = Join-Path $resultsRoot ("runbook-tests-{0}" -f $timestamp)
  New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

  $entries = Get-RunbookTestEntries -TestsDir $testsDir -RepoRoot $repoRoot
  $components = @()

  $unitEntry = $entries.components | Where-Object { $_.name -ieq 'Unit' } | Select-Object -First 1
  if (-not $unitEntry) {
    $unitEntry = [pscustomobject]@{ name='Unit'; includePatterns=@(); expectedTests=$null; requiresIntegration=$false }
  }
  $unitComponent = Invoke-RunbookTestComponent -ComponentName 'Unit' -RepoRoot $repoRoot -ResultsRoot $runRoot -RunEnabled:$true -IncludeIntegrationSwitch:$false -IncludePatterns $unitEntry.includePatterns -CountsHint (@{
      expected        = $unitEntry.expectedTests
      timeoutSeconds  = $unitEntry.timeoutSeconds
      perTestSeconds  = $unitEntry.perTestSeconds
    }) -ResolvedFiles $unitEntry.resolvedFiles
  $components += $unitComponent

  $integrationRequested = $IncludeIntegrationTests.IsPresent
  $integrationEntry = $entries.components | Where-Object { $_.name -ieq 'Integration' } | Select-Object -First 1
  if (-not $integrationEntry) {
    $integrationEntry = [pscustomobject]@{ name='Integration'; includePatterns=@(); expectedTests=$null; requiresIntegration=$true }
  }

  if ($integrationRequested) {
    $integrationComponent = Invoke-RunbookTestComponent -ComponentName 'Integration' -RepoRoot $repoRoot -ResultsRoot $runRoot -RunEnabled:$true -IncludeIntegrationSwitch:$true -IncludePatterns $integrationEntry.includePatterns -CountsHint (@{
        expected        = $integrationEntry.expectedTests
        timeoutSeconds  = $integrationEntry.timeoutSeconds
        perTestSeconds  = $integrationEntry.perTestSeconds
      }) -ResolvedFiles $integrationEntry.resolvedFiles
    $components += $integrationComponent
  } else {
    $components += Invoke-RunbookTestComponent -ComponentName 'Integration' -RepoRoot $repoRoot -ResultsRoot $runRoot -RunEnabled:$false -IncludeIntegrationSwitch:$false -IncludePatterns $integrationEntry.includePatterns -CountsHint (@{
        reason          = 'integration-not-requested'
        expected        = $integrationEntry.expectedTests
        timeoutSeconds  = $integrationEntry.timeoutSeconds
        perTestSeconds  = $integrationEntry.perTestSeconds
      }) -ResolvedFiles $integrationEntry.resolvedFiles
  }

  $failedComponents = $components | Where-Object { $_.status -eq 'Failed' }

  $integrationComponentState = $components | Where-Object { $_.name -ieq 'Integration' } | Select-Object -First 1
  $integrationIncludedValue = $false
  if ($integrationComponentState -is [hashtable] -and $integrationComponentState.ContainsKey('included')) {
    $integrationIncludedValue = [bool]$integrationComponentState['included']
  } elseif ($integrationComponentState -and $integrationComponentState.PSObject.Properties['included']) {
    $integrationIncludedValue = [bool]$integrationComponentState.included
  }

  $r.details = [ordered]@{
    integrationRequested = [bool]$integrationRequested
    integrationIncluded  = $integrationIncludedValue
    catalog              = $entries.catalog
    resultsRoot          = $runRoot
    components           = $components
    componentExitCodes   = @(
      foreach ($component in $components) {
        [ordered]@{
          name     = $component.name
          exitCode = $component.exitCode
          status   = $component.status
        }
      }
    )
  }

  if ($failedComponents) {
    $r.status = 'Failed'
  } else {
    $r.status = 'Passed'
  }

  if ($env:GITHUB_STEP_SUMMARY) {
    try {
      $lines = @()
      $lines += '#### Tests - Components'
      $lines += ''
      $lines += '| Component | Status | Tests | Failed | Duration (s) | Notes |'
      $lines += '| --- | --- | --- | --- | --- | --- |'
      foreach ($component in $components) {
        $testCount = if ($component.summary -and $component.summary.PSObject.Properties['total']) { $component.summary.total } elseif ($component.PSObject.Properties['expectedTests']) { $component.expectedTests } else { 'n/a' }
        $failedCount = if ($component.summary -and $component.summary.PSObject.Properties['failed']) { $component.summary.failed } else { 'n/a' }
        $duration = if ($component.summary -and $component.summary.PSObject.Properties['duration_s'] -and $component.summary.duration_s -ne $null) { '{0:N2}' -f $component.summary.duration_s } else { 'n/a' }
        $notesParts = @()
        if ($component.PSObject.Properties['reason'] -and $component.reason) { $notesParts += $component.reason }
        if ($component.summary -and $component.summary.PSObject.Properties['flags'] -and $component.summary.flags) {
          $notesParts += ($component.summary.flags -join ',')
        }
        $notes = if ($notesParts) { $notesParts -join '; ' } else { '' }
        $lines += ('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $component.name, $component.status, $testCount, $failedCount, $duration, $notes)
      }
      Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8
    } catch {
      Write-Warning ("Failed to append Tests component table to step summary: {0}" -f $_.Exception.Message)
    }
  }
}

function Invoke-PhaseLoop {
  param($r,$ctx)
  Write-PhaseBanner $r.name
  $env:LOOP_SIMULATE = ''  # ensure real
  # Optional quick/override controls via env (non-breaking defaults)
  try {
    if (-not $PSBoundParameters.ContainsKey('LoopIterations')) {
      if ($env:RUNBOOK_LOOP_ITERATIONS -match '^[0-9]+$') { $LoopIterations = [int]$env:RUNBOOK_LOOP_ITERATIONS }
    }
    if ($env:RUNBOOK_LOOP_QUICK -match '^(?i:1|true|yes|on)$') { $LoopIterations = 1 }
  } catch {}
  if ($LoopIterations -gt 0) { $env:LOOP_MAX_ITERATIONS = $LoopIterations } else { Remove-Item Env:LOOP_MAX_ITERATIONS -ErrorAction SilentlyContinue }
  $failOn = $false
  try { if ($env:RUNBOOK_LOOP_FAIL_ON_DIFF -match '^(?i:1|true|yes|on)$') { $failOn = $true } } catch {}
  try { if ($env:RUNBOOK_LOOP_QUICK -match '^(?i:1|true|yes|on)$') { $failOn = $true } } catch {}
  $env:LOOP_FAIL_ON_DIFF = ($failOn ? 'true' : 'false')
  try {
    & (Join-Path (Get-Location) 'scripts' 'Run-AutonomousIntegrationLoop.ps1')
    $code = $LASTEXITCODE
    $r.details.exitCode = $code
    if ($code -eq 0) { $r.status='Passed' } else { $r.status='Failed' }
  } catch {
    $r.details.error = $_.Exception.Message
    $r.status='Failed'
  }
}

function Invoke-PhaseDiagnostics {
  param($r,$ctx)
  Write-PhaseBanner $r.name
  $cli = 'C:\\Program Files\\National Instruments\\Shared\\LabVIEW Compare\\LVCompare.exe'
  if (-not (Test-Path $cli)) { $r.details.skipped='cli-missing'; $r.status='Skipped'; return }
  if (-not ($ctx.basePath -and $ctx.headPath)) { $r.details.skipped='paths-missing'; $r.status='Skipped'; return }
  try {
    # Optional console watcher during diagnostics compare
    $cwId = $null
    if ($env:WATCH_CONSOLE -match '^(?i:1|true|yes|on)$') {
      try {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        if (-not (Get-Command -Name Start-ConsoleWatch -ErrorAction SilentlyContinue)) {
          Import-Module (Join-Path $root 'tools' 'ConsoleWatch.psm1') -Force
        }
        $cwId = Start-ConsoleWatch -OutDir (Get-Location).Path
      } catch {}
    }
    $compareScript = Join-Path -Path $PSScriptRoot -ChildPath 'CompareVI.ps1'
    if (-not (Test-Path $compareScript)) {
      $alt = Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'scripts') -ChildPath 'CompareVI.ps1'
      if (Test-Path $alt) { $compareScript = $alt }
    }
    if (-not (Get-Command -Name Invoke-CompareVI -ErrorAction SilentlyContinue)) {
      . $compareScript
    }
    $res = Invoke-CompareVI -Base $ctx.basePath -Head $ctx.headPath -LvComparePath $cli -LvCompareArgs '-nobdcosm -nofppos -noattr' -FailOnDiff:$false
    # Write minimal diag artifacts for parity
    "${res.ExitCode}" | Set-Content runbook-diag-exitcode.txt -Encoding utf8
    '' | Set-Content runbook-diag-stdout.txt -Encoding utf8
    '' | Set-Content runbook-diag-stderr.txt -Encoding utf8
    $r.details.exitCode = $res.ExitCode
    $r.details.stdoutLength = 0
    $r.details.stderrLength = 0
    if ($cwId) {
      try { $cwSum = Stop-ConsoleWatch -Id $cwId -OutDir (Get-Location).Path -Phase 'diagnostics'; if ($cwSum) { $r.details.consoleSpawns = $cwSum.counts } } catch {}
    }
    $r.status = 'Passed'
  } catch {
    $r.details.error = $_.Exception.Message
    $r.status='Failed'
  }
}

#endregion

foreach ($p in $ordered) {
  $phaseResult = New-PhaseResult $p
  $results.Add($phaseResult) | Out-Null
  switch ($p) {
    'Prereqs' { Invoke-PhasePrereqs $phaseResult }
    'CanonicalCli' { Invoke-PhaseCanonicalCli $phaseResult }
    'ViInputs' { Invoke-PhaseViInputs $phaseResult $ctx }
    'Compare' { Invoke-PhaseCompare $phaseResult $ctx }
    'Tests' { Invoke-PhaseTests $phaseResult }
    'Loop' { Invoke-PhaseLoop $phaseResult $ctx }
    'Diagnostics' { Invoke-PhaseDiagnostics $phaseResult $ctx }
  }
  if ($phaseResult.status -eq 'Failed') { $overallFailed = $true }
}

$final = [pscustomobject]@{
  schema = $script:Schema
  generated = (Get-Date).ToString('o')
  phases = $results
  overallStatus = $( if ($overallFailed) { 'Failed' } else { 'Passed' } )
}

Write-Host "Overall Status: $($final.overallStatus)" -ForegroundColor $( if ($overallFailed) { 'Red' } else { 'Green' } )

if ($JsonReport) {
  $json = $final | ConvertTo-Json -Depth 6
  Set-Content -Path $JsonReport -Value $json -Encoding utf8
  Write-Host "JSON report written: $JsonReport" -ForegroundColor Yellow
}

if ($env:GITHUB_STEP_SUMMARY) {
  try {
    $lines = @()
    $lines += '### Integration Runbook'
    $lines += ''
    $lines += ("- Overall Status: **{0}**" -f $final.overallStatus)
    if ($JsonReport) {
      try {
        $resolved = Resolve-Path -LiteralPath $JsonReport -ErrorAction Stop
        $lines += ("- JSON Report: {0}" -f $resolved)
      } catch {
        $lines += ("- JSON Report: {0}" -f $JsonReport)
      }
    } else {
      $lines += '- JSON Report: (not requested)'
    }
    $lines += ''
    $lines += '| Phase | Status |'
    $lines += '| --- | --- |'
    foreach ($phase in $final.phases) {
      $lines += ('| {0} | {1} |' -f $phase.name, $phase.status)
    }
    $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  } catch {
    Write-Warning ("Failed to append runbook summary to step summary: {0}" -f $_.Exception.Message)
  }
}

if ($PassThru) { return $final }

if ($overallFailed) { exit 1 } else { exit 0 }
