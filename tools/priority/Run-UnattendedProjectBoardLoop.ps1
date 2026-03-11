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
  [string]$ProjectPortfolioTrack = 'Agent UX'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaState = 'priority/unattended-project-board-state@v1'
$schemaCycle = 'priority/unattended-project-board-cycle@v1'
$schemaEvent = 'priority/unattended-project-board-event@v1'

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

function Append-Event {
  param(
    [Parameter(Mandatory)][string]$EventsPath,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Outcome,
    [object]$Details
  )
  $event = [ordered]@{
    schema = $schemaEvent
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
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

Ensure-Directory -Path $orchestratorDirHost
Ensure-Directory -Path $cyclesDir

$loopStartedAt = (Get-Date).ToUniversalTime().ToString('o')
$cycle = 0
$finalOutcome = 'running'
$finalMessage = ''

Append-Event -EventsPath $eventsPath -Action 'loop-start' -Outcome 'started' -Details @{
  repo = $Repo
  runtimeDir = $RuntimeDir
  queueApply = [bool]$QueueApply
  portfolioApplyEnabled = [bool](-not $NoPortfolioApply)
  stopWhenNoOpenIssues = [bool]$StopWhenNoOpenIssues
}
Write-JsonFile -Path $statePath -Payload ([ordered]@{
  schema = $schemaState
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
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
  artifacts = [ordered]@{
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    cyclesDir = $cyclesDir
    stopRequestPath = $stopRequestPath
  }
})

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
  $cycleStartedAt = (Get-Date).ToUniversalTime().ToString('o')
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
    artifacts = [ordered]@{
      statePath = $statePath
      statusPath = $statusPath
      eventsPath = $eventsPath
      cyclesDir = $cyclesDir
      stopRequestPath = $stopRequestPath
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
    openIssues = $null
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
    if ($portfolioCheck.exitCode -ne 0) {
      throw "Project portfolio check failed (exit=$($portfolioCheck.exitCode))."
    }

    if (-not $NoPortfolioApply -and $heartbeat) {
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
          throw "Project portfolio apply failed for issue URL $issueUrl (exit=$($issueApply.exitCode))."
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
          throw "Project portfolio apply failed for PR URL $prUrl (exit=$($prApply.exitCode))."
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
    }
    if ($queueResult.exitCode -ne 0) {
      throw "Queue supervisor run failed (exit=$($queueResult.exitCode))."
    }

    $openIssues = Invoke-GhIssueListCount -RepoSlug $Repo
    $cycleReport.openIssues = $openIssues

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
      break
    }
  } catch {
    $cycleReport.status = 'blocked'
    $cycleReport.outcome = 'cycle-failed'
    $cycleReport.message = $_.Exception.Message
    Append-Event -EventsPath $eventsPath -Action 'cycle' -Outcome 'blocked' -Details @{
      cycle = $cycle
      message = $_.Exception.Message
    }
  }

  $cyclePath = Join-Path $cyclesDir ("{0:yyyyMMddTHHmmssfffZ}-cycle-{1:0000}.json" -f (Get-Date).ToUniversalTime(), $cycle)
  Write-JsonFile -Path $cyclePath -Payload $cycleReport

  $statusPayload = [ordered]@{
    schema = $schemaState
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
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
    artifacts = [ordered]@{
      statePath = $statePath
      statusPath = $statusPath
      eventsPath = $eventsPath
      cyclesDir = $cyclesDir
      stopRequestPath = $stopRequestPath
      latestCyclePath = $cyclePath
    }
  }
  Write-JsonFile -Path $statePath -Payload $statusPayload
  Write-JsonFile -Path $statusPath -Payload $statusPayload

  Start-Sleep -Seconds $CycleIntervalSeconds
}

$finalState = [ordered]@{
  schema = $schemaState
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
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
  artifacts = [ordered]@{
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    cyclesDir = $cyclesDir
    stopRequestPath = $stopRequestPath
  }
}
Write-JsonFile -Path $statePath -Payload $finalState
Write-JsonFile -Path $statusPath -Payload $finalState
