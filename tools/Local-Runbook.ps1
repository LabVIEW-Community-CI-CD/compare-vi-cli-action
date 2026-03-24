param(
  [switch]$All,
  [string[]]$Phases,
  [string]$Profile = 'quick',
  [switch]$IncludeLoop,
  [switch]$FailOnDiff,
  [string]$JsonReport,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..') | Select-Object -ExpandProperty Path

function Get-EffectiveJsonReportPath {
  param(
    [AllowNull()][string]$RequestedPath,
    [string[]]$SelectedPhases,
    [switch]$RunAll,
    [string]$RepoRoot
  )

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    return $RequestedPath
  }

  if ($RunAll -or ($SelectedPhases -contains 'Loop')) {
    $outDir = Join-Path $RepoRoot 'tests' 'results' '_agent' 'local-runbook'
    if (-not (Test-Path -LiteralPath $outDir)) {
      New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    return (Join-Path $outDir 'local-runbook-report.json')
  }

  return $null
}

function Write-LoopExecutionTopologySummary {
  param([AllowNull()][string]$JsonReportPath)

  if ([string]::IsNullOrWhiteSpace($JsonReportPath)) {
    return
  }
  if (-not (Test-Path -LiteralPath $JsonReportPath -PathType Leaf)) {
    return
  }

  try {
    $report = Get-Content -LiteralPath $JsonReportPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $loopPhase = @($report.phases) | Where-Object { $_.name -eq 'Loop' } | Select-Object -First 1
    if (-not $loopPhase) {
      return
    }
    $executionTopology = if ($loopPhase.details.PSObject.Properties.Name -contains 'executionTopology') { $loopPhase.details.executionTopology } else { $null }
    if (-not $executionTopology) {
      return
    }

    Write-Output 'Loop Execution Topology:'
    if ($executionTopology.runtimeSurface) { Write-Output ("  runtimeSurface: {0}" -f $executionTopology.runtimeSurface) }
    if ($executionTopology.processModelClass) { Write-Output ("  processModelClass: {0}" -f $executionTopology.processModelClass) }
    if ($executionTopology.executionCellLeaseId) { Write-Output ("  executionCellLeaseId: {0}" -f $executionTopology.executionCellLeaseId) }
    if ($executionTopology.harnessInstanceLeaseId) { Write-Output ("  harnessInstanceLeaseId: {0}" -f $executionTopology.harnessInstanceLeaseId) }
    if ($executionTopology.harnessInstanceId) { Write-Output ("  harnessInstanceId: {0}" -f $executionTopology.harnessInstanceId) }
  } catch {
    Write-Warning ("Failed to read loop execution topology from JSON report: {0}" -f $_.Exception.Message)
  }
}

Push-Location $repoRoot
try {
  Write-Host "=== Local Runbook ===" -ForegroundColor Cyan
  Write-Host ("Repository: {0}" -f $repoRoot) -ForegroundColor Gray

  # Default phases for local sanity runs
  $profiles = @{
    quick   = @('Prereqs','ViInputs','Compare')
    compare = @('Prereqs','Compare')
    loop    = @('Prereqs','ViInputs','Compare','Loop')
    full    = @()
  }

  $selectedPhases = @()
  if ($All) {
    $selectedPhases = @()
  } elseif ($Phases -and $Phases.Count -gt 0) {
    $selectedPhases = $Phases
  } else {
    $profileKey = ($Profile ?? 'quick').ToLowerInvariant()
    if ($profiles.ContainsKey($profileKey)) {
      $selectedPhases = $profiles[$profileKey]
    } else {
      Write-Warning "Unknown profile '$Profile'; defaulting to quick"
      $selectedPhases = $profiles.quick
    }
    if ($IncludeLoop -and $selectedPhases) {
      if ($selectedPhases -notcontains 'Loop') { $selectedPhases += 'Loop' }
    } elseif ($IncludeLoop -and -not $selectedPhases) {
      $selectedPhases = @('Loop')
    }
  }

  $env:RUNBOOK_LOOP_ITERATIONS = '1'
  $env:RUNBOOK_LOOP_QUICK = '1'
  if ($FailOnDiff) { $env:RUNBOOK_LOOP_FAIL_ON_DIFF = '1' } else { Remove-Item Env:RUNBOOK_LOOP_FAIL_ON_DIFF -ErrorAction SilentlyContinue }
  $effectiveJsonReport = Get-EffectiveJsonReportPath -RequestedPath $JsonReport -SelectedPhases $selectedPhases -RunAll:$All -RepoRoot $repoRoot

  $runbookArgs = @()
  if ($All) { $runbookArgs += '-All' }
  if ($selectedPhases.Count -gt 0 -and -not $All) {
    $runbookArgs += @('-Phases', ($selectedPhases -join ',')) 
  }
  if ($FailOnDiff) { $runbookArgs += '-FailOnDiff' }
  if ($effectiveJsonReport) { $runbookArgs += @('-JsonReport', $effectiveJsonReport) }
  if ($PassThru) { $runbookArgs += '-PassThru' }

  Write-Host "Invoking Invoke-IntegrationRunbook.ps1 with arguments:" -ForegroundColor Gray
  if ($runbookArgs.Count -eq 0) { Write-Host '  (none)' -ForegroundColor DarkGray }
  else {
    $runbookArgs | ForEach-Object { Write-Host ("  {0}" -f $_) -ForegroundColor DarkGray }
  }

  & pwsh -NoLogo -NoProfile -File "$repoRoot/scripts/Invoke-IntegrationRunbook.ps1" @runbookArgs
  $runbookExitCode = $LASTEXITCODE
  Write-LoopExecutionTopologySummary -JsonReportPath $effectiveJsonReport
  exit $runbookExitCode
}
finally {
  Pop-Location
  Remove-Item Env:RUNBOOK_LOOP_ITERATIONS -ErrorAction SilentlyContinue
  Remove-Item Env:RUNBOOK_LOOP_QUICK -ErrorAction SilentlyContinue
  Remove-Item Env:RUNBOOK_LOOP_FAIL_ON_DIFF -ErrorAction SilentlyContinue
}
