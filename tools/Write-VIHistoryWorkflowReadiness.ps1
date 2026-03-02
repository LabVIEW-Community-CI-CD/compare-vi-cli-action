#Requires -Version 7.0
<#
.SYNOPSIS
  Writes workflow-lane readiness envelope for PR VI history runs.

.DESCRIPTION
  Creates additive machine-readable and markdown readiness artifacts from lane
  statuses (windows + linux smoke) and known summary artifact paths. Designed
  for use in reusable and direct PR VI history workflows.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$WindowsLaneStatus,
  [Parameter(Mandatory = $true)][string]$LinuxLaneStatus,
  [string]$WindowsDiffDetected = '',
  [string]$LinuxDiffDetected = '',
  [string]$WindowsFailureClass = '',
  [string]$LinuxFailureClass = '',
  [string]$WindowsLaneStopClass = '',
  [string]$LinuxLaneStopClass = '',
  [string]$WindowsLaneStopReason = '',
  [string]$LinuxLaneStopReason = '',
  [string]$WindowsLaneStartStep = '',
  [string]$LinuxLaneStartStep = '',
  [string]$WindowsLaneEndStep = '',
  [string]$LinuxLaneEndStep = '',
  [string]$WindowsLaneStartedAt = '',
  [string]$LinuxLaneStartedAt = '',
  [string]$WindowsLaneEndedAt = '',
  [string]$LinuxLaneEndedAt = '',
  [string]$WindowsLaneHardStopTriggered = '',
  [string]$LinuxLaneHardStopTriggered = '',
  [string]$FastLoopReadinessPath = '',
  [string]$FastLoopProofPath = '',
  [string]$ResultsRoot = 'tests/results/pr-vi-history',
  [string]$SummaryPath = '',
  [string]$LinuxSmokeSummaryPath = '',
  [string]$WindowsRuntimeSnapshotPath = '',
  [string]$LinuxRuntimeSnapshotPath = '',
  [string]$OutputJsonPath = '',
  [string]$OutputMarkdownPath = '',
  [string]$RunUrl = '',
  [string]$PrNumber = '',
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

function Normalize-Status {
  param([AllowNull()][AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return 'unknown' }
  $normalized = $Value.Trim().ToLowerInvariant()
  switch -Regex ($normalized) {
    '^(success|ok|passed)$' { return 'success' }
    '^(failure|failed|error)$' { return 'failure' }
    '^(skipped|skip)$' { return 'skipped' }
    default { return $normalized }
  }
}

function Normalize-StopClass {
  param([AllowNull()][AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  $normalized = $Value.Trim().ToLowerInvariant()
  switch -Regex ($normalized) {
    '^(completed|complete)$' { return 'completed' }
    '^(hard-stop|hardstop|hard_stop)$' { return 'hard-stop' }
    '^(blocked|block)$' { return 'blocked' }
    '^(failure|failed|error)$' { return 'failure' }
    default { return $normalized }
  }
}

function Read-JsonOrNull {
  param([AllowNull()][AllowEmptyString()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20)
  } catch {
    return $null
  }
}

function Convert-ToBool {
  param(
    [AllowNull()][AllowEmptyString()][string]$Value,
    [bool]$Default = $false
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
  switch -Regex ($Value.Trim().ToLowerInvariant()) {
    '^(true|1|yes|y|on)$' { return $true }
    '^(false|0|no|n|off)$' { return $false }
    default { return $Default }
  }
}

function Escape-MarkdownCell {
  param([AllowNull()][AllowEmptyString()][string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return ($Value -replace '\|', '\|')
}

function Resolve-DefaultStopClass {
  param(
    [Parameter(Mandatory)][string]$LaneStatus,
    [Parameter(Mandatory)][string]$FailureClass
  )
  switch ($LaneStatus) {
    'success' { return 'completed' }
    'failure' {
      if ($FailureClass -eq 'runtime-determinism') {
        return 'hard-stop'
      }
      return 'failure'
    }
    'skipped' { return 'none' }
    default { return 'blocked' }
  }
}

function Resolve-DefaultStopReason {
  param(
    [Parameter(Mandatory)][string]$LaneStatus,
    [Parameter(Mandatory)][string]$FailureClass
  )
  switch ($LaneStatus) {
    'success' { return 'lane-complete' }
    'failure' {
      if ($FailureClass -eq 'runtime-determinism') {
        return 'runtime-determinism-hard-stop'
      }
      if ([string]::IsNullOrWhiteSpace($FailureClass) -or $FailureClass -eq 'none') {
        return 'lane-failed'
      }
      return ("lane-failed ({0})" -f $FailureClass)
    }
    'skipped' { return '' }
    default { return 'lane-not-started' }
  }
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$DestPath
  )
  if ([string]::IsNullOrWhiteSpace($DestPath)) { return }
  Ensure-ParentDirectory -Path $DestPath
  if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
    New-Item -ItemType File -Path $DestPath -Force | Out-Null
  }
  Add-Content -LiteralPath $DestPath -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Resolve-LaneLifecycleEntry {
  param(
    [Parameter(Mandatory)][string]$LaneName,
    [Parameter(Mandatory)][string]$LaneStatus,
    [Parameter(Mandatory)][string]$FailureClass,
    [AllowNull()]$ArtifactEntry,
    [AllowNull()][AllowEmptyString()][string]$ExplicitStopClass,
    [AllowNull()][AllowEmptyString()][string]$ExplicitStopReason,
    [AllowNull()][AllowEmptyString()][string]$ExplicitStartStep,
    [AllowNull()][AllowEmptyString()][string]$ExplicitEndStep,
    [AllowNull()][AllowEmptyString()][string]$ExplicitStartedAt,
    [AllowNull()][AllowEmptyString()][string]$ExplicitEndedAt,
    [AllowNull()][AllowEmptyString()][string]$ExplicitHardStopTriggered
  )

  $defaultStopClass = Resolve-DefaultStopClass -LaneStatus $LaneStatus -FailureClass $FailureClass
  $defaultStopReason = Resolve-DefaultStopReason -LaneStatus $LaneStatus -FailureClass $FailureClass

  $artifactStopClass = ''
  $artifactStopReason = ''
  $artifactStartStep = ''
  $artifactEndStep = ''
  $artifactStartedAt = ''
  $artifactEndedAt = ''
  $artifactTotal = 0
  $artifactExecuted = 0
  $artifactStarted = $false
  $artifactCompleted = $false
  $artifactHardStop = $false
  if ($ArtifactEntry) {
    if ($ArtifactEntry.PSObject.Properties['stopClass']) { $artifactStopClass = Normalize-StopClass -Value ([string]$ArtifactEntry.stopClass) }
    if ($ArtifactEntry.PSObject.Properties['stopReason']) { $artifactStopReason = [string]$ArtifactEntry.stopReason }
    if ($ArtifactEntry.PSObject.Properties['startStep']) { $artifactStartStep = [string]$ArtifactEntry.startStep }
    if ($ArtifactEntry.PSObject.Properties['endStep']) { $artifactEndStep = [string]$ArtifactEntry.endStep }
    if ($ArtifactEntry.PSObject.Properties['startedAt']) { $artifactStartedAt = [string]$ArtifactEntry.startedAt }
    if ($ArtifactEntry.PSObject.Properties['endedAt']) { $artifactEndedAt = [string]$ArtifactEntry.endedAt }
    if ($ArtifactEntry.PSObject.Properties['totalPlannedSteps']) { $artifactTotal = [int]$ArtifactEntry.totalPlannedSteps }
    if ($ArtifactEntry.PSObject.Properties['executedSteps']) { $artifactExecuted = [int]$ArtifactEntry.executedSteps }
    if ($ArtifactEntry.PSObject.Properties['started']) { $artifactStarted = [bool]$ArtifactEntry.started }
    if ($ArtifactEntry.PSObject.Properties['completed']) { $artifactCompleted = [bool]$ArtifactEntry.completed }
    if ($ArtifactEntry.PSObject.Properties['hardStopTriggered']) { $artifactHardStop = [bool]$ArtifactEntry.hardStopTriggered }
  }

  $stopClass = Normalize-StopClass -Value $ExplicitStopClass
  if ([string]::IsNullOrWhiteSpace($stopClass)) { $stopClass = $artifactStopClass }
  if ([string]::IsNullOrWhiteSpace($stopClass)) { $stopClass = $defaultStopClass }

  $stopReason = if (-not [string]::IsNullOrWhiteSpace($ExplicitStopReason)) { [string]$ExplicitStopReason } else { $artifactStopReason }
  if ([string]::IsNullOrWhiteSpace($stopReason)) { $stopReason = $defaultStopReason }

  $startStep = if (-not [string]::IsNullOrWhiteSpace($ExplicitStartStep)) { [string]$ExplicitStartStep } else { $artifactStartStep }
  $endStep = if (-not [string]::IsNullOrWhiteSpace($ExplicitEndStep)) { [string]$ExplicitEndStep } else { $artifactEndStep }
  $startedAt = if (-not [string]::IsNullOrWhiteSpace($ExplicitStartedAt)) { [string]$ExplicitStartedAt } else { $artifactStartedAt }
  $endedAt = if (-not [string]::IsNullOrWhiteSpace($ExplicitEndedAt)) { [string]$ExplicitEndedAt } else { $artifactEndedAt }

  $defaultStarted = ($LaneStatus -in @('success', 'failure'))
  $defaultCompleted = ($LaneStatus -in @('success', 'failure'))
  $defaultTotal = if ($LaneStatus -eq 'skipped') { 0 } else { 1 }
  $defaultExecuted = if ($defaultStarted) { $defaultTotal } else { 0 }

  $hardStopTriggered = Convert-ToBool -Value $ExplicitHardStopTriggered -Default $artifactHardStop
  if (-not $hardStopTriggered -and $stopClass -eq 'hard-stop') {
    $hardStopTriggered = $true
  }

  $totalPlannedSteps = if ($artifactTotal -gt 0 -or $LaneStatus -eq 'skipped') { $artifactTotal } else { $defaultTotal }
  if ($LaneStatus -eq 'skipped') { $totalPlannedSteps = 0 }
  $executedSteps = if ($artifactExecuted -gt 0 -or $totalPlannedSteps -eq 0) { $artifactExecuted } else { $defaultExecuted }
  if ($executedSteps -gt $totalPlannedSteps -and $totalPlannedSteps -gt 0) {
    $executedSteps = $totalPlannedSteps
  }
  $started = if ($ArtifactEntry -and $ArtifactEntry.PSObject.Properties['started']) { $artifactStarted } else { $defaultStarted }
  $completed = if ($ArtifactEntry -and $ArtifactEntry.PSObject.Properties['completed']) { $artifactCompleted } else { $defaultCompleted }
  if ($LaneStatus -eq 'skipped') {
    $started = $false
    $completed = $false
  }

  return [ordered]@{
    status = $LaneStatus
    totalPlannedSteps = [int]$totalPlannedSteps
    executedSteps = [int]$executedSteps
    started = [bool]$started
    completed = [bool]$completed
    startStep = ($startStep ?? '')
    endStep = ($endStep ?? '')
    startedAt = ($startedAt ?? '')
    endedAt = ($endedAt ?? '')
    hardStopTriggered = [bool]$hardStopTriggered
    stopClass = ($stopClass ?? 'none')
    stopReason = ($stopReason ?? '')
  }
}

$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot
if (-not (Test-Path -LiteralPath $resultsRootResolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null
}

$windows = Normalize-Status -Value $WindowsLaneStatus
$linux = Normalize-Status -Value $LinuxLaneStatus
$windowsDiff = Convert-ToBool -Value $WindowsDiffDetected -Default $false
$linuxDiff = Convert-ToBool -Value $LinuxDiffDetected -Default $false
$windowsFailure = if ([string]::IsNullOrWhiteSpace($WindowsFailureClass)) {
  if ($windows -eq 'success') { 'none' } elseif ($windows -eq 'failure') { 'cli/tool' } else { 'none' }
} else {
  $WindowsFailureClass.Trim().ToLowerInvariant()
}
$linuxFailure = if ([string]::IsNullOrWhiteSpace($LinuxFailureClass)) {
  if ($linux -eq 'success') { 'none' } elseif ($linux -eq 'failure') { 'preflight' } else { 'none' }
} else {
  $LinuxFailureClass.Trim().ToLowerInvariant()
}

$fastLoopReadinessResolved = if ([string]::IsNullOrWhiteSpace($FastLoopReadinessPath)) { '' } else { Resolve-AbsolutePath -Path $FastLoopReadinessPath }
$fastLoopProofResolved = if ([string]::IsNullOrWhiteSpace($FastLoopProofPath)) { '' } else { Resolve-AbsolutePath -Path $FastLoopProofPath }
$fastLoopReadiness = Read-JsonOrNull -Path $fastLoopReadinessResolved
$fastLoopProof = Read-JsonOrNull -Path $fastLoopProofResolved
$artifactLaneLifecycle = if ($fastLoopReadiness -and $fastLoopReadiness.PSObject.Properties['laneLifecycle']) {
  $fastLoopReadiness.laneLifecycle
} elseif ($fastLoopProof -and $fastLoopProof.PSObject.Properties['laneLifecycle']) {
  $fastLoopProof.laneLifecycle
} else {
  $null
}

$windowsArtifactLifecycle = if ($artifactLaneLifecycle -and $artifactLaneLifecycle.PSObject.Properties['windows']) { $artifactLaneLifecycle.windows } else { $null }
$linuxArtifactLifecycle = if ($artifactLaneLifecycle -and $artifactLaneLifecycle.PSObject.Properties['linux']) { $artifactLaneLifecycle.linux } else { $null }

$windowsLaneLifecycle = Resolve-LaneLifecycleEntry `
  -LaneName 'windows' `
  -LaneStatus $windows `
  -FailureClass $windowsFailure `
  -ArtifactEntry $windowsArtifactLifecycle `
  -ExplicitStopClass $WindowsLaneStopClass `
  -ExplicitStopReason $WindowsLaneStopReason `
  -ExplicitStartStep $WindowsLaneStartStep `
  -ExplicitEndStep $WindowsLaneEndStep `
  -ExplicitStartedAt $WindowsLaneStartedAt `
  -ExplicitEndedAt $WindowsLaneEndedAt `
  -ExplicitHardStopTriggered $WindowsLaneHardStopTriggered

$linuxLaneLifecycle = Resolve-LaneLifecycleEntry `
  -LaneName 'linux' `
  -LaneStatus $linux `
  -FailureClass $linuxFailure `
  -ArtifactEntry $linuxArtifactLifecycle `
  -ExplicitStopClass $LinuxLaneStopClass `
  -ExplicitStopReason $LinuxLaneStopReason `
  -ExplicitStartStep $LinuxLaneStartStep `
  -ExplicitEndStep $LinuxLaneEndStep `
  -ExplicitStartedAt $LinuxLaneStartedAt `
  -ExplicitEndedAt $LinuxLaneEndedAt `
  -ExplicitHardStopTriggered $LinuxLaneHardStopTriggered

$verdict = if ($windows -eq 'success' -and $linux -eq 'success') { 'ready' } else { 'not-ready' }
$recommendation = if ($verdict -eq 'ready') { 'proceed' } else { 'hold' }

$jsonOutResolved = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsRootResolved 'vi-history-workflow-readiness.json'
} else {
  Resolve-AbsolutePath -Path $OutputJsonPath
}
$mdOutResolved = if ([string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
  Join-Path $resultsRootResolved 'vi-history-workflow-readiness.md'
} else {
  Resolve-AbsolutePath -Path $OutputMarkdownPath
}

$envelope = [ordered]@{
  schema = 'vi-history/workflow-readiness@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  verdict = $verdict
  recommendation = $recommendation
  pullRequestNumber = $PrNumber
  runUrl = $RunUrl
  source = [ordered]@{
    fastLoopReadinessPath = if (-not [string]::IsNullOrWhiteSpace($fastLoopReadinessResolved) -and (Test-Path -LiteralPath $fastLoopReadinessResolved -PathType Leaf)) { $fastLoopReadinessResolved } else { '' }
    fastLoopProofPath = if (-not [string]::IsNullOrWhiteSpace($fastLoopProofResolved) -and (Test-Path -LiteralPath $fastLoopProofResolved -PathType Leaf)) { $fastLoopProofResolved } else { '' }
  }
  laneLifecycle = [ordered]@{
    windows = $windowsLaneLifecycle
    linux = $linuxLaneLifecycle
  }
  lanes = [ordered]@{
    windows = [ordered]@{
      status = $windows
      diffDetected = [bool]$windowsDiff
      failureClass = $windowsFailure
      stopClass = [string]$windowsLaneLifecycle.stopClass
      stopReason = [string]$windowsLaneLifecycle.stopReason
      runtimeSnapshotPath = $WindowsRuntimeSnapshotPath
      summaryPath = $SummaryPath
    }
    linux = [ordered]@{
      status = $linux
      diffDetected = [bool]$linuxDiff
      failureClass = $linuxFailure
      stopClass = [string]$linuxLaneLifecycle.stopClass
      stopReason = [string]$linuxLaneLifecycle.stopReason
      runtimeSnapshotPath = $LinuxRuntimeSnapshotPath
      smokeSummaryPath = $LinuxSmokeSummaryPath
    }
  }
}

Ensure-ParentDirectory -Path $jsonOutResolved
$envelope | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonOutResolved -Encoding utf8

$md = New-Object System.Collections.Generic.List[string]
$md.Add('### VI History Workflow Readiness') | Out-Null
$md.Add('') | Out-Null
$md.Add('| Metric | Value |') | Out-Null
$md.Add('| --- | --- |') | Out-Null
$md.Add(('| Verdict | `{0}` |' -f $verdict)) | Out-Null
$md.Add(('| Recommendation | `{0}` |' -f $recommendation)) | Out-Null
$md.Add(('| PR Number | `{0}` |' -f ($PrNumber ?? ''))) | Out-Null
$runUrlCell = if ([string]::IsNullOrWhiteSpace($RunUrl)) { '`' } else { "[link]($RunUrl)" }
$md.Add(('| Run URL | {0} |' -f $runUrlCell)) | Out-Null
$md.Add('') | Out-Null
$md.Add('| Lane | Status | Diff Detected | Failure Class | Stop Class | Start Step | End Step | Runtime Snapshot | Summary |') | Out-Null
$md.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |') | Out-Null
$md.Add(('| windows | `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | `{7}` |' -f `
    $windows, `
    $windowsDiff, `
    $windowsFailure, `
    ([string]$windowsLaneLifecycle.stopClass), `
    (Escape-MarkdownCell -Value ([string]$windowsLaneLifecycle.startStep)), `
    (Escape-MarkdownCell -Value ([string]$windowsLaneLifecycle.endStep)), `
    (Escape-MarkdownCell -Value ($WindowsRuntimeSnapshotPath ?? '')), `
    (Escape-MarkdownCell -Value ($SummaryPath ?? '')))) | Out-Null
if (-not [string]::IsNullOrWhiteSpace([string]$windowsLaneLifecycle.stopReason)) {
  $md.Add(("| | | | | stop reason | `{0}` | | | |" -f (Escape-MarkdownCell -Value ([string]$windowsLaneLifecycle.stopReason)))) | Out-Null
}
$md.Add(('| linux | `{0}` | `{1}` | `{2}` | `{3}` | `{4}` | `{5}` | `{6}` | `{7}` |' -f `
    $linux, `
    $linuxDiff, `
    $linuxFailure, `
    ([string]$linuxLaneLifecycle.stopClass), `
    (Escape-MarkdownCell -Value ([string]$linuxLaneLifecycle.startStep)), `
    (Escape-MarkdownCell -Value ([string]$linuxLaneLifecycle.endStep)), `
    (Escape-MarkdownCell -Value ($LinuxRuntimeSnapshotPath ?? '')), `
    (Escape-MarkdownCell -Value ($LinuxSmokeSummaryPath ?? '')))) | Out-Null
if (-not [string]::IsNullOrWhiteSpace([string]$linuxLaneLifecycle.stopReason)) {
  $md.Add(("| | | | | stop reason | `{0}` | | | |" -f (Escape-MarkdownCell -Value ([string]$linuxLaneLifecycle.stopReason)))) | Out-Null
}
$md.Add('') | Out-Null
$md.Add(('- Readiness JSON: `{0}`' -f $jsonOutResolved)) | Out-Null

Ensure-ParentDirectory -Path $mdOutResolved
$md | Set-Content -LiteralPath $mdOutResolved -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  Ensure-ParentDirectory -Path $StepSummaryPath
  $md | Add-Content -LiteralPath $StepSummaryPath -Encoding utf8
}

Write-GitHubOutput -Key 'workflow-readiness-json-path' -Value $jsonOutResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-markdown-path' -Value $mdOutResolved -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-verdict' -Value $verdict -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'workflow-readiness-recommendation' -Value $recommendation -DestPath $GitHubOutputPath

Write-Host ("[vi-history-workflow-readiness] verdict={0} recommendation={1}" -f $verdict, $recommendation)
Write-Host ("[vi-history-workflow-readiness] json={0}" -f $jsonOutResolved)
Write-Host ("[vi-history-workflow-readiness] markdown={0}" -f $mdOutResolved)
Write-Output $jsonOutResolved
