#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Ensure,
  [switch]$Stop,
  [switch]$Status,
  [switch]$QueueApply,
  [switch]$NoPortfolioApply,
  [switch]$StopWhenNoOpenIssues,
  [switch]$SleepMode,
  [string]$Repo = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$RuntimeDir = 'tests/results/_agent/runtime',
  [string]$OrchestratorDir = 'tests/results/_agent/runtime-linux-orchestrator',
  [string]$DaemonContainerName = 'comparevi-runtime-daemon-origin8',
  [string]$LinuxContext = 'docker-desktop',
  [int]$DaemonPollIntervalSeconds = 60,
  [int]$CycleIntervalSeconds = 90,
  [int]$MaxCycles = 0,
  [int]$StopWaitSeconds = 30,
  [string]$ProjectStatus = 'In Progress',
  [string]$ProjectProgram = 'Shared Infra',
  [string]$ProjectPhase = 'Helper Workflow',
  [string]$ProjectEnvironmentClass = 'Infra',
  [string]$ProjectBlockingSignal = 'Scope',
  [string]$ProjectEvidenceState = 'Partial',
  [string]$ProjectPortfolioTrack = 'Agent UX',
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
  [switch]$AutoDevelopSync,
  [int]$CodexHygieneIntervalCycles = 3,
  [string]$WslDistro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Convert-ToWslPath {
  param([Parameter(Mandatory)][string]$Path)

  try {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
  } catch {
    $resolved = [System.IO.Path]::GetFullPath($Path)
  }
  if ($resolved -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = ($Matches[2] -replace '\\', '/')
    return "/mnt/$drive/$rest"
  }

  throw "Unable to convert to WSL path: $Path"
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  } catch {
    return $null
  }
}

function Resolve-CommandPath {
  param([Parameter(Mandatory)][string]$Name)

  $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command) {
    throw "Required command not found on the Windows host: $Name"
  }

  return $command.Source
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Payload
  )

  $directory = Split-Path -Parent $Path
  if ($directory) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $Payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-ArtifactPaths {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $runtimeDirPath = Join-Path $RepoRoot $RuntimeDir
  return [pscustomobject]@{
    RuntimeDirPath = $runtimeDirPath
    ManagerStatePath = Join-Path $runtimeDirPath 'delivery-agent-manager-state.json'
    ManagerPidPath = Join-Path $runtimeDirPath 'delivery-agent-manager-pid.json'
    StopRequestPath = Join-Path $runtimeDirPath 'delivery-agent-manager-stop.json'
    ObserverHeartbeatPath = Join-Path $runtimeDirPath 'observer-heartbeat.json'
    DeliveryStatePath = Join-Path $runtimeDirPath 'delivery-agent-state.json'
    DeliveryMemoryPath = Join-Path $runtimeDirPath 'delivery-memory.json'
    WslDaemonPidPath = Join-Path $runtimeDirPath 'delivery-agent-wsl-daemon-pid.json'
    CodexStateHygienePath = Join-Path $runtimeDirPath 'codex-state-hygiene.json'
    HostSignalPath = Join-Path $runtimeDirPath 'daemon-host-signal.json'
    HostIsolationPath = Join-Path $runtimeDirPath 'delivery-agent-host-isolation.json'
    HostTracePath = Join-Path $runtimeDirPath 'delivery-agent-host-trace.ndjson'
    WslNativeDockerPath = Join-Path $runtimeDirPath 'wsl-native-docker.json'
    RunnerLogPath = Join-Path $runtimeDirPath 'delivery-agent-manager.log'
    RunnerErrorPath = Join-Path $runtimeDirPath 'delivery-agent-manager.stderr.log'
  }
}

function Test-ProcessAlive {
  param([int]$ProcessId)

  if ($ProcessId -le 0) {
    return $false
  }

  try {
    $null = Get-Process -Id $ProcessId -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Test-WslProcessAlive {
  param(
    [Parameter(Mandatory)][string]$Distro,
    [int]$ProcessId
  )

  if ($ProcessId -le 0) {
    return $false
  }

  & wsl.exe -d $Distro -- bash -lc "kill -0 $ProcessId >/dev/null 2>&1"
  return ($LASTEXITCODE -eq 0)
}

function Get-OptionalIntProperty {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $InputObject) {
    return 0
  }
  if (-not $InputObject.PSObject.Properties[$Name]) {
    return 0
  }
  return [int]$InputObject.$Name
}

function Get-OptionalProperty {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }
  if (-not $InputObject.PSObject.Properties[$Name]) {
    return $null
  }
  return $InputObject.$Name
}

function Get-OptionalStringProperty {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  $value = Get-OptionalProperty -InputObject $InputObject -Name $Name
  if ($null -eq $value) {
    return $null
  }
  $text = [string]$value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }
  return $text
}

function Get-OptionalDateTimeProperty {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  $text = Get-OptionalStringProperty -InputObject $InputObject -Name $Name
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  try {
    return [DateTime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
  } catch {
    return $null
  }
}

function Resolve-DeliveryStateForStatus {
  param(
    [AllowNull()][object]$DeliveryState,
    [AllowNull()][object]$Heartbeat,
    [Parameter(Mandatory)][object]$Paths
  )

  if ($null -eq $Heartbeat -or $null -eq $Heartbeat.activeLane) {
    return $DeliveryState
  }

  $heartbeatLane = $Heartbeat.activeLane
  $heartbeatIssue = Get-OptionalIntProperty -InputObject $heartbeatLane -Name 'issue'
  if ($heartbeatIssue -le 0) {
    return $DeliveryState
  }

  $deliveryGeneratedAt = Get-OptionalDateTimeProperty -InputObject $DeliveryState -Name 'generatedAt'
  $heartbeatGeneratedAt = Get-OptionalDateTimeProperty -InputObject $Heartbeat -Name 'generatedAt'
  $deliveryIssue = 0
  if ($DeliveryState -and $DeliveryState.PSObject.Properties['activeLane']) {
    $deliveryIssue = Get-OptionalIntProperty -InputObject $DeliveryState.activeLane -Name 'issue'
  }

  $heartbeatNewer = $heartbeatGeneratedAt -and ((-not $deliveryGeneratedAt) -or ($heartbeatGeneratedAt -gt $deliveryGeneratedAt))
  $issueDrift = $deliveryIssue -ne $heartbeatIssue
  if (-not $heartbeatNewer -and -not $issueDrift) {
    return $DeliveryState
  }

  $laneId = Get-OptionalStringProperty -InputObject $heartbeatLane -Name 'laneId'
  $taskPacket = Get-OptionalProperty -InputObject $heartbeatLane -Name 'taskPacket'
  $taskStatus = Get-OptionalStringProperty -InputObject $taskPacket -Name 'status'
  $runtimeOutcome = Get-OptionalStringProperty -InputObject $Heartbeat -Name 'outcome'
  $laneLifecycle = if ($runtimeOutcome -match 'blocked|failed') {
    'blocked'
  } elseif ($taskStatus -and $taskStatus -in @('planning', 'reshaping-backlog', 'coding', 'waiting-ci', 'waiting-review', 'ready-merge', 'blocked', 'complete', 'idle')) {
    $taskStatus
  } else {
    'planning'
  }
  $status = if ($laneLifecycle -eq 'idle') {
    'idle'
  } elseif ($laneLifecycle -eq 'blocked') {
    'blocked'
  } else {
    'running'
  }
  $lanePath = if (-not [string]::IsNullOrWhiteSpace($laneId)) {
    Join-Path (Join-Path $Paths.RuntimeDirPath 'delivery-agent-lanes') ("{0}.json" -f $laneId)
  } else {
    $null
  }

  return [ordered]@{
    schema = 'priority/delivery-agent-runtime-state@v1'
    generatedAt = if ($heartbeatGeneratedAt) { $heartbeatGeneratedAt.ToString('o') } else { [DateTime]::UtcNow.ToString('o') }
    repository = $Repo
    runtimeDir = $RuntimeDir
    status = $status
    laneLifecycle = $laneLifecycle
    activeCodingLanes = if ($laneLifecycle -eq 'coding') { 1 } else { 0 }
    derivedFromHeartbeat = $true
    activeLane = [ordered]@{
      schema = 'priority/delivery-agent-lane-state@v1'
      generatedAt = if ($heartbeatGeneratedAt) { $heartbeatGeneratedAt.ToString('o') } else { [DateTime]::UtcNow.ToString('o') }
      laneId = $laneId
      issue = $heartbeatIssue
      epic = Get-OptionalIntProperty -InputObject $heartbeatLane -Name 'epic'
      branch = Get-OptionalStringProperty -InputObject $heartbeatLane -Name 'branch'
      forkRemote = Get-OptionalStringProperty -InputObject $heartbeatLane -Name 'forkRemote'
      prUrl = Get-OptionalStringProperty -InputObject $heartbeatLane -Name 'prUrl'
      blockerClass = Get-OptionalStringProperty -InputObject $heartbeatLane -Name 'blockerClass'
      laneLifecycle = $laneLifecycle
      actionType = $runtimeOutcome
      outcome = $runtimeOutcome
      reason = $runtimeOutcome
      retryable = $false
      nextWakeCondition = $null
    }
    artifacts = [ordered]@{
      statePath = $Paths.DeliveryStatePath
      lanePath = $lanePath
    }
  }
}

function Invoke-EnsurePrereqs {
  $scriptPath = Join-Path $PSScriptRoot 'Ensure-WSLDeliveryPrereqs.ps1'
  $output = & pwsh -NoLogo -NoProfile -File $scriptPath -Distro $WslDistro
  if ($LASTEXITCODE -ne 0) {
    throw "Ensure-WSLDeliveryPrereqs failed for distro '$WslDistro'."
  }

  return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
}

function Invoke-DeliveryHostSignal {
  param(
    [Parameter(Mandatory)][ValidateSet('collect', 'isolate', 'restore')][string]$Mode,
    [Parameter(Mandatory)][object]$Paths
  )

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path (Resolve-RepoRoot) 'dist\tools\priority\delivery-host-signal.js'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Compiled delivery host signal collector not found: $scriptPath"
  }

  $args = @(
    $scriptPath,
    '--mode',
    $Mode,
    '--repo-root',
    (Resolve-RepoRoot),
    '--distro',
    $WslDistro,
    '--docker-host',
    'unix:///var/run/docker.sock',
    '--report',
    $Paths.HostSignalPath,
    '--isolation',
    $Paths.HostIsolationPath,
    '--trace',
    $Paths.HostTracePath
  )
  if ($Mode -eq 'collect') {
    $args += '--allow-runner-services'
  }

  $output = & $nodePath @args
  if ($LASTEXITCODE -ne 0) {
    throw "Delivery host signal '$Mode' failed."
  }

  return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
}

function Emit-Status {
  param(
    [Parameter(Mandatory)][object]$Paths,
    [string]$Outcome = 'status'
  )

  $pidState = Read-JsonFile -Path $Paths.ManagerPidPath
  $managerAlive = Test-ProcessAlive -ProcessId (Get-OptionalIntProperty -InputObject $pidState -Name 'pid')
  $daemonState = Read-JsonFile -Path $Paths.WslDaemonPidPath
  $daemonAlive = Test-WslProcessAlive -Distro $WslDistro -ProcessId (Get-OptionalIntProperty -InputObject $daemonState -Name 'pid')
  $heartbeat = Read-JsonFile -Path $Paths.ObserverHeartbeatPath
  $deliveryState = Resolve-DeliveryStateForStatus -DeliveryState (Read-JsonFile -Path $Paths.DeliveryStatePath) -Heartbeat $heartbeat -Paths $Paths
  $deliveryMemory = Read-JsonFile -Path $Paths.DeliveryMemoryPath
  $codexStateHygiene = Read-JsonFile -Path $Paths.CodexStateHygienePath
  $hostSignal = Read-JsonFile -Path $Paths.HostSignalPath
  $hostIsolation = Read-JsonFile -Path $Paths.HostIsolationPath
  $wslNativeDocker = Read-JsonFile -Path $Paths.WslNativeDockerPath
  $status = if ($managerAlive -or $daemonAlive) { 'running' } else { 'stopped' }

  $report = [ordered]@{
    schema = 'priority/unattended-delivery-agent-report@v1'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    repo = $Repo
    runtimeDir = $RuntimeDir
    distro = $WslDistro
    status = $status
    outcome = $Outcome
    manager = [ordered]@{
      pid = Get-OptionalIntProperty -InputObject $pidState -Name 'pid'
      alive = $managerAlive
      startedAt = Get-OptionalProperty -InputObject $pidState -Name 'startedAt'
      command = Get-OptionalProperty -InputObject $pidState -Name 'command'
    }
    daemon = [ordered]@{
      pid = Get-OptionalIntProperty -InputObject $daemonState -Name 'pid'
      alive = $daemonAlive
      startedAt = Get-OptionalProperty -InputObject $daemonState -Name 'startedAt'
      command = Get-OptionalProperty -InputObject $daemonState -Name 'command'
    }
    heartbeat = $heartbeat
    delivery = $deliveryState
    deliveryMemory = $deliveryMemory
    codexStateHygiene = $codexStateHygiene
    hostSignal = $hostSignal
    hostIsolation = $hostIsolation
    wslNativeDocker = $wslNativeDocker
    paths = [ordered]@{
      managerStatePath = $Paths.ManagerStatePath
      managerPidPath = $Paths.ManagerPidPath
      stopRequestPath = $Paths.StopRequestPath
      observerHeartbeatPath = $Paths.ObserverHeartbeatPath
      deliveryStatePath = $Paths.DeliveryStatePath
      deliveryMemoryPath = $Paths.DeliveryMemoryPath
      wslDaemonPidPath = $Paths.WslDaemonPidPath
      codexStateHygienePath = $Paths.CodexStateHygienePath
      hostSignalPath = $Paths.HostSignalPath
      hostIsolationPath = $Paths.HostIsolationPath
      hostTracePath = $Paths.HostTracePath
      wslNativeDockerPath = $Paths.WslNativeDockerPath
      runnerLogPath = $Paths.RunnerLogPath
      runnerErrorPath = $Paths.RunnerErrorPath
    }
  }

  Write-JsonFile -Path $Paths.ManagerStatePath -Payload $report
  $report | ConvertTo-Json -Depth 20
}

$repoRoot = Resolve-RepoRoot
$paths = Get-ArtifactPaths -RepoRoot $repoRoot

if ($Status) {
  Emit-Status -Paths $paths | Write-Output
  return
}

if ($Stop) {
  Write-JsonFile -Path $paths.StopRequestPath -Payload ([ordered]@{
      schema = 'priority/unattended-delivery-agent-stop@v1'
      requestedAt = [DateTime]::UtcNow.ToString('o')
      repo = $Repo
      distro = $WslDistro
    })

  $managerPidState = Read-JsonFile -Path $paths.ManagerPidPath
  $managerPid = Get-OptionalIntProperty -InputObject $managerPidState -Name 'pid'
  $deadline = (Get-Date).ToUniversalTime().AddSeconds($StopWaitSeconds)
  while ((Get-Date).ToUniversalTime() -lt $deadline) {
    if (-not (Test-ProcessAlive -ProcessId $managerPid)) {
      break
    }
    Start-Sleep -Seconds 1
  }

  if (Test-ProcessAlive -ProcessId $managerPid) {
    Stop-Process -Id $managerPid -Force -ErrorAction SilentlyContinue
  }

  $daemonPidState = Read-JsonFile -Path $paths.WslDaemonPidPath
  $daemonPid = Get-OptionalIntProperty -InputObject $daemonPidState -Name 'pid'
  if (Test-WslProcessAlive -Distro $WslDistro -ProcessId $daemonPid) {
    & wsl.exe -d $WslDistro -- bash -lc "kill $daemonPid >/dev/null 2>&1 || true"
    Start-Sleep -Seconds 2
    if (Test-WslProcessAlive -Distro $WslDistro -ProcessId $daemonPid) {
      & wsl.exe -d $WslDistro -- bash -lc "kill -9 $daemonPid >/dev/null 2>&1 || true"
    }
  }

  try {
    Invoke-DeliveryHostSignal -Mode 'restore' -Paths $paths | Out-Null
  } catch {
    Write-Warning ("Failed to restore runner services: {0}" -f $_.Exception.Message)
  }

  Remove-Item -LiteralPath $paths.ManagerPidPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $paths.WslDaemonPidPath -Force -ErrorAction SilentlyContinue
  Emit-Status -Paths $paths -Outcome 'stopped' | Write-Output
  return
}

if (-not $Ensure) {
  throw 'Specify one of -Ensure, -Status, or -Stop.'
}

$null = Invoke-EnsurePrereqs

$existingPidState = Read-JsonFile -Path $paths.ManagerPidPath
$existingPid = Get-OptionalIntProperty -InputObject $existingPidState -Name 'pid'
if (Test-ProcessAlive -ProcessId $existingPid) {
  Emit-Status -Paths $paths -Outcome 'already-running' | Write-Output
  return
}

Remove-Item -LiteralPath $paths.StopRequestPath -Force -ErrorAction SilentlyContinue

$null = Invoke-DeliveryHostSignal -Mode 'isolate' -Paths $paths

$runnerPath = Join-Path $PSScriptRoot 'Run-UnattendedDeliveryAgent.ps1'
$argumentList = @(
  '-NoLogo',
  '-NoProfile',
  '-File',
  $runnerPath,
  '-Repo',
  $Repo,
  '-RuntimeDir',
  $RuntimeDir,
  '-DaemonPollIntervalSeconds',
  "$DaemonPollIntervalSeconds",
  '-CycleIntervalSeconds',
  "$CycleIntervalSeconds",
  '-MaxCycles',
  "$MaxCycles",
  '-CodexHygieneIntervalCycles',
  "$CodexHygieneIntervalCycles",
  '-WslDistro',
  $WslDistro
)
if ($StopWhenNoOpenIssues -or $SleepMode) {
  $argumentList += '-StopWhenNoOpenIssues'
}
if ($SleepMode) {
  $argumentList += '-SleepMode'
}

$directory = Split-Path -Parent $paths.RunnerLogPath
if ($directory) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

try {
  $process = Start-Process -FilePath 'pwsh' -ArgumentList $argumentList -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $paths.RunnerLogPath -RedirectStandardError $paths.RunnerErrorPath
} catch {
  try {
    Invoke-DeliveryHostSignal -Mode 'restore' -Paths $paths | Out-Null
  } catch {
    Write-Warning ("Failed to restore runner services after launch failure: {0}" -f $_.Exception.Message)
  }
  throw
}

Write-JsonFile -Path $paths.ManagerPidPath -Payload ([ordered]@{
    schema = 'priority/unattended-delivery-agent-manager-pid@v1'
    startedAt = [DateTime]::UtcNow.ToString('o')
    pid = $process.Id
    repo = $Repo
    runtimeDir = $RuntimeDir
    distro = $WslDistro
    command = @('pwsh') + $argumentList
  })

Start-Sleep -Seconds 2
Emit-Status -Paths $paths -Outcome 'started' | Write-Output
