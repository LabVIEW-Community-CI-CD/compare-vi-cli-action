#Requires -Version 7.0
<#
.SYNOPSIS
  Local deterministic fast-loop for Docker Desktop Windows + Linux lanes.

.DESCRIPTION
  Executes runtime determinism preflight and probe checks for:
  1) NI Windows container compare lane
  2) NI Linux container compare lane
  3) Linux history/report plumbing probe (fixture -> renderer)
  Writes a machine-readable summary and fails if any lane fails.
#>
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$LabVIEWPath = '',
  [string]$ResultsRoot = 'tests/results/local-parity',
  [string]$StatusPath = '',
  [string]$ReadinessJsonPath = '',
  [string]$ReadinessMarkdownPath = '',
  [ValidateSet('none', 'smoke', 'history-core')]
  [string]$HistoryScenarioSet = 'none',
  [ValidateSet('both', 'windows', 'linux')]
  [string]$LaneScope = 'both',
  [string]$HistoryHarnessPath = 'fixtures/vi-history/pr-harness.json',
  [string]$SequentialFixturePath = 'fixtures/vi-history/sequential.json',
  [ValidateRange(1, 86400)]
  [int]$StepTimeoutSeconds = 600,
  [bool]$ManageDockerEngine = $false,
  [ValidateSet('linux-first', 'windows-first')]
  [string]$LaneOrder = 'linux-first',
  [switch]$SkipWindowsProbe,
  [switch]$SkipLinuxProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$classifierScriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Compare-ExitCodeClassifier.ps1'
if (-not (Test-Path -LiteralPath $classifierScriptPath -PathType Leaf)) {
  throw ("Exit-code classifier script not found: {0}" -f $classifierScriptPath)
}
. $classifierScriptPath

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-RepoRootFromToolsScript {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-RepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string]$Description
  )

  $resolved = if ([System.IO.Path]::IsPathRooted($PathValue)) {
    [System.IO.Path]::GetFullPath($PathValue)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
  }
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw ("{0} not found: {1}" -f $Description, $resolved)
  }
  return $resolved
}

function Read-JsonFileOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 12)
  } catch {
    return $null
  }
}

function Get-RuntimeManagerLaneTelemetry {
  param(
    [Parameter(Mandatory)][ValidateSet('windows', 'linux')][string]$Lane,
    [Parameter(Mandatory)][string]$SnapshotPath
  )

  $snapshot = Read-JsonFileOrNull -Path $SnapshotPath
  $repairActions = @()
  if ($snapshot -and $snapshot.PSObject.Properties['repairActions'] -and $snapshot.repairActions) {
    $repairActions = @($snapshot.repairActions | ForEach-Object { [string]$_ })
  }

  $status = ''
  $failureClass = ''
  $probeParseReason = ''
  $observedOsType = ''
  $observedContext = ''
  if ($snapshot -and $snapshot.PSObject.Properties['result'] -and $snapshot.result) {
    if ($snapshot.result.PSObject.Properties['status']) { $status = [string]$snapshot.result.status }
    if ($snapshot.result.PSObject.Properties['failureClass']) { $failureClass = [string]$snapshot.result.failureClass }
    if ($snapshot.result.PSObject.Properties['probeParseReason']) { $probeParseReason = [string]$snapshot.result.probeParseReason }
  }
  if ($snapshot -and $snapshot.PSObject.Properties['observed'] -and $snapshot.observed) {
    if ($snapshot.observed.PSObject.Properties['osType']) { $observedOsType = [string]$snapshot.observed.osType }
    if ($snapshot.observed.PSObject.Properties['context']) { $observedContext = [string]$snapshot.observed.context }
  }
  if ([string]::IsNullOrWhiteSpace($probeParseReason) -and $snapshot -and $snapshot.PSObject.Properties['observed'] -and $snapshot.observed -and $snapshot.observed.PSObject.Properties['dockerOsProbe'] -and $snapshot.observed.dockerOsProbe -and $snapshot.observed.dockerOsProbe.PSObject.Properties['last'] -and $snapshot.observed.dockerOsProbe.last -and $snapshot.observed.dockerOsProbe.last.PSObject.Properties['parseReason']) {
    $probeParseReason = [string]$snapshot.observed.dockerOsProbe.last.parseReason
  }

  $contextSwitchCount = 0
  $engineSwitchCount = 0
  $serviceRecoveryCount = 0
  foreach ($action in @($repairActions)) {
    if ($action -match '(?i)^docker context use ') { $contextSwitchCount++ }
    if ($action -match '(?i)^docker engine switch to ') { $engineSwitchCount++ }
    if ($action -match '(?i)^docker service recovery:') { $serviceRecoveryCount++ }
  }

  return [ordered]@{
    lane = $Lane
    snapshotPath = $SnapshotPath
    snapshotPresent = ($null -ne $snapshot)
    status = $status
    failureClass = if ([string]::IsNullOrWhiteSpace($failureClass)) { 'none' } else { $failureClass }
    probeParseReason = $probeParseReason
    observedOsType = $observedOsType
    observedContext = $observedContext
    repairActionCount = @($repairActions).Count
    contextSwitchCount = [int]$contextSwitchCount
    engineSwitchCount = [int]$engineSwitchCount
    serviceRecoveryCount = [int]$serviceRecoveryCount
    daemonUnavailable = ([string]$failureClass -eq 'daemon-unavailable')
    parseDefect = ([string]$failureClass -eq 'parse-defect')
    repairActions = @($repairActions)
  }
}

function Get-RuntimeManagerTelemetry {
  param(
    [Parameter(Mandatory)][string]$WindowsSnapshotPath,
    [Parameter(Mandatory)][string]$LinuxSnapshotPath
  )

  $windows = Get-RuntimeManagerLaneTelemetry -Lane windows -SnapshotPath $WindowsSnapshotPath
  $linux = Get-RuntimeManagerLaneTelemetry -Lane linux -SnapshotPath $LinuxSnapshotPath
  return [ordered]@{
    schema = 'docker-fast-loop/runtime-manager@v1'
    lanes = [ordered]@{
      windows = $windows
      linux = $linux
    }
    transitionCount = [int]($windows.repairActionCount + $linux.repairActionCount)
    contextSwitchCount = [int]($windows.contextSwitchCount + $linux.contextSwitchCount)
    engineSwitchCount = [int]($windows.engineSwitchCount + $linux.engineSwitchCount)
    serviceRecoveryCount = [int]($windows.serviceRecoveryCount + $linux.serviceRecoveryCount)
    daemonUnavailableCount = [int](([int]$windows.daemonUnavailable) + ([int]$linux.daemonUnavailable))
    parseDefectCount = [int](([int]$windows.parseDefect) + ([int]$linux.parseDefect))
  }
}

function Get-HistoryScenarioIdsForSet {
  param(
    [Parameter(Mandatory)][string]$ScenarioSet,
    [Parameter(Mandatory)][object]$Harness
  )

  $diagnostics = New-Object System.Collections.Generic.List[string]
  $scenarioMap = @{}
  foreach ($scenario in @($Harness.scenarios)) {
    if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
    $id = [string]$scenario.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $scenarioMap[$id] = $scenario
  }

  switch ($ScenarioSet) {
    'none' {
      return [pscustomobject]@{
        scenarioIds = @()
        diagnostics = @()
      }
    }
    'smoke' {
      $preferred = @('attribute', 'sequential')
      $resolved = New-Object System.Collections.Generic.List[string]
      foreach ($id in $preferred) {
        if (-not $scenarioMap.ContainsKey($id)) {
          $diagnostics.Add(("History smoke scenario '{0}' is not present in harness manifest." -f $id)) | Out-Null
          continue
        }
        $scenario = $scenarioMap[$id]
        $requireDiff = $false
        if ($scenario.PSObject.Properties['requireDiff']) {
          $requireDiff = [bool]$scenario.requireDiff
        }
        if ($requireDiff) {
          $resolved.Add($id) | Out-Null
        } else {
          $diagnostics.Add(("History smoke scenario '{0}' skipped because requireDiff=true is required." -f $id)) | Out-Null
        }
      }
      if ($resolved.Count -eq 0) {
        $details = if ($diagnostics.Count -gt 0) { [string]::Join(' ', @($diagnostics.ToArray())) } else { '' }
        throw ("History smoke scenario set resolved to empty after requireDiff=true filtering. {0}" -f $details)
      }
      return [pscustomobject]@{
        scenarioIds = @($resolved.ToArray())
        diagnostics = @($diagnostics.ToArray())
      }
    }
    'history-core' {
      if (-not $Harness.scenarios -or @($Harness.scenarios).Count -eq 0) {
        throw 'History core scenario set requires at least one scenario in the harness manifest.'
      }
      $resolved = New-Object System.Collections.Generic.List[string]
      foreach ($scenario in @($Harness.scenarios)) {
        if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
        $id = [string]$scenario.id
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $requireDiff = $false
        if ($scenario.PSObject.Properties['requireDiff']) {
          $requireDiff = [bool]$scenario.requireDiff
        }
        if ($requireDiff) {
          $resolved.Add($id) | Out-Null
        } else {
          $diagnostics.Add(("History scenario '{0}' skipped because requireDiff=true is required for history-core." -f $id)) | Out-Null
        }
      }
      if ($resolved.Count -eq 0) {
        $details = if ($diagnostics.Count -gt 0) { [string]::Join(' ', @($diagnostics.ToArray())) } else { '' }
        throw ("History core scenario set resolved to empty after requireDiff=true filtering. {0}" -f $details)
      }
      return [pscustomobject]@{
        scenarioIds = @($resolved.ToArray())
        diagnostics = @($diagnostics.ToArray())
      }
    }
    default {
      throw ("Unsupported HistoryScenarioSet: {0}" -f $ScenarioSet)
    }
  }
}

function Invoke-WindowsHistoryCompare {
  param(
    [Parameter(Mandatory)][string]$BaseVi,
    [Parameter(Mandatory)][string]$HeadVi,
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$LabVIEWPath,
    [Parameter(Mandatory)][string]$WindowsImage,
    [Parameter(Mandatory)][string]$RuntimeSnapshotPath,
    [Parameter(Mandatory)][bool]$RuntimeAutoRepair,
    [Parameter(Mandatory)][bool]$ManageDockerEngine,
    [Parameter(Mandatory)][int]$StepTimeoutSeconds
  )

  $reportDir = Split-Path -Parent $ReportPath
  if ($reportDir -and -not (Test-Path -LiteralPath $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
  }

  $runtimeGuardScript = Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1'
  if (-not (Test-Path -LiteralPath $runtimeGuardScript -PathType Leaf)) {
    throw ("Runtime guard script not found: {0}" -f $runtimeGuardScript)
  }
  & pwsh -NoLogo -NoProfile -File $runtimeGuardScript `
    -ExpectedOsType windows `
    -ExpectedContext desktop-windows `
    -AutoRepair:$RuntimeAutoRepair `
    -ManageDockerEngine:$ManageDockerEngine `
    -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
    -EngineReadyPollSeconds 3 `
    -SnapshotPath $RuntimeSnapshotPath `
    -GitHubOutputPath '' | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw ("Windows runtime preflight failed before history compare. Snapshot: {0}" -f $RuntimeSnapshotPath)
  }

  $windowsCompareArgs = @(
    '-NoLogo', '-NoProfile',
    '-File', (Join-Path $PSScriptRoot 'Run-NIWindowsContainerCompare.ps1'),
    '-BaseVi', $BaseVi,
    '-HeadVi', $HeadVi,
    '-Image', $WindowsImage,
    '-ReportPath', $ReportPath,
    '-TimeoutSeconds', [string]$StepTimeoutSeconds,
    "-AutoRepairRuntime:$RuntimeAutoRepair",
    "-ManageDockerEngine:$ManageDockerEngine",
    '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
    '-RuntimeEngineReadyPollSeconds', '3',
    '-RuntimeSnapshotPath', $RuntimeSnapshotPath
  )
  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $windowsCompareArgs += @('-LabVIEWPath', $LabVIEWPath)
  }
  & pwsh @windowsCompareArgs | Out-Null

  $compareExit = $LASTEXITCODE

  $capturePath = Join-Path $reportDir 'ni-windows-container-capture.json'
  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    throw ("Windows history compare capture missing: {0}" -f $capturePath)
  }
  $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 8
  $captureMessage = if ($capture.PSObject.Properties['message']) { [string]$capture.message } else { '' }
  $runtimeStatus = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['status']) { [string]$capture.runtimeDeterminism.status } else { '' }
  $runtimeReason = if ($capture.PSObject.Properties['runtimeDeterminism'] -and $capture.runtimeDeterminism -and $capture.runtimeDeterminism.PSObject.Properties['reason']) { [string]$capture.runtimeDeterminism.reason } else { '' }
  $classification = if (
    $capture.PSObject.Properties['resultClass'] -and
    $capture.PSObject.Properties['isDiff'] -and
    $capture.PSObject.Properties['gateOutcome'] -and
    $capture.PSObject.Properties['failureClass']
  ) {
    [pscustomobject]@{
      resultClass = [string]$capture.resultClass
      isDiff = [bool]$capture.isDiff
      gateOutcome = [string]$capture.gateOutcome
      failureClass = [string]$capture.failureClass
    }
  } else {
    Get-CompareExitClassification `
      -ExitCode $compareExit `
      -CaptureStatus ([string]$capture.status) `
      -StdOut '' `
      -StdErr '' `
      -Message $captureMessage `
      -RuntimeDeterminismStatus $runtimeStatus `
      -RuntimeDeterminismReason $runtimeReason `
      -TimedOut:([bool]($capture.PSObject.Properties['timedOut'] -and [bool]$capture.timedOut))
  }

  if (
    [string]$classification.failureClass -eq 'preflight' -and
    (
      $captureMessage -match '(?i)runtime determinism' -or
      $captureMessage -match '(?i)runtime invariant mismatch' -or
      $captureMessage -match '(?i)expected os=' -or
      $captureMessage -match '(?i)docker desktop is unable to start' -or
      $captureMessage -match '(?i)dockerdesktop/wsl/execerror'
    )
  ) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-runtime'
      isDiff = $false
      gateOutcome = 'fail'
      failureClass = 'runtime-determinism'
    }
  }

  $validationMessage = ''
  if ([string]$classification.gateOutcome -eq 'pass' -and -not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    $classification = [pscustomobject]@{
      resultClass = 'failure-tool'
      isDiff = [bool]$classification.isDiff
      gateOutcome = 'fail'
      failureClass = 'cli/tool'
    }
    $validationMessage = ("Windows history compare report missing: {0}" -f $ReportPath)
  }
  $effectiveMessage = $captureMessage
  if (-not [string]::IsNullOrWhiteSpace($validationMessage)) {
    if ([string]::IsNullOrWhiteSpace($effectiveMessage)) {
      $effectiveMessage = $validationMessage
    } else {
      $effectiveMessage = ("{0} | {1}" -f $effectiveMessage, $validationMessage)
    }
  }

  return [pscustomobject]@{
    ExitCode = [int]$compareExit
    CapturePath = $capturePath
    Capture = $capture
    Classification = $classification
    Message = $effectiveMessage
    ReportPath = $ReportPath
  }
}

function Get-StepLane {
  param([Parameter(Mandatory)][string]$StepName)
  if ($StepName -like 'windows-*') { return 'windows' }
  if ($StepName -like 'linux-*') { return 'linux' }
  return ''
}

function Get-MedianMs {
  param([Parameter(Mandatory)][int[]]$Values)
  if (-not $Values -or $Values.Count -eq 0) { return 0 }
  $sorted = @($Values | Sort-Object)
  $count = $sorted.Count
  $mid = [math]::Floor($count / 2)
  if (($count % 2) -eq 1) {
    return [int]$sorted[$mid]
  }
  return [int][math]::Round((([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0), 0)
}

function Get-HistoricalStepDurationMedians {
  param(
    [Parameter(Mandatory)][string]$ResultsDir,
    [int]$MaxRuns = 25
  )

  $durations = @{}
  $files = Get-ChildItem -LiteralPath $ResultsDir -Filter 'docker-runtime-fastloop-*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^docker-runtime-fastloop-\d{14}\.json$' } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First $MaxRuns

  foreach ($file in @($files)) {
    try {
      $summary = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 10
    } catch {
      continue
    }
    if (-not $summary -or -not $summary.steps) { continue }
    foreach ($step in @($summary.steps)) {
      if (-not $step -or -not $step.PSObject -or -not $step.PSObject.Properties['name']) { continue }
      $stepName = [string]$step.PSObject.Properties['name'].Value
      $duration = 0
      if ($step.PSObject.Properties['durationMs']) {
        $duration = [int]$step.PSObject.Properties['durationMs'].Value
      }
      if ($duration -le 0) { continue }
      if (-not $durations.ContainsKey($stepName)) {
        $durations[$stepName] = New-Object System.Collections.Generic.List[int]
      }
      $durations[$stepName].Add($duration) | Out-Null
    }
  }

  $medians = @{}
  foreach ($key in @($durations.Keys)) {
    $values = @($durations[$key].ToArray())
    if ($values.Count -eq 0) { continue }
    $medians[$key] = Get-MedianMs -Values $values
  }
  return $medians
}

function Get-LaneLifecycleFromPlan {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ObservedSteps,
    [Parameter(Mandatory)][string]$Phase,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = ''
  )

  $laneNames = @('windows', 'linux')
  $lifecycle = [ordered]@{}
  foreach ($laneName in $laneNames) {
    $lifecycle[$laneName] = [ordered]@{
      totalPlannedSteps = 0
      executedSteps = 0
      started = $false
      completed = $false
      status = 'skipped'
      startStep = ''
      endStep = ''
      startedAt = ''
      endedAt = ''
      hardStopTriggered = $false
      stopClass = 'none'
      stopReason = ''
    }
  }

  foreach ($planStep in @($StepPlan)) {
    $laneName = Get-StepLane -StepName $planStep
    if ([string]::IsNullOrWhiteSpace($laneName) -or -not $lifecycle.Contains($laneName)) { continue }
    $lifecycle[$laneName].totalPlannedSteps = [int]$lifecycle[$laneName].totalPlannedSteps + 1
    if ([string]$lifecycle[$laneName].status -eq 'skipped') {
      $lifecycle[$laneName].status = 'pending'
    }
  }

  foreach ($step in @($ObservedSteps)) {
    if (-not $step -or -not $step.PSObject.Properties['name']) { continue }
    $stepName = [string]$step.name
    $laneName = Get-StepLane -StepName $stepName
    if ([string]::IsNullOrWhiteSpace($laneName) -or -not $lifecycle.Contains($laneName)) { continue }

    $lane = $lifecycle[$laneName]
    $lane.executedSteps = [int]$lane.executedSteps + 1
    $lane.started = $true
    if ([string]::IsNullOrWhiteSpace([string]$lane.startStep)) {
      $lane.startStep = $stepName
    }
    $lane.endStep = $stepName
    if ([string]::IsNullOrWhiteSpace([string]$lane.startedAt) -and $step.PSObject.Properties['startedAt']) {
      $lane.startedAt = [string]$step.startedAt
    }
    if ($step.PSObject.Properties['finishedAt']) {
      $lane.endedAt = [string]$step.finishedAt
    }

    $stepStatus = if ($step.PSObject.Properties['status']) { [string]$step.status } else { '' }
    if ($stepStatus -ne 'success') {
      $lane.status = 'failure'
      $lane.stopClass = 'failure'
      if ($step.PSObject.Properties['hardStopTriggered'] -and [bool]$step.hardStopTriggered) {
        $lane.hardStopTriggered = $true
        $lane.stopClass = 'hard-stop'
      }
      $failureClassText = if ($step.PSObject.Properties['failureClass']) { [string]$step.failureClass } else { '' }
      $messageText = if ($step.PSObject.Properties['message']) { [string]$step.message } else { '' }
      if (-not [string]::IsNullOrWhiteSpace($messageText)) {
        $lane.stopReason = $messageText
      } elseif (-not [string]::IsNullOrWhiteSpace($failureClassText)) {
        $lane.stopReason = ("failureClass={0}" -f $failureClassText)
      } else {
        $lane.stopReason = 'step-failure'
      }
      continue
    }

    if ([string]$lane.status -notin @('failure', 'success', 'incomplete')) {
      $lane.status = 'running'
    }
  }

  foreach ($laneName in $laneNames) {
    $lane = $lifecycle[$laneName]
    $planned = [int]$lane.totalPlannedSteps
    $executed = [int]$lane.executedSteps

    if ($planned -eq 0) {
      $lane.status = 'skipped'
      $lane.completed = $false
      $lane.stopClass = 'none'
      $lane.stopReason = ''
      continue
    }

    if ($executed -eq 0) {
      if ($HardStopTriggered) {
        $lane.status = 'blocked'
        $lane.stopClass = 'blocked'
        $lane.stopReason = if ([string]::IsNullOrWhiteSpace($HardStopReason)) { 'blocked-by-hard-stop' } else { $HardStopReason }
      } elseif ($Phase -eq 'completed') {
        $lane.status = 'blocked'
        $lane.stopClass = 'blocked'
        $lane.stopReason = 'lane-not-started'
      } else {
        $lane.status = 'pending'
        $lane.stopClass = 'none'
      }
      continue
    }

    if ([string]$lane.status -eq 'failure') {
      $lane.completed = ($executed -ge $planned)
      if ($lane.hardStopTriggered -and [string]::IsNullOrWhiteSpace([string]$lane.stopReason) -and -not [string]::IsNullOrWhiteSpace($HardStopReason)) {
        $lane.stopReason = $HardStopReason
      }
      continue
    }

    if ($executed -ge $planned) {
      $lane.status = 'success'
      $lane.completed = $true
      $lane.stopClass = 'completed'
      if ([string]::IsNullOrWhiteSpace([string]$lane.stopReason)) {
        $lane.stopReason = 'lane-complete'
      }
      continue
    }

    $lane.completed = $false
    if ($HardStopTriggered) {
      $lane.status = 'incomplete'
      $lane.stopClass = 'blocked'
      $lane.stopReason = if ([string]::IsNullOrWhiteSpace($HardStopReason)) { 'hard-stop-before-lane-complete' } else { $HardStopReason }
    } else {
      $lane.status = if ($Phase -eq 'completed') { 'incomplete' } else { 'running' }
      if ([string]$lane.stopClass -eq 'none') {
        $lane.stopReason = ''
      }
    }
  }

  return $lifecycle
}

function New-StatusTelemetry {
  param(
    [Parameter(Mandatory)][string]$RunStatus,
    [Parameter(Mandatory)][string]$Phase,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ObservedSteps,
    [Parameter(Mandatory)][hashtable]$HistoricalMedians,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = ''
  )

  $completedDurationMs = 0
  $failedSteps = 0
  $completedNames = New-Object System.Collections.Generic.HashSet[string]
  $laneTotals = @{ windows = 0; linux = 0 }
  $laneCompleted = @{ windows = 0; linux = 0 }

  foreach ($planStep in @($StepPlan)) {
    $laneName = Get-StepLane -StepName $planStep
    if (-not [string]::IsNullOrWhiteSpace($laneName) -and $laneTotals.ContainsKey($laneName)) {
      $laneTotals[$laneName] = [int]$laneTotals[$laneName] + 1
    }
  }

  foreach ($step in @($ObservedSteps)) {
    if (-not $step -or -not $step.PSObject.Properties['name']) { continue }
    $name = [string]$step.name
    $completedNames.Add($name) | Out-Null
    $laneName = Get-StepLane -StepName $name
    if (-not [string]::IsNullOrWhiteSpace($laneName) -and $laneCompleted.ContainsKey($laneName)) {
      $laneCompleted[$laneName] = [int]$laneCompleted[$laneName] + 1
    }
    if ($step.PSObject.Properties['durationMs']) {
      $completedDurationMs += [int]$step.durationMs
    }
    if ($step.PSObject.Properties['status'] -and [string]$step.status -ne 'success') {
      $failedSteps++
    }
  }

  $remainingEstimateMs = 0
  foreach ($planned in @($StepPlan)) {
    if ($completedNames.Contains($planned)) { continue }
    if ($HistoricalMedians.ContainsKey($planned)) {
      $remainingEstimateMs += [int]$HistoricalMedians[$planned]
    } else {
      $remainingEstimateMs += 5000
    }
  }

  $etaSeconds = [math]::Round(($remainingEstimateMs / 1000.0), 1)
  $pushRecommendation = 'hold'
  $canPush = $false
  if ($Phase -eq 'completed' -and $RunStatus -eq 'success') {
    $pushRecommendation = 'push'
    $canPush = $true
  } elseif ($Phase -eq 'completed' -and $RunStatus -ne 'success') {
    $pushRecommendation = 'do-not-push'
  }
  $laneLifecycle = Get-LaneLifecycleFromPlan `
    -StepPlan $StepPlan `
    -ObservedSteps $ObservedSteps `
    -Phase $Phase `
    -HardStopTriggered:$HardStopTriggered `
    -HardStopReason $HardStopReason

  return [ordered]@{
    completedDurationMs = [int]$completedDurationMs
    remainingEstimateMs = [int]$remainingEstimateMs
    etaSeconds = $etaSeconds
    failedSteps = [int]$failedSteps
    laneProgress = [ordered]@{
      windows = [ordered]@{ completed = [int]$laneCompleted.windows; total = [int]$laneTotals.windows }
      linux = [ordered]@{ completed = [int]$laneCompleted.linux; total = [int]$laneTotals.linux }
    }
    laneLifecycle = $laneLifecycle
    pushRecommendation = $pushRecommendation
    canPush = [bool]$canPush
  }
}

function Write-SemiLiveStatus {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$StartedAt,
    [Parameter(Mandatory)][string]$RunStatus,
    [Parameter(Mandatory)][string]$Phase,
    [AllowEmptyString()][string]$CurrentStep,
    [Parameter(Mandatory)][int]$CompletedSteps,
    [Parameter(Mandatory)][int]$TotalSteps,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$StepPlan,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Steps,
    [Parameter(Mandatory)][hashtable]$HistoricalStepMedians,
    [bool]$HardStopTriggered = $false,
    [AllowEmptyString()][string]$HardStopReason = '',
    [AllowEmptyString()][string]$SummaryPath,
    [AllowNull()]$RuntimeManagerTelemetry = $null
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }
  $statusDir = Split-Path -Parent $Path
  if ($statusDir -and -not (Test-Path -LiteralPath $statusDir -PathType Container)) {
    New-Item -ItemType Directory -Path $statusDir -Force | Out-Null
  }
  $telemetry = New-StatusTelemetry `
    -RunStatus $RunStatus `
    -Phase $Phase `
    -StepPlan $StepPlan `
    -ObservedSteps $Steps `
    -HistoricalMedians $HistoricalStepMedians `
    -HardStopTriggered:$HardStopTriggered `
    -HardStopReason $HardStopReason

  $payload = [ordered]@{
    schema = 'docker-desktop-fast-loop-status@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    startedAt = $StartedAt
    phase = $Phase
    status = $RunStatus
    currentStep = ($CurrentStep ?? '')
    completedSteps = [int]$CompletedSteps
    totalSteps = [int]$TotalSteps
    percentComplete = if ($TotalSteps -gt 0) { [math]::Round((100.0 * $CompletedSteps / $TotalSteps), 1) } else { 100.0 }
    windowsImage = $WindowsImage
    linuxImage = $LinuxImage
    historyScenarioSet = $HistoryScenarioSet
    laneScope = $LaneScope
    singleLaneMode = [bool]$singleLaneMode
    runtimeAutoRepair = [bool]$runtimeAutoRepairEnabled
    stepTimeoutSeconds = [int]$StepTimeoutSeconds
    manageDockerEngine = [bool]$effectiveManageDockerEngine
    hardStopTriggered = [bool]$HardStopTriggered
    hardStopReason = ($HardStopReason ?? '')
    laneLifecycle = $telemetry.laneLifecycle
    telemetry = $telemetry
    runtimeManager = $RuntimeManagerTelemetry
    steps = @($Steps)
    summaryPath = ($SummaryPath ?? '')
  }
  $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Invoke-StepActionWithTimeout {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [Parameter(Mandatory)][int]$TimeoutSeconds
  )

  $threadJobAvailable = $null -ne (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
  if (-not $threadJobAvailable) {
    $global:LASTEXITCODE = 0
    try {
      $directOutput = & $Action
      $directExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $true
        exitCode = [int]$directExit
        output = $directOutput
        errorMessage = ''
      }
    } catch {
      $directExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $false
        exitCode = [int]$directExit
        output = $null
        errorMessage = [string]$_.Exception.Message
      }
    }
  }

  $job = $null
  try {
    $job = Start-ThreadJob -ScriptBlock {
      param([scriptblock]$InnerAction)
      Set-StrictMode -Version Latest
      $ErrorActionPreference = 'Stop'
      $global:LASTEXITCODE = 0
      try {
        $innerOutput = & $InnerAction
        $innerExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{
          timedOut = $false
          succeeded = $true
          exitCode = [int]$innerExit
          output = $innerOutput
          errorMessage = ''
        }
      } catch {
        $innerExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        [pscustomobject]@{
          timedOut = $false
          succeeded = $false
          exitCode = [int]$innerExit
          output = $null
          errorMessage = [string]$_.Exception.Message
        }
      }
    } -ArgumentList $Action

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
      Stop-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
      return [pscustomobject]@{
        timedOut = $true
        succeeded = $false
        exitCode = 124
        output = $null
        errorMessage = ("Step timed out after {0} second(s)." -f [int]$TimeoutSeconds)
      }
    }

    $jobResult = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) | Select-Object -Last 1
    if (-not $jobResult) {
      return [pscustomobject]@{
        timedOut = $false
        succeeded = $false
        exitCode = 1
        output = $null
        errorMessage = 'Step runner returned no output.'
      }
    }
    return $jobResult
  } finally {
    if ($job) {
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    }
  }
}

function Get-NormalizedStepExitCode {
  param(
    [Parameter(Mandatory)][int]$ExitCode,
    [AllowNull()][AllowEmptyString()][string]$ResultClass,
    [AllowNull()][AllowEmptyString()][string]$GateOutcome,
    [AllowNull()][AllowEmptyString()][string]$FailureClass
  )

  $normalizedExit = [int]$ExitCode
  $gate = if ([string]::IsNullOrWhiteSpace($GateOutcome)) { '' } else { $GateOutcome.Trim().ToLowerInvariant() }
  $result = if ([string]::IsNullOrWhiteSpace($ResultClass)) { '' } else { $ResultClass.Trim().ToLowerInvariant() }
  $failure = if ([string]::IsNullOrWhiteSpace($FailureClass)) { '' } else { $FailureClass.Trim().ToLowerInvariant() }

  if ($gate -ne 'fail' -or $normalizedExit -ne 0) {
    return $normalizedExit
  }

  switch ($failure) {
    'timeout' { return 124 }
    'runtime-determinism' { return 2 }
    'preflight' { return 2 }
    'startup-connectivity' { return 1 }
    'cli/tool' { return 1 }
  }

  switch ($result) {
    'failure-timeout' { return 124 }
    'failure-runtime' { return 2 }
    'failure-preflight' { return 2 }
    default { return 1 }
  }
}

function Invoke-Step {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$Action,
    [int[]]$AllowedExitCodes = @(0),
    [bool]$HardStopOnRuntimeFailure = $false,
    [scriptblock]$CaptureValidator,
    [int]$TimeoutSeconds = 600
  )

  $stepStartUtc = (Get-Date).ToUniversalTime()
  $stepOutput = $null
  $stepExitCode = 0
  $stepStatus = 'failure'
  $stepMessage = ''
  $resultClass = 'failure-tool'
  $gateOutcome = 'fail'
  $failureClass = 'cli/tool'
  $isDiff = $false
  $diffEvidenceSource = ''
  $diffImageCount = 0
  $extractedReportPath = ''
  $containerExportStatus = ''

  try {
    $execution = Invoke-StepActionWithTimeout -Action $Action -TimeoutSeconds $TimeoutSeconds
    $stepOutput = $execution.output
    $stepExitCode = [int]$execution.exitCode

    if ([bool]$execution.timedOut) {
      $stepStatus = 'failure'
      $stepMessage = [string]$execution.errorMessage
      $resultClass = 'failure-timeout'
      $gateOutcome = 'fail'
      $failureClass = 'timeout'
    } else {
      if (-not [bool]$execution.succeeded) {
        throw ([System.Exception]::new([string]$execution.errorMessage))
      }

      $classification = $null
      if ($CaptureValidator) {
        $classification = & $CaptureValidator $stepOutput $stepExitCode
      }
      if (-not $classification) {
        $defaultStatus = if ($AllowedExitCodes -contains $stepExitCode) { 'ok' } else { 'error' }
        $classification = Get-CompareExitClassification `
          -ExitCode $stepExitCode `
          -CaptureStatus $defaultStatus `
          -StdOut '' `
          -StdErr '' `
          -Message ''
      }

      $resultClass = [string]$classification.resultClass
      $gateOutcome = [string]$classification.gateOutcome
      $failureClass = [string]$classification.failureClass
      $isDiff = [bool]$classification.isDiff
      if ($classification.PSObject.Properties['message']) {
        $stepMessage = [string]$classification.message
      }
      if ($classification.PSObject.Properties['diffEvidenceSource']) {
        $diffEvidenceSource = [string]$classification.diffEvidenceSource
      }
      if ($classification.PSObject.Properties['diffImageCount']) {
        $diffImageCount = [int]$classification.diffImageCount
      }
      if ($classification.PSObject.Properties['extractedReportPath']) {
        $extractedReportPath = [string]$classification.extractedReportPath
      }
      if ($classification.PSObject.Properties['containerExportStatus']) {
        $containerExportStatus = [string]$classification.containerExportStatus
      }
      $stepExitCode = Get-NormalizedStepExitCode `
        -ExitCode $stepExitCode `
        -ResultClass $resultClass `
        -GateOutcome $gateOutcome `
        -FailureClass $failureClass

      if (-not ($AllowedExitCodes -contains $stepExitCode) -and $gateOutcome -eq 'pass') {
        $gateOutcome = 'fail'
        $resultClass = 'failure-preflight'
        $failureClass = 'preflight'
        $stepMessage = ("Native command exited with disallowed code {0}." -f $stepExitCode)
      } elseif (-not ($AllowedExitCodes -contains $stepExitCode) -and [string]::IsNullOrWhiteSpace($stepMessage)) {
        $stepMessage = ("Native command exited with code {0}." -f $stepExitCode)
      }

      if ($gateOutcome -eq 'pass') {
        $stepStatus = 'success'
      } else {
        $stepStatus = 'failure'
        if ([string]::IsNullOrWhiteSpace($stepMessage)) {
          $stepMessage = ("Step failed with resultClass={0} failureClass={1} exit={2}." -f $resultClass, $failureClass, $stepExitCode)
        }
      }
    }
  } catch {
    $stepExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $stepMessage = $_.Exception.Message
    $fallback = Get-CompareExitClassification `
      -ExitCode $stepExitCode `
      -CaptureStatus 'error' `
      -StdOut '' `
      -StdErr '' `
      -Message $stepMessage
    $resultClass = [string]$fallback.resultClass
    $gateOutcome = [string]$fallback.gateOutcome
    $failureClass = [string]$fallback.failureClass
    $isDiff = [bool]$fallback.isDiff
    $stepStatus = 'failure'
  }

  $hardStopEligible = [bool]$HardStopOnRuntimeFailure -or ($failureClass -eq 'runtime-determinism')
  $hardStopTriggered = ($stepStatus -ne 'success' -and $hardStopEligible)
  $stepEndUtc = (Get-Date).ToUniversalTime()
  $durationMs = [math]::Round(($stepEndUtc - $stepStartUtc).TotalMilliseconds, 0)

  $capturePath = ''
  if ($stepOutput -and $stepOutput.PSObject -and $stepOutput.PSObject.Properties['CapturePath']) {
    $capturePath = [string]$stepOutput.CapturePath
  }
  if ($stepOutput -and $stepOutput.PSObject -and $stepOutput.PSObject.Properties['Capture'] -and $stepOutput.Capture) {
    $capture = $stepOutput.Capture
    if ([string]::IsNullOrWhiteSpace($diffEvidenceSource) -and $capture.PSObject.Properties['diffEvidenceSource']) {
      $diffEvidenceSource = [string]$capture.diffEvidenceSource
    }
    if ($diffImageCount -le 0 -and $capture.PSObject.Properties['reportAnalysis'] -and $capture.reportAnalysis -and $capture.reportAnalysis.PSObject.Properties['diffImageCount']) {
      $diffImageCount = [int]$capture.reportAnalysis.diffImageCount
    }
    if ([string]::IsNullOrWhiteSpace($extractedReportPath) -and $capture.PSObject.Properties['reportAnalysis'] -and $capture.reportAnalysis -and $capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) {
      $extractedReportPath = [string]$capture.reportAnalysis.reportPathExtracted
    }
    if ([string]::IsNullOrWhiteSpace($containerExportStatus) -and $capture.PSObject.Properties['containerArtifacts'] -and $capture.containerArtifacts -and $capture.containerArtifacts.PSObject.Properties['copyStatus']) {
      $containerExportStatus = [string]$capture.containerArtifacts.copyStatus
    }
  }

  return [pscustomobject]@{
    name = $Name
    status = $stepStatus
    message = $stepMessage
    startedAt = $stepStartUtc.ToString('o')
    finishedAt = $stepEndUtc.ToString('o')
    durationMs = [int]$durationMs
    exitCode = [int]$stepExitCode
    resultClass = $resultClass
    gateOutcome = $gateOutcome
    failureClass = $failureClass
    isDiff = [bool]$isDiff
    diffEvidenceSource = $diffEvidenceSource
    diffImageCount = [int]$diffImageCount
    extractedReportPath = $extractedReportPath
    containerExportStatus = $containerExportStatus
    hardStopEligible = [bool]$hardStopEligible
    hardStopTriggered = [bool]$hardStopTriggered
    allowedExitCodes = @($AllowedExitCodes)
    capturePath = $capturePath
  }
}

$root = Resolve-AbsolutePath -Path $ResultsRoot
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
}

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
$summaryPath = Join-Path $root ("docker-runtime-fastloop-{0}.json" -f $timestamp)
$statusResolved = if ([string]::IsNullOrWhiteSpace($StatusPath)) {
  Join-Path $root 'docker-runtime-fastloop-status.json'
} else {
  Resolve-AbsolutePath -Path $StatusPath
}
$readinessJsonResolved = if ([string]::IsNullOrWhiteSpace($ReadinessJsonPath)) {
  Join-Path $root 'docker-runtime-fastloop-readiness.json'
} else {
  Resolve-AbsolutePath -Path $ReadinessJsonPath
}
$readinessMarkdownResolved = if ([string]::IsNullOrWhiteSpace($ReadinessMarkdownPath)) {
  Join-Path $root 'docker-runtime-fastloop-readiness.md'
} else {
  Resolve-AbsolutePath -Path $ReadinessMarkdownPath
}
$windowsSnapshot = Join-Path $root 'windows-runtime-determinism.json'
$linuxSnapshot = Join-Path $root 'linux-runtime-determinism.json'
$linuxSmokeRoot = Join-Path $root 'linux-smoke'
$historyScenariosRoot = Join-Path $root 'history-scenarios'
$repoRoot = Get-RepoRootFromToolsScript
$historyScenarioSetNormalized = if ([string]::IsNullOrWhiteSpace($HistoryScenarioSet)) { 'none' } else { $HistoryScenarioSet.Trim().ToLowerInvariant() }
$laneScopeNormalized = if ([string]::IsNullOrWhiteSpace($LaneScope)) { 'both' } else { $LaneScope.Trim().ToLowerInvariant() }
$singleLaneMode = $laneScopeNormalized -ne 'both'
if ($singleLaneMode -and $ManageDockerEngine) {
  throw ("LaneScope '{0}' does not allow -ManageDockerEngine`:$true. Use LaneScope 'both' for managed engine switching." -f $laneScopeNormalized)
}
$effectiveManageDockerEngine = if ($singleLaneMode) { $false } else { [bool]$ManageDockerEngine }
$runtimeAutoRepairEnabled = -not $singleLaneMode
$effectiveLabVIEWPath = $LabVIEWPath
if ([string]::IsNullOrWhiteSpace($effectiveLabVIEWPath)) {
  foreach ($candidateLabVIEWPath in @($env:COMPARE_LABVIEW_PATH, $env:LOOP_LABVIEW_PATH, $env:LABVIEW_PATH, $env:LV_LABVIEW_PATH, $env:LABVIEW_EXE)) {
    if (-not [string]::IsNullOrWhiteSpace($candidateLabVIEWPath)) {
      $effectiveLabVIEWPath = $candidateLabVIEWPath
      break
    }
  }
}
$effectiveSkipWindowsProbe = [bool]$SkipWindowsProbe
$effectiveSkipLinuxProbe = [bool]$SkipLinuxProbe
switch ($laneScopeNormalized) {
  'windows' { $effectiveSkipLinuxProbe = $true }
  'linux' { $effectiveSkipWindowsProbe = $true }
  default { }
}
$historyScenarioCount = 0
$historyScenarioFilterDiagnostics = New-Object System.Collections.Generic.List[string]

$results = New-Object System.Collections.Generic.List[object]
$runStartedAt = (Get-Date).ToUniversalTime().ToString('o')
$stepDefinitions = New-Object System.Collections.Generic.List[object]
$hardStopTriggered = $false
$hardStopReason = ''

if (-not $effectiveSkipWindowsProbe) {
  $stepDefinitions.Add([pscustomobject]@{
    name = 'windows-runtime-preflight'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    captureValidator = {
      param($stepOutput, $stepExitCode)
      $runtimeStatus = ''
      $runtimeReason = ''
      if (Test-Path -LiteralPath $windowsSnapshot -PathType Leaf) {
        try {
          $snapshot = Get-Content -LiteralPath $windowsSnapshot -Raw | ConvertFrom-Json -Depth 8
          if ($snapshot -and $snapshot.PSObject.Properties['result']) {
            if ($snapshot.result.PSObject.Properties['status']) { $runtimeStatus = [string]$snapshot.result.status }
            if ($snapshot.result.PSObject.Properties['reason']) { $runtimeReason = [string]$snapshot.result.reason }
          }
        } catch {}
      }
      $captureStatus = if ([int]$stepExitCode -eq 0) { 'ok' } else { 'preflight-error' }
      $classification = Get-CompareExitClassification `
        -ExitCode ([int]$stepExitCode) `
        -CaptureStatus $captureStatus `
        -StdOut '' `
        -StdErr '' `
        -Message $runtimeReason `
        -RuntimeDeterminismStatus $runtimeStatus `
        -RuntimeDeterminismReason $runtimeReason
      [pscustomobject]@{
        resultClass = [string]$classification.resultClass
        isDiff = [bool]$classification.isDiff
        gateOutcome = [string]$classification.gateOutcome
        failureClass = [string]$classification.failureClass
        message = $runtimeReason
      }
    }
    action = {
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1') `
      -ExpectedOsType windows `
      -ExpectedContext desktop-windows `
      -AutoRepair:$runtimeAutoRepairEnabled `
      -ManageDockerEngine:$effectiveManageDockerEngine `
      -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
      -EngineReadyPollSeconds 3 `
      -SnapshotPath $windowsSnapshot `
      -GitHubOutputPath ''
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'windows-container-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    action = {
    $windowsProbeArgs = @(
      '-NoLogo', '-NoProfile',
      '-File', (Join-Path $PSScriptRoot 'Run-NIWindowsContainerCompare.ps1'),
      '-Probe',
      '-Image', $WindowsImage,
      '-TimeoutSeconds', [string]$StepTimeoutSeconds,
      "-AutoRepairRuntime:$runtimeAutoRepairEnabled",
      "-ManageDockerEngine:$effectiveManageDockerEngine",
      '-RuntimeEngineReadyTimeoutSeconds', [string]$StepTimeoutSeconds,
      '-RuntimeEngineReadyPollSeconds', '3',
      '-RuntimeSnapshotPath', $windowsSnapshot
    )
    if (-not [string]::IsNullOrWhiteSpace($effectiveLabVIEWPath)) {
      $windowsProbeArgs += @('-LabVIEWPath', $effectiveLabVIEWPath)
    }
    pwsh @windowsProbeArgs | Out-Null
    }
  }) | Out-Null
}

if (-not $effectiveSkipLinuxProbe) {
  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-runtime-preflight'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    captureValidator = {
      param($stepOutput, $stepExitCode)
      $runtimeStatus = ''
      $runtimeReason = ''
      if (Test-Path -LiteralPath $linuxSnapshot -PathType Leaf) {
        try {
          $snapshot = Get-Content -LiteralPath $linuxSnapshot -Raw | ConvertFrom-Json -Depth 8
          if ($snapshot -and $snapshot.PSObject.Properties['result']) {
            if ($snapshot.result.PSObject.Properties['status']) { $runtimeStatus = [string]$snapshot.result.status }
            if ($snapshot.result.PSObject.Properties['reason']) { $runtimeReason = [string]$snapshot.result.reason }
          }
        } catch {}
      }
      $captureStatus = if ([int]$stepExitCode -eq 0) { 'ok' } else { 'preflight-error' }
      $classification = Get-CompareExitClassification `
        -ExitCode ([int]$stepExitCode) `
        -CaptureStatus $captureStatus `
        -StdOut '' `
        -StdErr '' `
        -Message $runtimeReason `
        -RuntimeDeterminismStatus $runtimeStatus `
        -RuntimeDeterminismReason $runtimeReason
      [pscustomobject]@{
        resultClass = [string]$classification.resultClass
        isDiff = [bool]$classification.isDiff
        gateOutcome = [string]$classification.gateOutcome
        failureClass = [string]$classification.failureClass
        message = $runtimeReason
      }
    }
    action = {
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Assert-DockerRuntimeDeterminism.ps1') `
      -ExpectedOsType linux `
      -ExpectedContext desktop-linux `
      -AutoRepair:$runtimeAutoRepairEnabled `
      -ManageDockerEngine:$effectiveManageDockerEngine `
      -EngineReadyTimeoutSeconds $StepTimeoutSeconds `
      -EngineReadyPollSeconds 3 `
      -SnapshotPath $linuxSnapshot `
      -GitHubOutputPath ''
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-container-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $true
    action = {
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Run-NILinuxContainerCompare.ps1') `
      -Probe `
      -Image $LinuxImage `
      -TimeoutSeconds $StepTimeoutSeconds `
      -AutoRepairRuntime:$runtimeAutoRepairEnabled `
      -RuntimeEngineReadyTimeoutSeconds $StepTimeoutSeconds `
      -RuntimeEngineReadyPollSeconds 3 `
      -RuntimeSnapshotPath $linuxSnapshot | Out-Null
    }
  }) | Out-Null

  $stepDefinitions.Add([pscustomobject]@{
    name = 'linux-renderer-smoke-probe'
    allowedExitCodes = @(0)
    hardStopOnRuntimeFailure = $false
    action = {
    if (-not (Test-Path -LiteralPath $linuxSmokeRoot -PathType Container)) {
      New-Item -ItemType Directory -Path $linuxSmokeRoot -Force | Out-Null
    }
    $tmpOut = Join-Path $linuxSmokeRoot 'gh-output.txt'
    $tmpSummary = Join-Path $linuxSmokeRoot 'step-summary.md'
    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'New-VIHistorySmokeFixture.ps1') `
      -OutputRoot $linuxSmokeRoot `
      -GitHubOutputPath $tmpOut | Out-Null

    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $tmpOut) {
      if ([string]::IsNullOrWhiteSpace($line) -or $line -notmatch '=') { continue }
      $parts = $line -split '=', 2
      $outputs[$parts[0]] = $parts[1]
    }
    $manifestPath = $outputs['suite-manifest-path']
    $contextPath = $outputs['history-context-path']
    $resultsDir = $outputs['results-dir']
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or [string]::IsNullOrWhiteSpace($contextPath) -or [string]::IsNullOrWhiteSpace($resultsDir)) {
      throw 'Fixture generator did not provide expected output paths.'
    }

    pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Render-VIHistoryReport.ps1') `
      -ManifestPath $manifestPath `
      -HistoryContextPath $contextPath `
      -OutputDir $resultsDir `
      -EmitHtml `
      -GitHubOutputPath $tmpOut `
      -StepSummaryPath $tmpSummary | Out-Null
    }
  }) | Out-Null
}

if ($historyScenarioSetNormalized -ne 'none') {
  $harnessPathResolved = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue $HistoryHarnessPath -Description 'History harness manifest'
  $harness = Get-Content -LiteralPath $harnessPathResolved -Raw | ConvertFrom-Json -Depth 8
  if (-not $harness -or [string]$harness.schema -ne 'vi-history-pr-harness@v1') {
    throw ("Unsupported history harness schema in {0}" -f $harnessPathResolved)
  }
  $scenarioSelection = Get-HistoryScenarioIdsForSet -ScenarioSet $historyScenarioSetNormalized -Harness $harness
  $scenarioIds = @($scenarioSelection.scenarioIds)
  foreach ($diagnostic in @($scenarioSelection.diagnostics)) {
    if ([string]::IsNullOrWhiteSpace([string]$diagnostic)) { continue }
    $historyScenarioFilterDiagnostics.Add([string]$diagnostic) | Out-Null
    Write-Host ("[docker-fast-loop][history-filter] {0}" -f [string]$diagnostic) -ForegroundColor DarkYellow
  }
  if ($scenarioIds.Count -gt 0 -and -not (Test-Path -LiteralPath $historyScenariosRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $historyScenariosRoot -Force | Out-Null
  }

  $baselineBase = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue 'fixtures/vi-attr/Base.vi' -Description 'History baseline base VI'
  $scenarioMap = @{}
  foreach ($scenario in @($harness.scenarios)) {
    if (-not $scenario -or -not $scenario.PSObject.Properties['id']) { continue }
    $scenarioMap[[string]$scenario.id] = $scenario
  }

  foreach ($scenarioId in $scenarioIds) {
    if (-not $scenarioMap.ContainsKey($scenarioId)) {
      throw ("History scenario '{0}' was not found in harness manifest {1}" -f $scenarioId, $harnessPathResolved)
    }
    $scenario = $scenarioMap[$scenarioId]
    $scenarioMode = if ($scenario.PSObject.Properties['mode']) { [string]$scenario.mode } else { 'attribute' }

    if ([string]::Equals($scenarioMode, 'sequential', [System.StringComparison]::OrdinalIgnoreCase)) {
      $sequentialPathResolved = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue $SequentialFixturePath -Description 'Sequential history fixture'
      $sequential = Get-Content -LiteralPath $sequentialPathResolved -Raw | ConvertFrom-Json -Depth 8
      if (-not $sequential -or [string]$sequential.schema -ne 'vi-history-sequence@v1') {
        throw ("Unsupported sequential fixture schema in {0}" -f $sequentialPathResolved)
      }
      if (-not $sequential.steps -or @($sequential.steps).Count -eq 0) {
        throw ("Sequential fixture contains no steps: {0}" -f $sequentialPathResolved)
      }
      $previousHead = $baselineBase
      $stepIndex = 0
      $addedSequentialSteps = 0
      foreach ($sequenceStep in @($sequential.steps)) {
        $stepIndex++
        $seqIdRaw = if ($sequenceStep.PSObject.Properties['id']) { [string]$sequenceStep.id } else { ("step-{0:000}" -f $stepIndex) }
        $requireStepDiff = $false
        if ($sequenceStep.PSObject.Properties['requireDiff']) {
          $requireStepDiff = [bool]$sequenceStep.requireDiff
        }
        if (-not $requireStepDiff) {
          $skipMessage = ("Sequential step '{0}' skipped because requireDiff=true is required for diff-only history execution." -f $seqIdRaw)
          $historyScenarioFilterDiagnostics.Add($skipMessage) | Out-Null
          Write-Host ("[docker-fast-loop][history-filter] {0}" -f $skipMessage) -ForegroundColor DarkYellow
          continue
        }
        $safeSeqId = $seqIdRaw -replace '[^a-zA-Z0-9._-]', '-'
        $headPath = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue ([string]$sequenceStep.source) -Description ("Sequential step source '{0}'" -f $seqIdRaw)
        $reportPath = Join-Path $historyScenariosRoot (Join-Path 'sequential' (Join-Path $safeSeqId 'windows-compare-report.html'))
        $stepName = "windows-history-sequential-$safeSeqId"
        $baseForStep = $previousHead
        $headForStep = $headPath

        $stepDefinitions.Add([pscustomobject]@{
          name = $stepName
          allowedExitCodes = @(0, 1)
          hardStopOnRuntimeFailure = $true
          captureValidator = {
            param($stepOutput, $stepExitCode)
            if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
              throw ("Missing compare classification for step output (exit={0})." -f $stepExitCode)
            }
            $classification = $stepOutput.Classification
            $validatorMessage = ''
            if ($stepOutput.PSObject.Properties['Message']) {
              $validatorMessage = [string]$stepOutput.Message
            }
            [pscustomobject]@{
              resultClass = [string]$classification.resultClass
              isDiff = [bool]$classification.isDiff
              gateOutcome = [string]$classification.gateOutcome
              failureClass = [string]$classification.failureClass
              message = $validatorMessage
              diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
              diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
              extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
              containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
            }
          }
          action = {
            Invoke-WindowsHistoryCompare `
              -BaseVi $baseForStep `
              -HeadVi $headForStep `
              -ReportPath $reportPath `
              -LabVIEWPath $effectiveLabVIEWPath `
              -WindowsImage $WindowsImage `
              -RuntimeSnapshotPath $windowsSnapshot `
              -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
              -ManageDockerEngine:$effectiveManageDockerEngine `
              -StepTimeoutSeconds $StepTimeoutSeconds
          }
        }) | Out-Null

        $historyScenarioCount++
        $addedSequentialSteps++
        $previousHead = $headPath
      }
      if ($addedSequentialSteps -eq 0) {
        throw ("History sequential scenario '{0}' resolved to empty after requireDiff=true filtering in {1}." -f $scenarioId, $sequentialPathResolved)
      }
      continue
    }

    if (-not $scenario.PSObject.Properties['source'] -or [string]::IsNullOrWhiteSpace([string]$scenario.source)) {
      throw ("History scenario '{0}' requires a source path." -f $scenarioId)
    }
    $safeScenarioId = $scenarioId -replace '[^a-zA-Z0-9._-]', '-'
    $headPath = Resolve-RepoRelativePath -RepoRoot $repoRoot -PathValue ([string]$scenario.source) -Description ("Scenario source '{0}'" -f $scenarioId)
    $reportPath = Join-Path $historyScenariosRoot (Join-Path $safeScenarioId 'windows-compare-report.html')
    $stepName = "windows-history-$safeScenarioId"

    $stepDefinitions.Add([pscustomobject]@{
      name = $stepName
      allowedExitCodes = @(0, 1)
      hardStopOnRuntimeFailure = $true
      captureValidator = {
        param($stepOutput, $stepExitCode)
        if (-not $stepOutput -or -not $stepOutput.PSObject.Properties['Classification']) {
          throw ("Missing compare classification for step output (exit={0})." -f $stepExitCode)
        }
        $classification = $stepOutput.Classification
        $validatorMessage = ''
        if ($stepOutput.PSObject.Properties['Message']) {
          $validatorMessage = [string]$stepOutput.Message
        }
        [pscustomobject]@{
          resultClass = [string]$classification.resultClass
          isDiff = [bool]$classification.isDiff
          gateOutcome = [string]$classification.gateOutcome
          failureClass = [string]$classification.failureClass
          message = $validatorMessage
          diffEvidenceSource = if ($stepOutput.Capture.PSObject.Properties['diffEvidenceSource']) { [string]$stepOutput.Capture.diffEvidenceSource } else { '' }
          diffImageCount = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['diffImageCount']) { [int]$stepOutput.Capture.reportAnalysis.diffImageCount } else { 0 }
          extractedReportPath = if ($stepOutput.Capture.PSObject.Properties['reportAnalysis'] -and $stepOutput.Capture.reportAnalysis -and $stepOutput.Capture.reportAnalysis.PSObject.Properties['reportPathExtracted']) { [string]$stepOutput.Capture.reportAnalysis.reportPathExtracted } else { '' }
          containerExportStatus = if ($stepOutput.Capture.PSObject.Properties['containerArtifacts'] -and $stepOutput.Capture.containerArtifacts -and $stepOutput.Capture.containerArtifacts.PSObject.Properties['copyStatus']) { [string]$stepOutput.Capture.containerArtifacts.copyStatus } else { '' }
        }
      }
      action = {
        Invoke-WindowsHistoryCompare `
          -BaseVi $baselineBase `
          -HeadVi $headPath `
          -ReportPath $reportPath `
          -LabVIEWPath $effectiveLabVIEWPath `
          -WindowsImage $WindowsImage `
          -RuntimeSnapshotPath $windowsSnapshot `
          -RuntimeAutoRepair:$runtimeAutoRepairEnabled `
          -ManageDockerEngine:$effectiveManageDockerEngine `
          -StepTimeoutSeconds $StepTimeoutSeconds
      }
    }) | Out-Null
    $historyScenarioCount++
  }
}

function Get-StepLaneOrderRank {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$LanePreference
  )

  $linuxRank = 0
  $windowsRank = 1
  if ($LanePreference -eq 'windows-first') {
    $linuxRank = 1
    $windowsRank = 0
  }

  if ($Name -like 'linux-*') { return $linuxRank }
  if ($Name -like 'windows-*') { return $windowsRank }
  return 2
}

if ($stepDefinitions.Count -gt 1) {
  $indexed = for ($i = 0; $i -lt $stepDefinitions.Count; $i++) {
    [pscustomobject]@{
      index = $i
      def = $stepDefinitions[$i]
      rank = Get-StepLaneOrderRank -Name ([string]$stepDefinitions[$i].name) -LanePreference $LaneOrder
    }
  }
  $orderedDefs = @($indexed | Sort-Object -Property rank, index | ForEach-Object { $_.def })
  $stepDefinitions.Clear()
  foreach ($def in $orderedDefs) {
    $stepDefinitions.Add($def) | Out-Null
  }
}

$totalSteps = $stepDefinitions.Count
$stepPlan = @($stepDefinitions.ToArray() | ForEach-Object { [string]$_.name })
$historicalStepMedians = Get-HistoricalStepDurationMedians -ResultsDir $root
Write-SemiLiveStatus `
  -Path $statusResolved `
  -StartedAt $runStartedAt `
  -RunStatus 'running' `
  -Phase 'running' `
  -CurrentStep '' `
  -CompletedSteps 0 `
  -TotalSteps $totalSteps `
  -StepPlan $stepPlan `
  -Steps @() `
  -HistoricalStepMedians $historicalStepMedians `
  -HardStopTriggered:$hardStopTriggered `
  -HardStopReason $hardStopReason `
  -SummaryPath ''

foreach ($definition in $stepDefinitions.ToArray()) {
  $stepName = [string]$definition.name
  Write-Host ("[docker-fast-loop] start: {0}" -f $stepName)
  Write-SemiLiveStatus `
    -Path $statusResolved `
    -StartedAt $runStartedAt `
    -RunStatus 'running' `
    -Phase 'running' `
    -CurrentStep $stepName `
    -CompletedSteps $results.Count `
    -TotalSteps $totalSteps `
    -StepPlan $stepPlan `
    -Steps $results.ToArray() `
    -HistoricalStepMedians $historicalStepMedians `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason `
    -SummaryPath ''

  $allowedExitCodes = @(0)
  if ($definition.PSObject.Properties['allowedExitCodes'] -and $definition.allowedExitCodes) {
    $allowedExitCodes = @($definition.allowedExitCodes | ForEach-Object { [int]$_ })
  }
  $hardStopOnRuntimeFailure = $false
  if ($definition.PSObject.Properties['hardStopOnRuntimeFailure']) {
    $hardStopOnRuntimeFailure = [bool]$definition.hardStopOnRuntimeFailure
  }
  $captureValidator = $null
  if ($definition.PSObject.Properties['captureValidator'] -and $definition.captureValidator) {
    $captureValidator = [scriptblock]$definition.captureValidator
  }
  $stepResult = Invoke-Step `
    -Name $stepName `
    -Action $definition.action `
    -AllowedExitCodes $allowedExitCodes `
    -HardStopOnRuntimeFailure:$hardStopOnRuntimeFailure `
    -CaptureValidator $captureValidator `
    -TimeoutSeconds $StepTimeoutSeconds
  $results.Add($stepResult) | Out-Null
  $durationText = if ($stepResult.PSObject.Properties['durationMs']) { [string]$stepResult.durationMs } else { '0' }
  $stepStatusText = [string]$stepResult.status
  $diffEvidenceText = ''
  if ($stepResult.PSObject.Properties['diffEvidenceSource'] -and -not [string]::IsNullOrWhiteSpace([string]$stepResult.diffEvidenceSource)) {
    $diffEvidenceText = (" evidence={0}" -f [string]$stepResult.diffEvidenceSource)
    if ($stepResult.PSObject.Properties['diffImageCount']) {
      $diffEvidenceText = ("{0} images={1}" -f $diffEvidenceText, [int]$stepResult.diffImageCount)
    }
  }
  if ($stepStatusText -eq 'success') {
    Write-Host ("[docker-fast-loop] done: {0} ({1} ms) class={2} diff={3} exit={4}{5}" -f $stepName, $durationText, [string]$stepResult.resultClass, [bool]$stepResult.isDiff, [int]$stepResult.exitCode, $diffEvidenceText) -ForegroundColor Green
  } else {
    $failureMessage = [string]$stepResult.message
    Write-Host ("[docker-fast-loop] failed: {0} ({1} ms) class={2} failureClass={3} exit={4}: {5}" -f $stepName, $durationText, [string]$stepResult.resultClass, [string]$stepResult.failureClass, [int]$stepResult.exitCode, $failureMessage) -ForegroundColor Red
    if ($stepResult.PSObject.Properties['hardStopTriggered'] -and [bool]$stepResult.hardStopTriggered) {
      $hardStopTriggered = $true
      $failureClassText = [string]$stepResult.failureClass
      $reasonPrefix = switch ($failureClassText) {
        'runtime-determinism' { 'Runtime determinism check failed' }
        'startup-connectivity' { 'Startup/connectivity failure detected' }
        'timeout' { 'Timeout failure detected' }
        'preflight' { 'Preflight failure detected' }
        default { 'Tool failure detected' }
      }
      $hardStopReason = ("{0} at step '{1}' (failureClass={2}, exit={3}): {4}" -f $reasonPrefix, $stepName, $failureClassText, [int]$stepResult.exitCode, $failureMessage)
      Write-Host ("[docker-fast-loop] hard-stop: {0}" -f $hardStopReason) -ForegroundColor Red
    }
  }
  Write-SemiLiveStatus `
    -Path $statusResolved `
    -StartedAt $runStartedAt `
    -RunStatus 'running' `
    -Phase 'running' `
    -CurrentStep '' `
    -CompletedSteps $results.Count `
    -TotalSteps $totalSteps `
    -StepPlan $stepPlan `
    -Steps $results.ToArray() `
    -HistoricalStepMedians $historicalStepMedians `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason `
    -SummaryPath ''

  if ($hardStopTriggered) {
    break
  }
}

$failed = New-Object System.Collections.Generic.List[object]
foreach ($entry in $results.ToArray()) {
  $statusValue = $null
  if ($entry -is [System.Collections.IDictionary]) {
    $statusValue = [string]$entry['status']
  } elseif ($entry -and $entry.PSObject -and $entry.PSObject.Properties['status']) {
    $statusValue = [string]$entry.status
  }
  if ([string]::IsNullOrWhiteSpace($statusValue) -or $statusValue -ne 'success') {
    $failed.Add($entry) | Out-Null
  }
}
$diffStepCount = 0
$runtimeFailureCount = 0
$toolFailureCount = 0
$timeoutFailureCount = 0
$preflightFailureCount = 0
$diffEvidenceSteps = 0
$extractedReportCount = 0
$containerExportFailureCount = 0
$diffLaneSet = New-Object System.Collections.Generic.HashSet[string]
foreach ($entry in $results.ToArray()) {
  $entryIsDiff = $false
  if ($entry.PSObject.Properties['isDiff']) {
    $entryIsDiff = [bool]$entry.isDiff
  }
  if ($entryIsDiff) {
    $diffStepCount++
    $laneName = if ($entry.PSObject.Properties['name']) { Get-StepLane -StepName ([string]$entry.name) } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($laneName)) {
      $diffLaneSet.Add($laneName) | Out-Null
    }
  }
  $failureClassValue = if ($entry.PSObject.Properties['failureClass']) { [string]$entry.failureClass } else { '' }
  switch ($failureClassValue) {
    'runtime-determinism' { $runtimeFailureCount++ }
    'startup-connectivity' { $toolFailureCount++ }
    'cli/tool' { $toolFailureCount++ }
    'timeout' { $timeoutFailureCount++ }
    'preflight' { $preflightFailureCount++ }
  }
  $diffEvidenceSourceValue = if ($entry.PSObject.Properties['diffEvidenceSource']) { [string]$entry.diffEvidenceSource } else { '' }
  if ([string]::Equals($diffEvidenceSourceValue, 'html', [System.StringComparison]::OrdinalIgnoreCase)) {
    $diffEvidenceSteps++
  }
  $extractedPathValue = if ($entry.PSObject.Properties['extractedReportPath']) { [string]$entry.extractedReportPath } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($extractedPathValue)) {
    $extractedReportCount++
  }
  $exportStatusValue = if ($entry.PSObject.Properties['containerExportStatus']) { [string]$entry.containerExportStatus } else { '' }
  if ($exportStatusValue -in @('failed', 'partial')) {
    $containerExportFailureCount++
  }
}

$summary = [ordered]@{
  schema = 'docker-desktop-fast-loop@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  windowsImage = $WindowsImage
  linuxImage = $LinuxImage
  resultsRoot = $root
  snapshots = [ordered]@{
    windows = $windowsSnapshot
    linux = $linuxSnapshot
  }
  statusPath = $statusResolved
  readinessJsonPath = $readinessJsonResolved
  readinessMarkdownPath = $readinessMarkdownResolved
  historyScenarioSet = $historyScenarioSetNormalized
  laneScope = $laneScopeNormalized
  historyScenarioCount = [int]$historyScenarioCount
  diffStepCount = [int]$diffStepCount
  diffEvidenceSteps = [int]$diffEvidenceSteps
  diffLaneCount = [int]$diffLaneSet.Count
  extractedReportCount = [int]$extractedReportCount
  containerExportFailureCount = [int]$containerExportFailureCount
  runtimeFailureCount = [int]$runtimeFailureCount
  toolFailureCount = [int]$toolFailureCount
  timeoutFailureCount = [int]$timeoutFailureCount
  preflightFailureCount = [int]$preflightFailureCount
  hardStopTriggered = [bool]$hardStopTriggered
  hardStopReason = $hardStopReason
  skipWindowsProbe = [bool]$effectiveSkipWindowsProbe
  skipLinuxProbe = [bool]$effectiveSkipLinuxProbe
  historyScenarioFilterDiagnostics = @($historyScenarioFilterDiagnostics.ToArray())
  singleLaneMode = [bool]$singleLaneMode
  runtimeAutoRepair = [bool]$runtimeAutoRepairEnabled
  stepTimeoutSeconds = [int]$StepTimeoutSeconds
  manageDockerEngine = [bool]$effectiveManageDockerEngine
  laneOrder = $LaneOrder
  runtimeManager = (Get-RuntimeManagerTelemetry -WindowsSnapshotPath $windowsSnapshot -LinuxSnapshotPath $linuxSnapshot)
  laneLifecycle = (Get-LaneLifecycleFromPlan `
    -StepPlan $stepPlan `
    -ObservedSteps $results.ToArray() `
    -Phase 'completed' `
    -HardStopTriggered:$hardStopTriggered `
    -HardStopReason $hardStopReason)
  steps = $results.ToArray()
  status = if ($failed.Count -eq 0) { 'success' } else { 'failure' }
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
Write-Host ("[docker-fast-loop] summary: {0}" -f $summaryPath)

Write-SemiLiveStatus `
  -Path $statusResolved `
  -StartedAt $runStartedAt `
  -RunStatus ([string]$summary.status) `
  -Phase 'completed' `
  -CurrentStep '' `
  -CompletedSteps $results.Count `
  -TotalSteps $totalSteps `
  -StepPlan $stepPlan `
  -Steps $results.ToArray() `
  -HistoricalStepMedians $historicalStepMedians `
  -HardStopTriggered:$hardStopTriggered `
  -HardStopReason $hardStopReason `
  -SummaryPath $summaryPath `
  -RuntimeManagerTelemetry $summary.runtimeManager

pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Write-DockerFastLoopReadiness.ps1') `
  -ResultsRoot $root `
  -SummaryPath $summaryPath `
  -StatusPath $statusResolved `
  -OutputJsonPath $readinessJsonResolved `
  -OutputMarkdownPath $readinessMarkdownResolved `
  -GitHubOutputPath '' `
  -StepSummaryPath '' | Out-Null

if ($failed.Count -gt 0) {
  foreach ($step in $failed.ToArray()) {
    $nameValue = if ($step -is [System.Collections.IDictionary]) { [string]$step['name'] } elseif ($step -and $step.PSObject.Properties['name']) { [string]$step.name } else { '<unknown-step>' }
    $messageValue = if ($step -is [System.Collections.IDictionary]) { [string]$step['message'] } elseif ($step -and $step.PSObject.Properties['message']) { [string]$step.message } else { 'no details' }
    Write-Host ("[docker-fast-loop] failed: {0}: {1}" -f $nameValue, $messageValue) -ForegroundColor Red
  }
  if ($hardStopTriggered -and -not [string]::IsNullOrWhiteSpace($hardStopReason)) {
    throw ("Docker fast loop hard-stopped: {0}" -f $hardStopReason)
  }
  throw ("Docker fast loop failed with {0} step(s)." -f $failed.Count)
}

Write-Output $summaryPath
