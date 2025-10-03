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
  [int]$LoopIterations = 15,
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
  . "$PSScriptRoot/CompareVI.ps1"
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

function Invoke-PhaseTests {
  param($r)
  Write-PhaseBanner $r.name
  $inc = $IncludeIntegrationTests.IsPresent
  try {
    $invokeArgs = @('-File','Invoke-PesterTests.ps1')
    if ($inc) { $invokeArgs += '-IncludeIntegration'; $invokeArgs += 'true' }
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $invokeArgs -NoNewWindow -PassThru -Wait
    $code = $proc.ExitCode
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
  if ($LoopIterations -gt 0) { $env:LOOP_MAX_ITERATIONS = $LoopIterations } else { Remove-Item Env:LOOP_MAX_ITERATIONS -ErrorAction SilentlyContinue }
  $env:LOOP_FAIL_ON_DIFF = 'false'
  try {
    $proc = Start-Process pwsh -ArgumentList '-File','scripts/Run-AutonomousIntegrationLoop.ps1' -NoNewWindow -PassThru -Wait
    $code = $proc.ExitCode
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
    $command = '"{0}" "{1}" "{2}" -nobdcosm -nofppos -noattr' -f $cli,$ctx.basePath,$ctx.headPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo -Property @{ FileName='pwsh'; ArgumentList='-NoLogo','-NoProfile','-Command',$command; RedirectStandardError=$true; RedirectStandardOutput=$true; UseShellExecute=$false }
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd(); $stderr = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    Set-Content runbook-diag-stdout.txt $stdout -Encoding utf8
    Set-Content runbook-diag-stderr.txt $stderr -Encoding utf8
    "$($p.ExitCode)" | Set-Content runbook-diag-exitcode.txt
    $r.details.exitCode = $p.ExitCode
    $r.details.stdoutLength = $stdout.Length
    $r.details.stderrLength = $stderr.Length
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
  overallStatus = if ($overallFailed) { 'Failed' } else { 'Passed' }
}

Write-Host "Overall Status: $($final.overallStatus)" -ForegroundColor (if ($overallFailed) { 'Red' } else { 'Green' })

if ($JsonReport) {
  $json = $final | ConvertTo-Json -Depth 6
  Set-Content -Path $JsonReport -Value $json -Encoding utf8
  Write-Host "JSON report written: $JsonReport" -ForegroundColor Yellow
}

if ($PassThru) { return $final }

if ($overallFailed) { exit 1 } else { exit 0 }
