#Requires -Version 7.0
<#
.SYNOPSIS
  Writes a canonical readiness envelope for Docker Desktop fast-loop runs.

.DESCRIPTION
  Produces machine-readable and markdown readiness artifacts from the latest
  fast-loop summary/status files. Includes lane status, step timing, historical
  medians/p90 baselines, and a deterministic push recommendation.
#>
[CmdletBinding()]
param(
  [string]$ResultsRoot = 'tests/results/local-parity',
  [string]$SummaryPath = '',
  [string]$StatusPath = '',
  [string]$OutputJsonPath = '',
  [string]$OutputMarkdownPath = '',
  [int]$HistoryRuns = 25,
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Ensure-ParentDirectory {
  param([Parameter(Mandatory)][string]$Path)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
}

function Convert-ToSecondsString {
  param([double]$Milliseconds)
  return ([math]::Round(($Milliseconds / 1000.0), 3)).ToString('0.###')
}

function Get-StepLane {
  param([Parameter(Mandatory)][string]$StepName)
  if ($StepName -like 'windows-*') { return 'windows' }
  if ($StepName -like 'linux-*') { return 'linux' }
  return ''
}

function Get-Percentile {
  param(
    [Parameter(Mandatory)][double[]]$Values,
    [ValidateRange(0.0, 1.0)][double]$Percentile
  )
  if (-not $Values -or $Values.Count -eq 0) { return 0.0 }
  $sorted = @($Values | Sort-Object)
  if ($sorted.Count -eq 1) { return [double]$sorted[0] }
  $position = ($sorted.Count - 1) * $Percentile
  $lower = [math]::Floor($position)
  $upper = [math]::Ceiling($position)
  if ($lower -eq $upper) { return [double]$sorted[$lower] }
  $weight = $position - $lower
  return ([double]$sorted[$lower] * (1.0 - $weight)) + ([double]$sorted[$upper] * $weight)
}

function Get-Median {
  param([Parameter(Mandatory)][double[]]$Values)
  return Get-Percentile -Values $Values -Percentile 0.5
}

function Get-LatestSummaryPath {
  param([Parameter(Mandatory)][string]$Root)
  $files = Get-ChildItem -LiteralPath $Root -Filter 'docker-runtime-fastloop-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^docker-runtime-fastloop-\d{14}\.json$' } |
    Sort-Object LastWriteTimeUtc -Descending
  $latest = $files | Select-Object -First 1
  if (-not $latest) { return $null }
  return $latest.FullName
}

function Read-JsonOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 16)
  } catch {
    return $null
  }
}

function Get-HistoricalStats {
  param(
    [Parameter(Mandatory)][string]$Root,
    [int]$MaxRuns = 25
  )

  $stepDurations = @{}
  $laneDurations = @{
    windows = New-Object System.Collections.Generic.List[double]
    linux = New-Object System.Collections.Generic.List[double]
  }

  $files = Get-ChildItem -LiteralPath $Root -Filter 'docker-runtime-fastloop-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^docker-runtime-fastloop-\d{14}\.json$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First $MaxRuns

  foreach ($file in @($files)) {
    $summary = Read-JsonOrNull -Path $file.FullName
    if (-not $summary -or -not $summary.steps) { continue }
    $laneSum = @{ windows = 0.0; linux = 0.0 }
    foreach ($step in @($summary.steps)) {
      if (-not $step -or -not $step.PSObject -or -not $step.PSObject.Properties['name']) { continue }
      $stepName = [string]$step.PSObject.Properties['name'].Value
      $durationMs = 0.0
      if ($step.PSObject.Properties['durationMs']) {
        $durationMs = [double]$step.PSObject.Properties['durationMs'].Value
      }
      if ($durationMs -le 0) { continue }

      if (-not $stepDurations.ContainsKey($stepName)) {
        $stepDurations[$stepName] = New-Object System.Collections.Generic.List[double]
      }
      $stepDurations[$stepName].Add($durationMs) | Out-Null

      $lane = Get-StepLane -StepName $stepName
      if (-not $laneSum.ContainsKey($lane)) { continue }
      $laneSum[$lane] = [double]$laneSum[$lane] + $durationMs
    }

    foreach ($laneName in @('windows', 'linux')) {
      if ($laneSum[$laneName] -gt 0) {
        $laneDurations[$laneName].Add([double]$laneSum[$laneName]) | Out-Null
      }
    }
  }

  $stepStats = @{}
  foreach ($key in @($stepDurations.Keys)) {
    $values = @($stepDurations[$key].ToArray())
    if ($values.Count -eq 0) { continue }
    $stepStats[$key] = [ordered]@{
      runs = $values.Count
      medianMs = [math]::Round((Get-Median -Values $values), 0)
      p90Ms = [math]::Round((Get-Percentile -Values $values -Percentile 0.9), 0)
    }
  }

  $laneStats = [ordered]@{}
  foreach ($laneName in @('windows', 'linux')) {
    $values = @($laneDurations[$laneName].ToArray())
    if ($values.Count -eq 0) {
      $laneStats[$laneName] = [ordered]@{ runs = 0; medianMs = 0; p90Ms = 0 }
      continue
    }
    $laneStats[$laneName] = [ordered]@{
      runs = $values.Count
      medianMs = [math]::Round((Get-Median -Values $values), 0)
      p90Ms = [math]::Round((Get-Percentile -Values $values -Percentile 0.9), 0)
    }
  }

  return [ordered]@{
    sampleRuns = @($files).Count
    maxRuns = $MaxRuns
    lanes = $laneStats
    steps = $stepStats
  }
}

function Get-LaneFromSteps {
  param([Parameter(Mandatory)][object[]]$Steps)

  $laneState = @{
    windows = [ordered]@{ total = 0; completed = 0; failed = 0; durationMs = 0; diffDetected = $false; failureClass = 'none' }
    linux   = [ordered]@{ total = 0; completed = 0; failed = 0; durationMs = 0; diffDetected = $false; failureClass = 'none' }
  }

  $failurePriority = @{
    'none' = 0
    'preflight' = 1
    'cli/tool' = 2
    'startup-connectivity' = 3
    'timeout' = 4
    'runtime-determinism' = 5
  }

  foreach ($step in @($Steps)) {
    if (-not $step -or -not $step.PSObject -or -not $step.PSObject.Properties['name']) { continue }
    $stepName = [string]$step.PSObject.Properties['name'].Value
    $laneName = Get-StepLane -StepName $stepName
    if (-not $laneState.ContainsKey($laneName)) { continue }
    $laneState[$laneName].total = [int]$laneState[$laneName].total + 1
    $status = if ($step.PSObject.Properties['status']) { [string]$step.status } else { '' }
    if ($status -eq 'success') {
      $laneState[$laneName].completed = [int]$laneState[$laneName].completed + 1
    } else {
      $laneState[$laneName].failed = [int]$laneState[$laneName].failed + 1
    }
    if ($step.PSObject.Properties['durationMs']) {
      $laneState[$laneName].durationMs = [int]$laneState[$laneName].durationMs + [int]$step.durationMs
    }

    if ($step.PSObject.Properties['isDiff'] -and [bool]$step.isDiff) {
      $laneState[$laneName].diffDetected = $true
    }

    $candidateFailureClass = if ($step.PSObject.Properties['failureClass']) { [string]$step.failureClass } else { 'none' }
    if ([string]::IsNullOrWhiteSpace($candidateFailureClass)) {
      $candidateFailureClass = 'none'
    }
    if (-not $failurePriority.ContainsKey($candidateFailureClass)) {
      $candidateFailureClass = 'cli/tool'
    }
    $currentFailureClass = [string]$laneState[$laneName].failureClass
    if (-not $failurePriority.ContainsKey($currentFailureClass)) {
      $currentFailureClass = 'none'
    }
    if ($failurePriority[$candidateFailureClass] -gt $failurePriority[$currentFailureClass]) {
      $laneState[$laneName].failureClass = $candidateFailureClass
    }
  }

  foreach ($laneName in @('windows', 'linux')) {
    $lane = $laneState[$laneName]
    if ($lane.total -eq 0) {
      $lane.status = 'skipped'
    } elseif ($lane.failed -gt 0) {
      $lane.status = 'failure'
    } else {
      $lane.status = 'success'
    }
    if ($lane.status -eq 'success' -and [string]$lane.failureClass -ne 'none') {
      $lane.failureClass = 'none'
    }
  }

  return $laneState
}

function Get-ClassificationAggregate {
  param([Parameter(Mandatory)][object[]]$Steps)

  $diffStepCount = 0
  $diffEvidenceSteps = 0
  $extractedReportCount = 0
  $containerExportFailureCount = 0
  $runtimeFailureCount = 0
  $toolFailureCount = 0
  $timeoutFailureCount = 0
  $preflightFailureCount = 0

  foreach ($step in @($Steps)) {
    if (-not $step) { continue }
    if ($step.PSObject.Properties['isDiff'] -and [bool]$step.isDiff) {
      $diffStepCount++
    }
    $diffEvidenceSource = if ($step.PSObject.Properties['diffEvidenceSource']) { [string]$step.diffEvidenceSource } else { '' }
    if ([string]::Equals($diffEvidenceSource, 'html', [System.StringComparison]::OrdinalIgnoreCase)) {
      $diffEvidenceSteps++
    }
    $extractedReportPath = if ($step.PSObject.Properties['extractedReportPath']) { [string]$step.extractedReportPath } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($extractedReportPath)) {
      $extractedReportCount++
    }
    $containerExportStatus = if ($step.PSObject.Properties['containerExportStatus']) { [string]$step.containerExportStatus } else { '' }
    if ($containerExportStatus -in @('failed', 'partial')) {
      $containerExportFailureCount++
    }
    $failureClass = if ($step.PSObject.Properties['failureClass']) { [string]$step.failureClass } else { 'none' }
    switch ($failureClass) {
      'runtime-determinism' { $runtimeFailureCount++ }
      'startup-connectivity' { $toolFailureCount++ }
      'cli/tool' { $toolFailureCount++ }
      'timeout' { $timeoutFailureCount++ }
      'preflight' { $preflightFailureCount++ }
    }
  }

  [ordered]@{
    diffStepCount = [int]$diffStepCount
    diffEvidenceSteps = [int]$diffEvidenceSteps
    extractedReportCount = [int]$extractedReportCount
    containerExportFailureCount = [int]$containerExportFailureCount
    runtimeFailureCount = [int]$runtimeFailureCount
    toolFailureCount = [int]$toolFailureCount
    timeoutFailureCount = [int]$timeoutFailureCount
    preflightFailureCount = [int]$preflightFailureCount
  }
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  Ensure-ParentDirectory -Path $Path
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    New-Item -ItemType File -Path $Path -Force | Out-Null
  }
  Add-Content -LiteralPath $Path -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot
if (-not (Test-Path -LiteralPath $resultsRootResolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null
}

$summaryResolved = if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
  Get-LatestSummaryPath -Root $resultsRootResolved
} else {
  Resolve-AbsolutePath -Path $SummaryPath
}
if ([string]::IsNullOrWhiteSpace($summaryResolved) -or -not (Test-Path -LiteralPath $summaryResolved -PathType Leaf)) {
  throw ("Unable to locate docker fast-loop summary json under: {0}" -f $resultsRootResolved)
}

$statusResolved = if ([string]::IsNullOrWhiteSpace($StatusPath)) {
  Join-Path $resultsRootResolved 'docker-runtime-fastloop-status.json'
} else {
  Resolve-AbsolutePath -Path $StatusPath
}

$jsonOutResolved = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsRootResolved 'docker-runtime-fastloop-readiness.json'
} else {
  Resolve-AbsolutePath -Path $OutputJsonPath
}
$mdOutResolved = if ([string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
  Join-Path $resultsRootResolved 'docker-runtime-fastloop-readiness.md'
} else {
  Resolve-AbsolutePath -Path $OutputMarkdownPath
}

$summary = Read-JsonOrNull -Path $summaryResolved
if (-not $summary) {
  throw ("Unable to parse summary json: {0}" -f $summaryResolved)
}
$status = Read-JsonOrNull -Path $statusResolved
$steps = @()
if ($summary.steps) {
  $steps = @($summary.steps)
}

$lane = Get-LaneFromSteps -Steps $steps
$historical = Get-HistoricalStats -Root $resultsRootResolved -MaxRuns $HistoryRuns
$classification = Get-ClassificationAggregate -Steps $steps

$overallStatus = if ($summary.PSObject.Properties['status']) { [string]$summary.status } else { 'unknown' }
$historyScenarioSet = if ($summary.PSObject.Properties['historyScenarioSet']) { [string]$summary.historyScenarioSet } else { 'none' }
$historyScenarioCount = 0
if ($summary.PSObject.Properties['historyScenarioCount']) {
  $historyScenarioCount = [int]$summary.historyScenarioCount
}
$hardStopTriggered = $false
if ($summary.PSObject.Properties['hardStopTriggered']) {
  $hardStopTriggered = [bool]$summary.hardStopTriggered
}
$hardStopReason = if ($summary.PSObject.Properties['hardStopReason']) { [string]$summary.hardStopReason } else { '' }
$statusRecommendation = ''
$etaSeconds = 0.0
if ($status -and $status.PSObject.Properties['telemetry'] -and $status.telemetry) {
  if ($status.telemetry.PSObject.Properties['pushRecommendation']) {
    $statusRecommendation = [string]$status.telemetry.pushRecommendation
  }
  if ($status.telemetry.PSObject.Properties['etaSeconds']) {
    $etaSeconds = [double]$status.telemetry.etaSeconds
  }
}
$blockingFailureCount = [int]$classification.runtimeFailureCount + [int]$classification.toolFailureCount + [int]$classification.timeoutFailureCount + [int]$classification.preflightFailureCount
$allBlockingLanesSuccess = ($lane.windows.status -in @('success', 'skipped')) -and ($lane.linux.status -in @('success', 'skipped'))
$verdict = if ($blockingFailureCount -eq 0 -and -not $hardStopTriggered -and $allBlockingLanesSuccess) { 'ready-to-push' } else { 'not-ready' }
$statusRecommendation = if ($verdict -eq 'ready-to-push') { 'push' } else { 'do-not-push' }

$totalDurationMs = 0
foreach ($step in @($steps)) {
  if ($step.PSObject.Properties['durationMs']) {
    $totalDurationMs += [int]$step.durationMs
  }
}
$diffLaneCount = 0
if ([bool]$lane.windows.diffDetected) { $diffLaneCount++ }
if ([bool]$lane.linux.diffDetected) { $diffLaneCount++ }

$readiness = [ordered]@{
  schema = 'vi-history/docker-fast-loop-readiness@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  diffStepCount = [int]$classification.diffStepCount
  diffEvidenceSteps = [int]$classification.diffEvidenceSteps
  diffLaneCount = [int]$diffLaneCount
  extractedReportCount = [int]$classification.extractedReportCount
  containerExportFailureCount = [int]$classification.containerExportFailureCount
  runtimeFailureCount = [int]$classification.runtimeFailureCount
  toolFailureCount = [int]$classification.toolFailureCount
  hardStopTriggered = [bool]$hardStopTriggered
  hardStopReason = $hardStopReason
  source = [ordered]@{
    summaryPath = $summaryResolved
    statusPath = if (Test-Path -LiteralPath $statusResolved -PathType Leaf) { $statusResolved } else { '' }
    resultsRoot = $resultsRootResolved
  }
  verdict = $verdict
  recommendation = $statusRecommendation
  run = [ordered]@{
    status = $overallStatus
    historyScenarioSet = $historyScenarioSet
    historyScenarioCount = [int]$historyScenarioCount
    hardStopTriggered = [bool]$hardStopTriggered
    hardStopReason = $hardStopReason
    diffStepCount = [int]$classification.diffStepCount
    diffEvidenceSteps = [int]$classification.diffEvidenceSteps
    extractedReportCount = [int]$classification.extractedReportCount
    containerExportFailureCount = [int]$classification.containerExportFailureCount
    runtimeFailureCount = [int]$classification.runtimeFailureCount
    toolFailureCount = [int]$classification.toolFailureCount
    timeoutFailureCount = [int]$classification.timeoutFailureCount
    preflightFailureCount = [int]$classification.preflightFailureCount
    completedSteps = @($steps).Count
    totalDurationMs = [int]$totalDurationMs
    totalDurationSeconds = [math]::Round(($totalDurationMs / 1000.0), 3)
    etaSeconds = [math]::Round($etaSeconds, 1)
  }
  lanes = [ordered]@{
    windows = [ordered]@{
      status = [string]$lane.windows.status
      diffDetected = [bool]$lane.windows.diffDetected
      failureClass = [string]$lane.windows.failureClass
      completed = [int]$lane.windows.completed
      total = [int]$lane.windows.total
      durationMs = [int]$lane.windows.durationMs
      durationSeconds = [math]::Round(($lane.windows.durationMs / 1000.0), 3)
    }
    linux = [ordered]@{
      status = [string]$lane.linux.status
      diffDetected = [bool]$lane.linux.diffDetected
      failureClass = [string]$lane.linux.failureClass
      completed = [int]$lane.linux.completed
      total = [int]$lane.linux.total
      durationMs = [int]$lane.linux.durationMs
      durationSeconds = [math]::Round(($lane.linux.durationMs / 1000.0), 3)
    }
  }
  history = $historical
  steps = @($steps)
}

Ensure-ParentDirectory -Path $jsonOutResolved
$readiness | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $jsonOutResolved -Encoding utf8

$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add('### Docker Fast-Loop Readiness') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('| Metric | Value |') | Out-Null
$mdLines.Add('| --- | --- |') | Out-Null
$mdLines.Add(('| Verdict | `{0}` |' -f $verdict)) | Out-Null
$mdLines.Add(('| Recommendation | `{0}` |' -f $statusRecommendation)) | Out-Null
$mdLines.Add(('| Run Status | `{0}` |' -f $overallStatus)) | Out-Null
$mdLines.Add(('| History Scenario Set | `{0}` |' -f $historyScenarioSet)) | Out-Null
$mdLines.Add(('| History Scenario Count | `{0}` |' -f $historyScenarioCount)) | Out-Null
$mdLines.Add(('| Hard Stop | `{0}` |' -f $hardStopTriggered)) | Out-Null
if (-not [string]::IsNullOrWhiteSpace($hardStopReason)) {
  $mdLines.Add(('| Hard Stop Reason | `{0}` |' -f $hardStopReason)) | Out-Null
}
$mdLines.Add(('| Diff Step Count | `{0}` |' -f $readiness.diffStepCount)) | Out-Null
$mdLines.Add(('| Diff Evidence Steps | `{0}` |' -f $readiness.diffEvidenceSteps)) | Out-Null
$mdLines.Add(('| Diff Lane Count | `{0}` |' -f $readiness.diffLaneCount)) | Out-Null
$mdLines.Add(('| Extracted Report Count | `{0}` |' -f $readiness.extractedReportCount)) | Out-Null
$mdLines.Add(('| Container Export Failure Count | `{0}` |' -f $readiness.containerExportFailureCount)) | Out-Null
$mdLines.Add(('| Runtime Failure Count | `{0}` |' -f $readiness.runtimeFailureCount)) | Out-Null
$mdLines.Add(('| Tool Failure Count | `{0}` |' -f $readiness.toolFailureCount)) | Out-Null
$mdLines.Add(('| Timeout Failure Count | `{0}` |' -f $readiness.run.timeoutFailureCount)) | Out-Null
$mdLines.Add(('| Preflight Failure Count | `{0}` |' -f $readiness.run.preflightFailureCount)) | Out-Null
$mdLines.Add(('| Completed Steps | `{0}` |' -f @($steps).Count)) | Out-Null
$mdLines.Add(('| Total Duration (s) | `{0}` |' -f (Convert-ToSecondsString -Milliseconds $totalDurationMs))) | Out-Null
$mdLines.Add(('| ETA (s) | `{0}` |' -f ([math]::Round($etaSeconds, 1)))) | Out-Null
$mdLines.Add(('| Readiness JSON | `{0}` |' -f $jsonOutResolved)) | Out-Null
$mdLines.Add('') | Out-Null

$mdLines.Add('| Lane | Status | Diff Detected | Failure Class | Completed | Total | Duration (s) | Hist Median (s) | Hist P90 (s) |') | Out-Null
$mdLines.Add('| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |') | Out-Null
foreach ($laneName in @('windows', 'linux')) {
  $laneData = $readiness.lanes.$laneName
  $histLane = $historical.lanes.$laneName
  $mdLines.Add(('| {0} | `{1}` | `{2}` | `{3}` | {4} | {5} | {6} | {7} | {8} |' -f `
      $laneName, `
      $laneData.status, `
      $laneData.diffDetected, `
      $laneData.failureClass, `
      $laneData.completed, `
      $laneData.total, `
      (Convert-ToSecondsString -Milliseconds ([double]$laneData.durationMs)), `
      (Convert-ToSecondsString -Milliseconds ([double]$histLane.medianMs)), `
      (Convert-ToSecondsString -Milliseconds ([double]$histLane.p90Ms)))) | Out-Null
}
$mdLines.Add('') | Out-Null

$mdLines.Add('| Step | Lane | Status | Exit | Result Class | Gate | Diff | Diff Source | Diff Images | Export | Failure Class | Duration (s) | Hist Median (s) | Hist P90 (s) |') | Out-Null
$mdLines.Add('| --- | --- | --- | ---: | --- | --- | --- | --- | ---: | --- | --- | ---: | ---: | ---: |') | Out-Null
foreach ($step in @($steps)) {
  $stepName = if ($step.PSObject.Properties['name']) { [string]$step.name } else { '<unknown>' }
  $laneName = Get-StepLane -StepName $stepName
  if ([string]::IsNullOrWhiteSpace($laneName)) { $laneName = '-' }
  $statusValue = if ($step.PSObject.Properties['status']) { [string]$step.status } else { 'unknown' }
  $exitCodeValue = if ($step.PSObject.Properties['exitCode']) { [string]$step.exitCode } else { '' }
  $resultClassValue = if ($step.PSObject.Properties['resultClass']) { [string]$step.resultClass } else { '' }
  $gateValue = if ($step.PSObject.Properties['gateOutcome']) { [string]$step.gateOutcome } else { '' }
  $isDiffValue = if ($step.PSObject.Properties['isDiff']) { [bool]$step.isDiff } else { $false }
  $diffEvidenceSourceValue = if ($step.PSObject.Properties['diffEvidenceSource']) { [string]$step.diffEvidenceSource } else { '' }
  if ([string]::IsNullOrWhiteSpace($diffEvidenceSourceValue)) { $diffEvidenceSourceValue = '-' }
  $diffImageCountValue = if ($step.PSObject.Properties['diffImageCount']) { [int]$step.diffImageCount } else { 0 }
  $containerExportStatusValue = if ($step.PSObject.Properties['containerExportStatus']) { [string]$step.containerExportStatus } else { '' }
  if ([string]::IsNullOrWhiteSpace($containerExportStatusValue)) { $containerExportStatusValue = '-' }
  $failureClassValue = if ($step.PSObject.Properties['failureClass']) { [string]$step.failureClass } else { '' }
  $durationMs = if ($step.PSObject.Properties['durationMs']) { [double]$step.durationMs } else { 0.0 }
  $histStep = if ($historical.steps.ContainsKey($stepName)) { $historical.steps[$stepName] } else { [ordered]@{ medianMs = 0; p90Ms = 0 } }
  $mdLines.Add(('| `{0}` | {1} | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | `{7}` | `{8}` | `{9}` | `{10}` | {11} | {12} | {13} |' -f `
      $stepName, `
      $laneName, `
      $statusValue, `
      $exitCodeValue, `
      $resultClassValue, `
      $gateValue, `
      $isDiffValue, `
      $diffEvidenceSourceValue, `
      $diffImageCountValue, `
      $containerExportStatusValue, `
      $failureClassValue, `
      (Convert-ToSecondsString -Milliseconds $durationMs), `
      (Convert-ToSecondsString -Milliseconds ([double]$histStep.medianMs)), `
      (Convert-ToSecondsString -Milliseconds ([double]$histStep.p90Ms)))) | Out-Null
}

Ensure-ParentDirectory -Path $mdOutResolved
$mdLines | Set-Content -LiteralPath $mdOutResolved -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  Ensure-ParentDirectory -Path $StepSummaryPath
  $mdLines | Add-Content -LiteralPath $StepSummaryPath -Encoding utf8
}

Write-GitHubOutput -Key 'readiness-json-path' -Value $jsonOutResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'readiness-markdown-path' -Value $mdOutResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'readiness-verdict' -Value $verdict -Path $GitHubOutputPath
Write-GitHubOutput -Key 'readiness-recommendation' -Value $statusRecommendation -Path $GitHubOutputPath

Write-Host ("[docker-fast-loop][readiness] verdict={0} recommendation={1}" -f $verdict, $statusRecommendation)
Write-Host ("[docker-fast-loop][readiness] json={0}" -f $jsonOutResolved)
Write-Host ("[docker-fast-loop][readiness] markdown={0}" -f $mdOutResolved)
Write-Output $jsonOutResolved
