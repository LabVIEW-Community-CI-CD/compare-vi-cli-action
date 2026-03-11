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
    WslDaemonPidPath = Join-Path $runtimeDirPath 'delivery-agent-wsl-daemon-pid.json'
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

function Invoke-EnsurePrereqs {
  $scriptPath = Join-Path $PSScriptRoot 'Ensure-WSLDeliveryPrereqs.ps1'
  & pwsh -NoLogo -NoProfile -File $scriptPath -Distro $WslDistro | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Ensure-WSLDeliveryPrereqs failed for distro '$WslDistro'."
  }
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
  $deliveryState = Read-JsonFile -Path $Paths.DeliveryStatePath
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
    paths = [ordered]@{
      managerStatePath = $Paths.ManagerStatePath
      managerPidPath = $Paths.ManagerPidPath
      stopRequestPath = $Paths.StopRequestPath
      observerHeartbeatPath = $Paths.ObserverHeartbeatPath
      deliveryStatePath = $Paths.DeliveryStatePath
      wslDaemonPidPath = $Paths.WslDaemonPidPath
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

  Remove-Item -LiteralPath $paths.ManagerPidPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $paths.WslDaemonPidPath -Force -ErrorAction SilentlyContinue
  Emit-Status -Paths $paths -Outcome 'stopped' | Write-Output
  return
}

if (-not $Ensure) {
  throw 'Specify one of -Ensure, -Status, or -Stop.'
}

Invoke-EnsurePrereqs

$existingPidState = Read-JsonFile -Path $paths.ManagerPidPath
$existingPid = Get-OptionalIntProperty -InputObject $existingPidState -Name 'pid'
if (Test-ProcessAlive -ProcessId $existingPid) {
  Emit-Status -Paths $paths -Outcome 'already-running' | Write-Output
  return
}

Remove-Item -LiteralPath $paths.StopRequestPath -Force -ErrorAction SilentlyContinue

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

$process = Start-Process -FilePath 'pwsh' -ArgumentList $argumentList -PassThru -WindowStyle Hidden `
  -RedirectStandardOutput $paths.RunnerLogPath -RedirectStandardError $paths.RunnerErrorPath

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
