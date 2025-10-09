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

function Invoke-PhaseTests {
  param($r)
  Write-PhaseBanner $r.name
  $inc = $IncludeIntegrationTests.IsPresent
  try {
    $cmd = @()
    $cmd += (Join-Path (Get-Location) 'Invoke-PesterTests.ps1')
    if ($inc) { $cmd += @('-IncludeIntegration','true') }
    & $cmd[0] @($cmd[1..($cmd.Count-1)])
    $code = $LASTEXITCODE
    $r.details.exitCode = $code
    $r.details.integrationIncluded = $inc
    if ($code -eq 0) { $r.status='Passed' } else { $r.status='Failed' }
  } catch {
    $r.details.error = $_.Exception.Message
    $r.status='Failed'
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
