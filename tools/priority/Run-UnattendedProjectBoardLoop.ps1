#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Repo = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$RuntimeDir = 'tests/results/_agent/runtime',
  [string]$OrchestratorDir = 'tests/results/_agent/runtime-linux-orchestrator',
  [string]$DaemonContainerName = 'comparevi-runtime-daemon-origin8',
  [string]$LinuxContext = 'docker-desktop',
  [int]$DaemonPollIntervalSeconds = 60,
  [int]$CycleIntervalSeconds = 90,
  [int]$MaxCycles = 0,
  [switch]$QueueApply,
  [switch]$NoPortfolioApply,
  [switch]$StopWhenNoOpenIssues,
  [string]$ProjectStatus = 'In Progress',
  [string]$ProjectProgram = 'Shared Infra',
  [string]$ProjectPhase = 'Helper Workflow',
  [string]$ProjectEnvironmentClass = 'Infra',
  [string]$ProjectBlockingSignal = 'Scope',
  [string]$ProjectEvidenceState = 'Partial',
  [string]$ProjectPortfolioTrack = 'Agent UX',
  [switch]$SleepMode,
  [int]$QueuePauseRecoveryThresholdCycles = 2,
  [int]$QueuePauseRecoveryCooldownMinutes = 30,
  [int]$QueuePauseRecoveryMaxAttempts = 8,
  [string]$QueuePauseRecoveryRef = 'develop',
  [switch]$DispatchValidateOnQueuePause,
  [switch]$QueuePauseRecoveryAllowFork,
  [switch]$OnlyRecoverQueueWhenEligible,
  [int]$MaxConsecutiveCycleFailures = 0,
  [switch]$AutoBootstrapOnFailure,
  [switch]$AutoPrioritySyncLane,
  [switch]$AutoDevelopSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaState = 'priority/unattended-project-board-state@v1'
$schemaCycle = 'priority/unattended-project-board-cycle@v1'
$schemaEvent = 'priority/unattended-project-board-event@v1'
$schemaSleepState = 'priority/unattended-sleep-mode-state@v1'
$recoverableQueuePauseReasons = @(
  'success-rate-below-threshold',
  'trunk-red-window-exceeded',
  'health-workflow-fetch-errors',
  'queued-runs-threshold-exceeded',
  'in-progress-runs-threshold-exceeded',
  'stalled-runs-detected'
)

if ($SleepMode) {
  if (-not $PSBoundParameters.ContainsKey('QueueApply')) { $QueueApply = $true }
  if (-not $PSBoundParameters.ContainsKey('StopWhenNoOpenIssues')) { $StopWhenNoOpenIssues = $true }
  if (-not $PSBoundParameters.ContainsKey('DispatchValidateOnQueuePause')) { $DispatchValidateOnQueuePause = $true }
  if (-not $PSBoundParameters.ContainsKey('QueuePauseRecoveryAllowFork')) { $QueuePauseRecoveryAllowFork = $true }
  if (-not $PSBoundParameters.ContainsKey('OnlyRecoverQueueWhenEligible')) { $OnlyRecoverQueueWhenEligible = $true }
  if (-not $PSBoundParameters.ContainsKey('AutoBootstrapOnFailure')) { $AutoBootstrapOnFailure = $true }
  if (-not $PSBoundParameters.ContainsKey('AutoPrioritySyncLane')) { $AutoPrioritySyncLane = $true }
}

function Get-NowUtcIso {
  return (Get-Date).ToUniversalTime().ToString('o')
}

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Payload
  )
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    Ensure-Directory -Path $dir
  }
  $Payload | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 40 -ErrorAction Stop
  } catch {
    return $null
  }
}

function Invoke-CommandCapture {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$Arguments
  )
  $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
  $exitCode = $LASTEXITCODE
  return [pscustomobject]@{
    command = @($FilePath) + $Arguments
    exitCode = [int]$exitCode
    lines = $lines
    text = ($lines -join "`n")
  }
}

function Test-RateLimitSignal {
  param([string[]]$Lines)
  foreach ($line in @($Lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    if ($line -match '(?i)rate limit') {
      return $true
    }
  }
  return $false
}

function Append-Event {
  param(
    [Parameter(Mandatory)][string]$EventsPath,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Outcome,
    [object]$Details
  )
  $event = [ordered]@{
    schema = $schemaEvent
    generatedAt = Get-NowUtcIso
    action = $Action
    outcome = $Outcome
    details = $Details
  }
  $dir = Split-Path -Parent $EventsPath
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    Ensure-Directory -Path $dir
  }
  Add-Content -LiteralPath $EventsPath -Value ($event | ConvertTo-Json -Depth 40) -Encoding utf8
}

function Get-SleepProfile {
  return [ordered]@{
    enabled = [bool]$SleepMode
    dispatchValidateOnQueuePause = [bool]$DispatchValidateOnQueuePause
    queuePauseRecoveryThresholdCycles = $QueuePauseRecoveryThresholdCycles
    queuePauseRecoveryCooldownMinutes = $QueuePauseRecoveryCooldownMinutes
    queuePauseRecoveryMaxAttempts = $QueuePauseRecoveryMaxAttempts
    queuePauseRecoveryRef = $QueuePauseRecoveryRef
    queuePauseRecoveryAllowFork = [bool]$QueuePauseRecoveryAllowFork
    onlyRecoverQueueWhenEligible = [bool]$OnlyRecoverQueueWhenEligible
    maxConsecutiveCycleFailures = $MaxConsecutiveCycleFailures
    autoBootstrapOnFailure = [bool]$AutoBootstrapOnFailure
    autoPrioritySyncLane = [bool]$AutoPrioritySyncLane
    autoDevelopSync = [bool]$AutoDevelopSync
  }
}

function Write-SleepState {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$LoopStartedAt,
    [Parameter(Mandatory)][int]$Cycle,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][int]$ConsecutiveCycleFailures,
    [Parameter(Mandatory)][int]$QueuePausedStreak,
    [string[]]$LastQueuePauseReasons = @(),
    [string]$LastQueueRecoveryAttemptAt,
    [string]$LastRateLimitDetectedAt,
    [Parameter(Mandatory)][int]$QueueRecoveryAttempts,
    [object]$LastQueueRecovery,
    [object]$LastCycleRecovery,
    [object]$SleepProfile
  )
  $payload = [ordered]@{
    schema = $schemaSleepState
    generatedAt = Get-NowUtcIso
    loopStartedAt = $LoopStartedAt
    cycle = $Cycle
    status = $Status
    sleepMode = $SleepProfile
    consecutiveCycleFailures = $ConsecutiveCycleFailures
    queuePausedStreak = $QueuePausedStreak
    lastQueuePauseReasons = @($LastQueuePauseReasons)
    queuePauseRecovery = [ordered]@{
      attempts = $QueueRecoveryAttempts
      lastAttemptAt = $LastQueueRecoveryAttemptAt
      last = $LastQueueRecovery
    }
    lastRateLimitDetectedAt = $LastRateLimitDetectedAt
    lastCycleRecovery = $LastCycleRecovery
  }
  Write-JsonFile -Path $Path -Payload $payload
}

function Resolve-IssueUrlFromHeartbeat {
  param(
    [Parameter(Mandatory)][string]$RepoSlug,
    [Parameter(Mandatory)]$Heartbeat
  )
  $issueNumber = $Heartbeat.activeLane.issue
  if (-not $issueNumber) {
    return $null
  }
  return "https://github.com/$RepoSlug/issues/$issueNumber"
}

function Invoke-ProjectPortfolioApply {
  param(
    [Parameter(Mandatory)][string]$TargetUrl,
    [switch]$DryRun
  )
  $args = @(
    'tools/npm/run-script.mjs',
    'priority:project:portfolio:apply',
    '--',
    '--url',
    $TargetUrl,
    '--status',
    $ProjectStatus,
    '--program',
    $ProjectProgram,
    '--phase',
    $ProjectPhase,
    '--environment-class',
    $ProjectEnvironmentClass,
    '--blocking-signal',
    $ProjectBlockingSignal,
    '--evidence-state',
    $ProjectEvidenceState,
    '--portfolio-track',
    $ProjectPortfolioTrack
  )
  if ($DryRun) {
    $args += '--dry-run'
  }
  return Invoke-CommandCapture -FilePath 'node' -Arguments $args
}

function Invoke-GhIssueListCount {
  param([Parameter(Mandatory)][string]$RepoSlug)
  $result = Invoke-CommandCapture -FilePath 'gh' -Arguments @(
    'issue',
    'list',
    '--repo',
    $RepoSlug,
    '--state',
    'open',
    '--limit',
    '200',
    '--json',
    'number'
  )
  if ($result.exitCode -ne 0) {
    return [pscustomobject]@{
      status = 'error'
      count = $null
      command = $result.command
      output = $result.lines
    }
  }
  try {
    $rows = $result.text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
    $count = @($rows).Count
    return [pscustomobject]@{
      status = 'ok'
      count = $count
      command = $result.command
      output = @()
    }
  } catch {
    return [pscustomobject]@{
      status = 'parse-error'
      count = $null
      command = $result.command
      output = $result.lines
      message = $_.Exception.Message
    }
  }
}

function Read-QueueSupervisorReport {
  param([Parameter(Mandatory)][string]$RepoRoot)
  $path = Join-Path $RepoRoot 'tests/results/_agent/queue/queue-supervisor-report.json'
  $parsed = Read-JsonFile -Path $path
  return [pscustomobject]@{
    path = $path
    exists = (Test-Path -LiteralPath $path -PathType Leaf)
    parsed = $parsed
  }
}

function Test-CooldownElapsed {
  param(
    [string]$LastAttemptAt,
    [int]$CooldownMinutes
  )
  if ([string]::IsNullOrWhiteSpace($LastAttemptAt)) {
    return $true
  }
  try {
    $last = [DateTime]::Parse($LastAttemptAt).ToUniversalTime()
    $delta = (Get-Date).ToUniversalTime() - $last
    return $delta.TotalMinutes -ge [double]([Math]::Max(0, $CooldownMinutes))
  } catch {
    return $true
  }
}

function Invoke-QueuePauseRecovery {
  param(
    [Parameter(Mandatory)][string]$Ref,
    [switch]$AllowFork
  )
  $args = @(
    'tools/npm/run-script.mjs',
    'priority:validate',
    '--',
    '--ref',
    $Ref
  )
  if ($AllowFork) {
    $args += '--allow-fork'
  }
  return Invoke-CommandCapture -FilePath 'node' -Arguments $args
}

function Invoke-CycleFailureRecovery {
  param(
    [switch]$RunBootstrap,
    [switch]$RunPrioritySyncLane,
    [switch]$RunDevelopSync
  )

  $steps = @()
  if ($RunBootstrap) {
    $result = Invoke-CommandCapture -FilePath 'pwsh' -Arguments @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      'tools/priority/bootstrap.ps1'
    )
    $steps += [ordered]@{
      action = 'bootstrap'
      skipped = $false
      command = $result.command
      exitCode = $result.exitCode
      output = $result.lines
    }
  } else {
    $steps += [ordered]@{ action = 'bootstrap'; skipped = $true }
  }

  if ($RunPrioritySyncLane) {
    $result = Invoke-CommandCapture -FilePath 'node' -Arguments @(
      'tools/npm/run-script.mjs',
      'priority:sync:lane'
    )
    $steps += [ordered]@{
      action = 'priority-sync-lane'
      skipped = $false
      command = $result.command
      exitCode = $result.exitCode
      output = $result.lines
    }
  } else {
    $steps += [ordered]@{ action = 'priority-sync-lane'; skipped = $true }
  }

  if ($RunDevelopSync) {
    $result = Invoke-CommandCapture -FilePath 'node' -Arguments @(
      'tools/npm/run-script.mjs',
      'priority:develop:sync'
    )
    $steps += [ordered]@{
      action = 'priority-develop-sync'
      skipped = $false
      command = $result.command
      exitCode = $result.exitCode
      output = $result.lines
    }
  } else {
    $steps += [ordered]@{ action = 'priority-develop-sync'; skipped = $true }
  }

  $blocking = @($steps | Where-Object { -not $_.skipped -and ($_.exitCode -ne 0) })
  return [ordered]@{
    generatedAt = Get-NowUtcIso
    status = if ($blocking.Count -eq 0) { 'pass' } else { 'blocked' }
    stepCount = @($steps | Where-Object { -not $_.skipped }).Count
    blockedSteps = $blocking.Count
    steps = $steps
  }
}

$repoRoot = Resolve-RepoRoot
Set-Location -LiteralPath $repoRoot

$orchestratorDirHost = if ([System.IO.Path]::IsPathRooted($OrchestratorDir)) {
  [System.IO.Path]::GetFullPath($OrchestratorDir)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OrchestratorDir))
}
$cyclesDir = Join-Path $orchestratorDirHost 'cycles'
$statePath = Join-Path $orchestratorDirHost 'state.json'
$eventsPath = Join-Path $orchestratorDirHost 'events.ndjson'
$stopRequestPath = Join-Path $orchestratorDirHost 'stop-request.json'
$statusPath = Join-Path $orchestratorDirHost 'status.json'
$sleepStatePath = Join-Path $orchestratorDirHost 'sleep-mode-state.json'

Ensure-Directory -Path $orchestratorDirHost
Ensure-Directory -Path $cyclesDir

$loopStartedAt = Get-NowUtcIso
$cycle = 0
$finalOutcome = 'running'
$finalMessage = ''
$consecutiveCycleFailures = 0
$queuePausedStreak = 0
$lastQueuePauseReasons = @()
$lastQueueRecoveryAttemptAt = $null
$queueRecoveryAttempts = 0
$lastQueueRecovery = $null
$lastCycleRecovery = $null
$lastRateLimitDetectedAt = $null
$sleepProfile = Get-SleepProfile

Append-Event -EventsPath $eventsPath -Action 'loop-start' -Outcome 'started' -Details @{
  repo = $Repo
  runtimeDir = $RuntimeDir
  queueApply = [bool]$QueueApply
  portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
  stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
  sleepMode = $sleepProfile
}
Write-JsonFile -Path $statePath -Payload ([ordered]@{
  schema = $schemaState
  generatedAt = Get-NowUtcIso
  loopStartedAt = $loopStartedAt
  cycle = 0
  status = 'running'
  outcome = 'started'
  message = 'Loop initialized.'
  repo = $Repo
  runtimeDir = $RuntimeDir
  queueApply = [bool]$QueueApply
  portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
  stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
  sleepMode = $sleepProfile
  artifacts = [ordered]@{
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    cyclesDir = $cyclesDir
    stopRequestPath = $stopRequestPath
    sleepStatePath = $sleepStatePath
  }
})
Write-SleepState -Path $sleepStatePath `
  -LoopStartedAt $loopStartedAt `
  -Cycle 0 `
  -Status 'running' `
  -ConsecutiveCycleFailures $consecutiveCycleFailures `
  -QueuePausedStreak $queuePausedStreak `
  -LastQueuePauseReasons $lastQueuePauseReasons `
  -LastQueueRecoveryAttemptAt $lastQueueRecoveryAttemptAt `
  -LastRateLimitDetectedAt $lastRateLimitDetectedAt `
  -QueueRecoveryAttempts $queueRecoveryAttempts `
  -LastQueueRecovery $lastQueueRecovery `
  -LastCycleRecovery $lastCycleRecovery `
  -SleepProfile $sleepProfile

while ($true) {
  if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
    $finalOutcome = 'stop-requested'
    $finalMessage = 'Stop request file detected.'
    Append-Event -EventsPath $eventsPath -Action 'loop-stop' -Outcome $finalOutcome -Details @{
      stopRequestPath = $stopRequestPath
    }
    break
  }

  if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) {
    $finalOutcome = 'max-cycles-reached'
    $finalMessage = "Reached MaxCycles=$MaxCycles."
    Append-Event -EventsPath $eventsPath -Action 'loop-stop' -Outcome $finalOutcome -Details @{
      maxCycles = $MaxCycles
    }
    break
  }

  $cycle += 1
  $cycleStartedAt = Get-NowUtcIso
  $rateLimitDetectedThisCycle = $false
  Write-JsonFile -Path $statePath -Payload ([ordered]@{
    schema = $schemaState
    generatedAt = $cycleStartedAt
    loopStartedAt = $loopStartedAt
    cycle = $cycle
    status = 'running'
    outcome = 'cycle-in-progress'
    message = "Executing cycle $cycle."
    repo = $Repo
    runtimeDir = $RuntimeDir
    queueApply = [bool]$QueueApply
    portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
    stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
    sleepMode = $sleepProfile
    artifacts = [ordered]@{
      statePath = $statePath
      statusPath = $statusPath
      eventsPath = $eventsPath
      cyclesDir = $cyclesDir
      stopRequestPath = $stopRequestPath
      sleepStatePath = $sleepStatePath
    }
  })
  $cycleReport = [ordered]@{
    schema = $schemaCycle
    cycle = $cycle
    generatedAt = $cycleStartedAt
    repo = $Repo
    runtimeDir = $RuntimeDir
    daemon = $null
    heartbeat = $null
    projectPortfolioCheck = $null
    projectPortfolioApply = @()
    queueSupervisor = $null
    queuePauseRecovery = $null
    cycleRecovery = $null
    openIssues = $null
    sleepMode = $sleepProfile
    status = 'pass'
    outcome = 'completed'
    message = $null
  }

  try {
    $daemonResult = Invoke-CommandCapture -FilePath 'pwsh' -Arguments @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      'tools/priority/Manage-RuntimeDaemonInDocker.ps1',
      '-Action',
      'start',
      '-Repo',
      $Repo,
      '-RuntimeDir',
      $RuntimeDir,
      '-ContainerName',
      $DaemonContainerName,
      '-LinuxContext',
      $LinuxContext,
      '-PollIntervalSeconds',
      "$DaemonPollIntervalSeconds",
      '-MaxCycles',
      '0',
      '-ExecuteTurn'
    )
    $cycleReport.daemon = [ordered]@{
      command = $daemonResult.command
      exitCode = $daemonResult.exitCode
      output = $daemonResult.lines
    }
    if ($daemonResult.exitCode -ne 0) {
      throw "Daemon ensure failed (exit=$($daemonResult.exitCode))."
    }

    $heartbeatPath = if ([System.IO.Path]::IsPathRooted($RuntimeDir)) {
      Join-Path $RuntimeDir 'observer-heartbeat.json'
    } else {
      Join-Path $repoRoot $RuntimeDir 'observer-heartbeat.json'
    }
    $heartbeat = Read-JsonFile -Path $heartbeatPath
    if ($heartbeat) {
      $cycleReport.heartbeat = [ordered]@{
        generatedAt = $heartbeat.generatedAt
        cyclesCompleted = $heartbeat.cyclesCompleted
        outcome = $heartbeat.outcome
        laneId = $heartbeat.activeLane.laneId
        issue = $heartbeat.activeLane.issue
        prUrl = $heartbeat.activeLane.prUrl
      }
    } else {
      $cycleReport.heartbeat = [ordered]@{
        generatedAt = $null
        cyclesCompleted = $null
        outcome = 'missing'
        laneId = $null
        issue = $null
        prUrl = $null
      }
    }

    $portfolioCheck = Invoke-CommandCapture -FilePath 'node' -Arguments @(
      'tools/npm/run-script.mjs',
      'priority:project:portfolio:check'
    )
    $cycleReport.projectPortfolioCheck = [ordered]@{
      command = $portfolioCheck.command
      exitCode = $portfolioCheck.exitCode
      output = $portfolioCheck.lines
    }
    $portfolioCheckOk = $portfolioCheck.exitCode -eq 0
    if ($portfolioCheck.exitCode -ne 0) {
      if (Test-RateLimitSignal -Lines $portfolioCheck.lines) {
        $rateLimitDetectedThisCycle = $true
        $lastRateLimitDetectedAt = Get-NowUtcIso
      }
      $portfolioFailureMessage = "Project portfolio check failed (exit=$($portfolioCheck.exitCode))."
      $cycleReport.projectPortfolioCheck.status = 'blocked'
      if ($SleepMode) {
        if ($cycleReport.status -eq 'pass') {
          $cycleReport.status = 'degraded'
          $cycleReport.outcome = 'portfolio-check-failed'
          $cycleReport.message = $portfolioFailureMessage
        }
        Append-Event -EventsPath $eventsPath -Action 'portfolio-check' -Outcome 'blocked' -Details @{
          cycle = $cycle
          message = $portfolioFailureMessage
        }
      } else {
        throw $portfolioFailureMessage
      }
    }

    if (-not $NoPortfolioApply -and $heartbeat -and $portfolioCheckOk) {
      $issueUrl = Resolve-IssueUrlFromHeartbeat -RepoSlug $Repo -Heartbeat $heartbeat
      if (-not [string]::IsNullOrWhiteSpace($issueUrl)) {
        $issueApply = Invoke-ProjectPortfolioApply -TargetUrl $issueUrl
        $cycleReport.projectPortfolioApply += [ordered]@{
          target = $issueUrl
          exitCode = $issueApply.exitCode
          command = $issueApply.command
          output = $issueApply.lines
        }
        if ($issueApply.exitCode -ne 0) {
          if (Test-RateLimitSignal -Lines $issueApply.lines) {
            $rateLimitDetectedThisCycle = $true
            $lastRateLimitDetectedAt = Get-NowUtcIso
          }
          $applyFailureMessage = "Project portfolio apply failed for issue URL $issueUrl (exit=$($issueApply.exitCode))."
          if ($SleepMode) {
            if ($cycleReport.status -eq 'pass') {
              $cycleReport.status = 'degraded'
              $cycleReport.outcome = 'portfolio-apply-failed'
              $cycleReport.message = $applyFailureMessage
            }
            Append-Event -EventsPath $eventsPath -Action 'portfolio-apply' -Outcome 'blocked' -Details @{
              cycle = $cycle
              target = $issueUrl
              message = $applyFailureMessage
            }
          } else {
            throw $applyFailureMessage
          }
        }
      }

      $prUrl = [string]$heartbeat.activeLane.prUrl
      if (-not [string]::IsNullOrWhiteSpace($prUrl)) {
        $prApply = Invoke-ProjectPortfolioApply -TargetUrl $prUrl
        $cycleReport.projectPortfolioApply += [ordered]@{
          target = $prUrl
          exitCode = $prApply.exitCode
          command = $prApply.command
          output = $prApply.lines
        }
        if ($prApply.exitCode -ne 0) {
          if (Test-RateLimitSignal -Lines $prApply.lines) {
            $rateLimitDetectedThisCycle = $true
            $lastRateLimitDetectedAt = Get-NowUtcIso
          }
          $applyFailureMessage = "Project portfolio apply failed for PR URL $prUrl (exit=$($prApply.exitCode))."
          if ($SleepMode) {
            if ($cycleReport.status -eq 'pass') {
              $cycleReport.status = 'degraded'
              $cycleReport.outcome = 'portfolio-apply-failed'
              $cycleReport.message = $applyFailureMessage
            }
            Append-Event -EventsPath $eventsPath -Action 'portfolio-apply' -Outcome 'blocked' -Details @{
              cycle = $cycle
              target = $prUrl
              message = $applyFailureMessage
            }
          } else {
            throw $applyFailureMessage
          }
        }
      }
    }

    $queueArgs = @(
      'tools/npm/run-script.mjs',
      'priority:queue:supervisor',
      '--',
      '--repo',
      $Repo
    )
    if ($QueueApply) {
      $queueArgs += '--apply'
    } else {
      $queueArgs += '--dry-run'
    }
    $queueResult = Invoke-CommandCapture -FilePath 'node' -Arguments $queueArgs
    $cycleReport.queueSupervisor = [ordered]@{
      command = $queueResult.command
      exitCode = $queueResult.exitCode
      output = $queueResult.lines
      apply = [bool]$QueueApply
      report = $null
    }
    $queueRunOk = $queueResult.exitCode -eq 0
    if (-not $queueRunOk) {
      if (Test-RateLimitSignal -Lines $queueResult.lines) {
        $rateLimitDetectedThisCycle = $true
        $lastRateLimitDetectedAt = Get-NowUtcIso
      }
      $queueFailureMessage = "Queue supervisor run failed (exit=$($queueResult.exitCode))."
      if ($SleepMode) {
        if ($cycleReport.status -eq 'pass') {
          $cycleReport.status = 'degraded'
          $cycleReport.outcome = 'queue-supervisor-failed'
          $cycleReport.message = $queueFailureMessage
        }
        Append-Event -EventsPath $eventsPath -Action 'queue-supervisor' -Outcome 'blocked' -Details @{
          cycle = $cycle
          message = $queueFailureMessage
        }
      } else {
        throw $queueFailureMessage
      }
    }

    $queueReport = if ($queueRunOk) { Read-QueueSupervisorReport -RepoRoot $repoRoot } else {
      [pscustomobject]@{
        path = (Join-Path $repoRoot 'tests/results/_agent/queue/queue-supervisor-report.json')
        exists = $false
        parsed = $null
      }
    }
    $pausedReasons = @()
    $paused = $false
    $eligibleCount = $null
    $plannedCount = $null
    $enqueuedCount = $null
    if ($queueReport.parsed) {
      $paused = [bool]$queueReport.parsed.paused
      $pausedReasons = @($queueReport.parsed.pausedReasons | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      $eligibleCount = $queueReport.parsed.summary.eligibleCount
      $plannedCount = $queueReport.parsed.summary.plannedCount
      $enqueuedCount = $queueReport.parsed.summary.enqueuedCount
    }
    $cycleReport.queueSupervisor.report = [ordered]@{
      path = $queueReport.path
      exists = $queueReport.exists
      parsed = [bool]$queueReport.parsed
      paused = $paused
      pausedReasons = $pausedReasons
      eligibleCount = $eligibleCount
      plannedCount = $plannedCount
      enqueuedCount = $enqueuedCount
    }

    if ($paused) {
      $queuePausedStreak += 1
      $lastQueuePauseReasons = $pausedReasons
    } else {
      $queuePausedStreak = 0
      $lastQueuePauseReasons = @()
      $lastQueueRecovery = $null
    }

    if ($paused -and $SleepMode -and $DispatchValidateOnQueuePause) {
      $queuePauseDecision = [ordered]@{
        generatedAt = Get-NowUtcIso
        pausedStreak = $queuePausedStreak
        thresholdCycles = $QueuePauseRecoveryThresholdCycles
        cooldownMinutes = $QueuePauseRecoveryCooldownMinutes
        maxAttempts = $QueuePauseRecoveryMaxAttempts
        attemptsSoFar = $queueRecoveryAttempts
        pauseReasons = $pausedReasons
        eligibleCount = $eligibleCount
        attempted = $false
        skippedReason = $null
        recovery = $null
      }

      $hasRecoverableReason = @($pausedReasons | Where-Object { $recoverableQueuePauseReasons -contains $_ }).Count -gt 0
      if (-not $hasRecoverableReason) {
        $queuePauseDecision.skippedReason = 'pause-reason-not-recoverable'
      } elseif ($OnlyRecoverQueueWhenEligible -and ($null -eq $eligibleCount -or [int]$eligibleCount -le 0)) {
        $queuePauseDecision.skippedReason = 'no-eligible-prs'
      } elseif ($queuePausedStreak -lt [Math]::Max(1, $QueuePauseRecoveryThresholdCycles)) {
        $queuePauseDecision.skippedReason = 'streak-below-threshold'
      } elseif ($queueRecoveryAttempts -ge [Math]::Max(1, $QueuePauseRecoveryMaxAttempts)) {
        $queuePauseDecision.skippedReason = 'max-attempts-reached'
      } elseif (-not (Test-CooldownElapsed -LastAttemptAt $lastQueueRecoveryAttemptAt -CooldownMinutes $QueuePauseRecoveryCooldownMinutes)) {
        $queuePauseDecision.skippedReason = 'cooldown-active'
      } else {
        $queuePauseDecision.attempted = $true
        $queueRecoveryAttempts += 1
        $lastQueueRecoveryAttemptAt = Get-NowUtcIso
        $validateRecovery = Invoke-QueuePauseRecovery -Ref $QueuePauseRecoveryRef -AllowFork:$QueuePauseRecoveryAllowFork
        $lastQueueRecovery = [ordered]@{
          generatedAt = Get-NowUtcIso
          command = $validateRecovery.command
          exitCode = $validateRecovery.exitCode
          output = $validateRecovery.lines
          recoveryRef = $QueuePauseRecoveryRef
          allowFork = [bool]$QueuePauseRecoveryAllowFork
          status = if ($validateRecovery.exitCode -eq 0) { 'pass' } else { 'blocked' }
        }
        $queuePauseDecision.recovery = $lastQueueRecovery
        Append-Event -EventsPath $eventsPath `
          -Action 'sleep-mode-queue-recovery' `
          -Outcome $lastQueueRecovery.status `
          -Details @{
            cycle = $cycle
            pauseReasons = $pausedReasons
            pausedStreak = $queuePausedStreak
            attempts = $queueRecoveryAttempts
            recoveryRef = $QueuePauseRecoveryRef
            allowFork = [bool]$QueuePauseRecoveryAllowFork
          }
      }
      $cycleReport.queuePauseRecovery = $queuePauseDecision
    }

    $queuePauseBlocking = $paused -and ($null -eq $eligibleCount -or [int]$eligibleCount -gt 0)
    if ($queuePauseBlocking) {
      $cycleReport.status = 'degraded'
      $cycleReport.outcome = 'queue-paused'
      $cycleReport.message = "Queue paused: $($pausedReasons -join ', ')"
    }

    $openIssues = Invoke-GhIssueListCount -RepoSlug $Repo
    $cycleReport.openIssues = $openIssues
    if ($openIssues.status -ne 'ok' -and (Test-RateLimitSignal -Lines $openIssues.output)) {
      $rateLimitDetectedThisCycle = $true
      $lastRateLimitDetectedAt = Get-NowUtcIso
    }

    if ($StopWhenNoOpenIssues -and $openIssues.status -eq 'ok' -and $openIssues.count -eq 0) {
      $cycleReport.outcome = 'queue-empty'
      $cycleReport.message = "No open issues remain in $Repo."
      $cyclePath = Join-Path $cyclesDir ("{0:yyyyMMddTHHmmssfffZ}-cycle-{1:0000}.json" -f (Get-Date).ToUniversalTime(), $cycle)
      Write-JsonFile -Path $cyclePath -Payload $cycleReport
      $finalOutcome = 'queue-empty'
      $finalMessage = $cycleReport.message
      Append-Event -EventsPath $eventsPath -Action 'loop-stop' -Outcome $finalOutcome -Details @{
        repo = $Repo
        openIssueCount = 0
      }
      $consecutiveCycleFailures = 0
      break
    }

    $consecutiveCycleFailures = 0
    $lastCycleRecovery = $null
  } catch {
    if (Test-RateLimitSignal -Lines @([string]$_.Exception.Message)) {
      $rateLimitDetectedThisCycle = $true
      $lastRateLimitDetectedAt = Get-NowUtcIso
    }
    $consecutiveCycleFailures += 1
    $cycleReport.status = 'blocked'
    $cycleReport.outcome = 'cycle-failed'
    $cycleReport.message = $_.Exception.Message
    Append-Event -EventsPath $eventsPath -Action 'cycle' -Outcome 'blocked' -Details @{
      cycle = $cycle
      message = $_.Exception.Message
      consecutiveCycleFailures = $consecutiveCycleFailures
    }

    if ($SleepMode -and ($AutoBootstrapOnFailure -or $AutoPrioritySyncLane -or $AutoDevelopSync)) {
      $lastCycleRecovery = Invoke-CycleFailureRecovery `
        -RunBootstrap:$AutoBootstrapOnFailure `
        -RunPrioritySyncLane:$AutoPrioritySyncLane `
        -RunDevelopSync:$AutoDevelopSync
      $cycleReport.cycleRecovery = $lastCycleRecovery
      Append-Event -EventsPath $eventsPath `
        -Action 'sleep-mode-cycle-recovery' `
        -Outcome $lastCycleRecovery.status `
        -Details @{
          cycle = $cycle
          consecutiveCycleFailures = $consecutiveCycleFailures
          stepCount = $lastCycleRecovery.stepCount
          blockedSteps = $lastCycleRecovery.blockedSteps
        }
    }
  }

  $cyclePath = Join-Path $cyclesDir ("{0:yyyyMMddTHHmmssfffZ}-cycle-{1:0000}.json" -f (Get-Date).ToUniversalTime(), $cycle)
  Write-JsonFile -Path $cyclePath -Payload $cycleReport

  $maxFailureThresholdReached = $MaxConsecutiveCycleFailures -gt 0 -and $consecutiveCycleFailures -ge $MaxConsecutiveCycleFailures
  if ($maxFailureThresholdReached) {
    Append-Event -EventsPath $eventsPath `
      -Action 'sleep-mode-failure-threshold' `
      -Outcome 'degraded' `
      -Details @{
        cycle = $cycle
        consecutiveCycleFailures = $consecutiveCycleFailures
        threshold = $MaxConsecutiveCycleFailures
      }
  }
  if ($rateLimitDetectedThisCycle) {
    Append-Event -EventsPath $eventsPath `
      -Action 'sleep-mode-rate-limit' `
      -Outcome 'degraded' `
      -Details @{
        cycle = $cycle
        message = 'GitHub API rate limit signal detected; extending loop backoff.'
      }
  }

  $statusPayload = [ordered]@{
    schema = $schemaState
    generatedAt = Get-NowUtcIso
    loopStartedAt = $loopStartedAt
    cycle = $cycle
    status = if ($cycleReport.status -eq 'pass') { 'running' } else { 'degraded' }
    outcome = $cycleReport.outcome
    message = $cycleReport.message
    repo = $Repo
    runtimeDir = $RuntimeDir
    queueApply = [bool]$QueueApply
    portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
    stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
    sleepMode = $sleepProfile
    metrics = [ordered]@{
      consecutiveCycleFailures = $consecutiveCycleFailures
      queuePausedStreak = $queuePausedStreak
      queueRecoveryAttempts = $queueRecoveryAttempts
      lastQueuePauseReasons = $lastQueuePauseReasons
      lastQueueRecoveryAttemptAt = $lastQueueRecoveryAttemptAt
      rateLimitDetected = $rateLimitDetectedThisCycle
      lastRateLimitDetectedAt = $lastRateLimitDetectedAt
    }
    artifacts = [ordered]@{
      statePath = $statePath
      statusPath = $statusPath
      eventsPath = $eventsPath
      cyclesDir = $cyclesDir
      stopRequestPath = $stopRequestPath
      sleepStatePath = $sleepStatePath
      latestCyclePath = $cyclePath
    }
  }
  Write-JsonFile -Path $statePath -Payload $statusPayload
  Write-JsonFile -Path $statusPath -Payload $statusPayload
  Write-SleepState -Path $sleepStatePath `
    -LoopStartedAt $loopStartedAt `
    -Cycle $cycle `
    -Status $statusPayload.status `
    -ConsecutiveCycleFailures $consecutiveCycleFailures `
    -QueuePausedStreak $queuePausedStreak `
    -LastQueuePauseReasons $lastQueuePauseReasons `
    -LastQueueRecoveryAttemptAt $lastQueueRecoveryAttemptAt `
    -LastRateLimitDetectedAt $lastRateLimitDetectedAt `
    -QueueRecoveryAttempts $queueRecoveryAttempts `
    -LastQueueRecovery $lastQueueRecovery `
    -LastCycleRecovery $lastCycleRecovery `
    -SleepProfile $sleepProfile

  $sleepSeconds = $CycleIntervalSeconds
  if ($rateLimitDetectedThisCycle) {
    $sleepSeconds = [Math]::Max($sleepSeconds, 600)
  }
  if ($maxFailureThresholdReached) {
    $sleepSeconds = [Math]::Max($CycleIntervalSeconds, 300)
  } elseif ($consecutiveCycleFailures -gt 0) {
    $sleepSeconds = [Math]::Max($CycleIntervalSeconds, [Math]::Min(180, $CycleIntervalSeconds * 2))
  }
  Start-Sleep -Seconds $sleepSeconds
}

$finalState = [ordered]@{
  schema = $schemaState
  generatedAt = Get-NowUtcIso
  loopStartedAt = $loopStartedAt
  cycle = $cycle
  status = 'stopped'
  outcome = $finalOutcome
  message = $finalMessage
  repo = $Repo
  runtimeDir = $RuntimeDir
  queueApply = [bool]$QueueApply
  portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
  stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
  sleepMode = $sleepProfile
  metrics = [ordered]@{
    consecutiveCycleFailures = $consecutiveCycleFailures
    queuePausedStreak = $queuePausedStreak
    queueRecoveryAttempts = $queueRecoveryAttempts
    lastQueuePauseReasons = $lastQueuePauseReasons
    lastQueueRecoveryAttemptAt = $lastQueueRecoveryAttemptAt
    lastRateLimitDetectedAt = $lastRateLimitDetectedAt
  }
  artifacts = [ordered]@{
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    cyclesDir = $cyclesDir
    stopRequestPath = $stopRequestPath
    sleepStatePath = $sleepStatePath
  }
}
Write-JsonFile -Path $statePath -Payload $finalState
Write-JsonFile -Path $statusPath -Payload $finalState
Write-SleepState -Path $sleepStatePath `
  -LoopStartedAt $loopStartedAt `
  -Cycle $cycle `
  -Status 'stopped' `
  -ConsecutiveCycleFailures $consecutiveCycleFailures `
  -QueuePausedStreak $queuePausedStreak `
  -LastQueuePauseReasons $lastQueuePauseReasons `
  -LastQueueRecoveryAttemptAt $lastQueueRecoveryAttemptAt `
  -LastRateLimitDetectedAt $lastRateLimitDetectedAt `
  -QueueRecoveryAttempts $queueRecoveryAttempts `
  -LastQueueRecovery $lastQueueRecovery `
  -LastCycleRecovery $lastCycleRecovery `
  -SleepProfile $sleepProfile
