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
  [switch]$AutoDevelopSync,
  [int]$CodexHygieneIntervalCycles = 3,
  [string]$WslDistro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaState = 'priority/unattended-delivery-agent-state@v1'
$schemaCycle = 'priority/unattended-delivery-agent-cycle@v1'

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

function Get-StableLeaseOwner {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $leasePath = Join-Path $RepoRoot '.git\agent-writer-leases\workspace.json'
  $lease = Read-JsonFile -Path $leasePath
  if ($lease -and $lease.PSObject.Properties['owner'] -and -not [string]::IsNullOrWhiteSpace([string]$lease.owner)) {
    return [string]$lease.owner
  }

  $actor = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_WRITER_LEASE_ACTOR)) {
    $env:AGENT_WRITER_LEASE_ACTOR
  } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTOR)) {
    $env:GITHUB_ACTOR
  } elseif (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
    $env:USERNAME
  } elseif (-not [string]::IsNullOrWhiteSpace($env:USER)) {
    $env:USER
  } else {
    'unknown'
  }

  $hostName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
    $env:COMPUTERNAME
  } elseif (-not [string]::IsNullOrWhiteSpace($env:HOSTNAME)) {
    $env:HOSTNAME
  } else {
    'unknown'
  }

  return ('{0}@{1}:default' -f $actor, $hostName)
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

function Start-WslRuntimeDaemon {
  param(
    [Parameter(Mandatory)][string]$RepoRootWsl,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)][string]$LogPathWsl,
    [Parameter(Mandatory)][string]$LaunchScriptPath,
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][int]$DaemonPollIntervalSeconds,
    [Parameter(Mandatory)][string]$LeaseOwner,
    [switch]$StopOnIdle
  )

  $daemonArgs = @(
    'node',
    'tools/priority/runtime-daemon.mjs',
    '--repo',
    $Repo,
    '--runtime-dir',
    $RuntimeDir,
    '--poll-interval-seconds',
    "$DaemonPollIntervalSeconds",
    '--execute-turn'
  )
  if ($StopOnIdle) {
    $daemonArgs += '--stop-on-idle'
  }

  $quotedArgs = @()
  foreach ($arg in $daemonArgs) {
    $escaped = $arg.Replace('\\', '\\\\').Replace('"', '\\"')
    $quotedArgs += ('"{0}"' -f $escaped)
  }

  $launchScript = @(
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    'export PATH="$HOME/.local/bin:$PATH"',
    "export AGENT_WRITER_LEASE_OWNER='$LeaseOwner'",
    "export DOCKER_HOST='unix:///var/run/docker.sock'",
    "export COMPAREVI_DOCKER_RUNTIME_PROVIDER='native-wsl'",
    "export COMPAREVI_DOCKER_EXPECTED_CONTEXT=''",
    "cd '$RepoRootWsl'",
    "nohup $($quotedArgs -join ' ') > '$LogPathWsl' 2>&1 < /dev/null &",
    'echo $!'
  ) -join "`n"
  $launchScript | Set-Content -LiteralPath $LaunchScriptPath -Encoding utf8
  $launchScriptPathWsl = Convert-ToWslPath -Path $LaunchScriptPath

  $daemonPid = & wsl.exe -d $Distro -- bash $launchScriptPathWsl
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to start WSL runtime daemon in distro '$Distro'."
  }
  return [int]($daemonPid | Select-Object -Last 1)
}

function Stop-WslRuntimeDaemon {
  param(
    [Parameter(Mandatory)][string]$Distro,
    [int]$ProcessId
  )

  if ($ProcessId -le 0) {
    return
  }

  & wsl.exe -d $Distro -- bash -lc "kill $ProcessId >/dev/null 2>&1 || true"
  Start-Sleep -Seconds 2
  if (Test-WslProcessAlive -Distro $Distro -ProcessId $ProcessId) {
    & wsl.exe -d $Distro -- bash -lc "kill -9 $ProcessId >/dev/null 2>&1 || true"
  }
}

function Invoke-CodexStateHygiene {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'tools\priority\codex-state-hygiene.mjs'
  $reportPath = Join-Path $RepoRoot 'tests\results\_agent\runtime\codex-state-hygiene.json'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [ordered]@{
      status = 'skipped'
      reason = 'script-missing'
      reportPath = $reportPath
    }
  }

  $output = & $nodePath --no-warnings $scriptPath --apply --repo-root $RepoRoot --report $reportPath
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    return [ordered]@{
      status = 'error'
      reason = 'tool-failed'
      exitCode = $exitCode
      reportPath = $reportPath
    }
  }

  try {
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
  } catch {
    return [ordered]@{
      status = 'error'
      reason = 'report-parse-failed'
      reportPath = $reportPath
    }
  }
}

function Invoke-DeliveryMemory {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$RuntimeDir
  )

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'tools\priority\delivery-memory.mjs'
  $reportPath = Join-Path (Join-Path $RepoRoot $RuntimeDir) 'delivery-memory.json'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    return [ordered]@{
      status = 'skipped'
      reason = 'script-missing'
      reportPath = $reportPath
    }
  }

  $output = & $nodePath $scriptPath --repo-root $RepoRoot --repo $Repo --runtime-dir $RuntimeDir --out $reportPath
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    return [ordered]@{
      status = 'error'
      reason = 'tool-failed'
      exitCode = $exitCode
      reportPath = $reportPath
    }
  }

  try {
    return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
  } catch {
    return [ordered]@{
      status = 'error'
      reason = 'report-parse-failed'
      reportPath = $reportPath
    }
  }
}

function Resolve-DefaultHostIsolationState {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$HostSignalPath
  )

  return [ordered]@{
    schema = 'priority/delivery-agent-host-isolation@v1'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    repo = $Repo
    runtimeDir = $RuntimeDir
    distro = $Distro
    dockerHost = 'unix:///var/run/docker.sock'
    runnerServicePolicy = 'stop-all-actions-runner-services'
    restoreRunnerServicesOnExit = $true
    preemptedServices = @()
    restoredServices = @()
    lastAction = 'status'
    lastEvent = $null
    lastDrift = $null
    daemonFingerprint = $null
    lastStatus = $null
    hostSignalPath = $HostSignalPath
    counters = [ordered]@{
      runnerPreemptionCount = 0
      runnerRestoreCount = 0
      dockerDriftIncidentCount = 0
      nativeDaemonRepairCount = 0
      cyclesBlockedByHostRuntimeConflict = 0
    }
  }
}

function Invoke-DeliveryHostSignal {
  param(
    [Parameter(Mandatory)][ValidateSet('collect', 'isolate', 'restore')][string]$Mode,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$ReportPath,
    [Parameter(Mandatory)][string]$IsolationPath,
    [AllowNull()][string]$PreviousFingerprint,
    [switch]$AllowRunnerServices
  )

  $nodePath = Resolve-CommandPath -Name 'node'
  $scriptPath = Join-Path $RepoRoot 'dist\tools\priority\delivery-host-signal.js'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Compiled delivery host signal collector not found: $scriptPath"
  }

  $args = @(
    $scriptPath,
    '--mode',
    $Mode,
    '--repo-root',
    $RepoRoot,
    '--distro',
    $Distro,
    '--docker-host',
    'unix:///var/run/docker.sock',
    '--report',
    $ReportPath,
    '--isolation',
    $IsolationPath,
    '--trace',
    (Join-Path (Split-Path -Parent $ReportPath) 'delivery-agent-host-trace.ndjson')
  )
  if (-not [string]::IsNullOrWhiteSpace($PreviousFingerprint)) {
    $args += @('--previous-fingerprint', $PreviousFingerprint)
  }
  if ($AllowRunnerServices) {
    $args += '--allow-runner-services'
  }

  $output = & $nodePath @args
  if ($LASTEXITCODE -ne 0) {
    throw "Delivery host signal '$Mode' failed."
  }

  return (($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
}

function Update-HostIsolationState {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)][string]$Distro,
    [Parameter(Mandatory)][string]$HostSignalPath,
    [string]$CounterName,
    [int]$Increment = 0,
    [string]$LastEventType,
    [string]$LastEventDetail,
    [AllowNull()][object]$HostSignal = $null
  )

  $state = Read-JsonFile -Path $Path
  if ($null -eq $state) {
    $state = Resolve-DefaultHostIsolationState -Repo $Repo -RuntimeDir $RuntimeDir -Distro $Distro -HostSignalPath $HostSignalPath
  }

  if (-not $state.PSObject.Properties['counters']) {
    $state | Add-Member -NotePropertyName counters -NotePropertyValue ([ordered]@{}) -Force
  }
  foreach ($name in @('runnerPreemptionCount', 'runnerRestoreCount', 'dockerDriftIncidentCount', 'nativeDaemonRepairCount', 'cyclesBlockedByHostRuntimeConflict')) {
    if (-not $state.counters.PSObject.Properties[$name]) {
      $state.counters | Add-Member -NotePropertyName $name -NotePropertyValue 0 -Force
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($CounterName)) {
    $state.counters.$CounterName = [int]$state.counters.$CounterName + [int]$Increment
  }
  if (-not [string]::IsNullOrWhiteSpace($LastEventType)) {
    $state | Add-Member -NotePropertyName lastEvent -NotePropertyValue ([ordered]@{
        type = $LastEventType
        at = [DateTime]::UtcNow.ToString('o')
        detail = if ([string]::IsNullOrWhiteSpace($LastEventDetail)) { $null } else { $LastEventDetail }
      }) -Force
  }
  if ($HostSignal) {
    $state | Add-Member -NotePropertyName generatedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $state | Add-Member -NotePropertyName daemonFingerprint -NotePropertyValue $HostSignal.daemonFingerprint -Force
    $state | Add-Member -NotePropertyName lastStatus -NotePropertyValue $HostSignal.status -Force
    $state | Add-Member -NotePropertyName hostSignalPath -NotePropertyValue $HostSignalPath -Force
  }

  Write-JsonFile -Path $Path -Payload $state
  return $state
}

$repoRoot = Resolve-RepoRoot
$runtimeDirPath = Join-Path $repoRoot $RuntimeDir
$statePath = Join-Path $runtimeDirPath 'delivery-agent-manager-state.json'
$cyclePath = Join-Path $runtimeDirPath 'delivery-agent-manager-cycle.json'
$stopRequestPath = Join-Path $runtimeDirPath 'delivery-agent-manager-stop.json'
$wslPidPath = Join-Path $runtimeDirPath 'delivery-agent-wsl-daemon-pid.json'
$observerHeartbeatPath = Join-Path $runtimeDirPath 'observer-heartbeat.json'
$observerReportPath = Join-Path $runtimeDirPath 'runtime-daemon-report.json'
$deliveryMemoryPath = Join-Path $runtimeDirPath 'delivery-memory.json'
$hostSignalPath = Join-Path $runtimeDirPath 'daemon-host-signal.json'
$hostIsolationPath = Join-Path $runtimeDirPath 'delivery-agent-host-isolation.json'
$hostTracePath = Join-Path $runtimeDirPath 'delivery-agent-host-trace.ndjson'
$wslNativeDockerPath = Join-Path $runtimeDirPath 'wsl-native-docker.json'
$daemonLogPath = Join-Path $runtimeDirPath 'runtime-daemon-wsl.log'
$launchScriptPath = Join-Path $runtimeDirPath 'start-runtime-daemon.sh'
$repoRootWsl = Convert-ToWslPath -Path $repoRoot
$daemonLogPathWsl = Convert-ToWslPath -Path $daemonLogPath
$leaseOwner = Get-StableLeaseOwner -RepoRoot $repoRoot

New-Item -ItemType Directory -Path $runtimeDirPath -Force | Out-Null

$ensureScript = Join-Path $PSScriptRoot 'Ensure-WSLDeliveryPrereqs.ps1'
$ensureOutput = & pwsh -NoLogo -NoProfile -File $ensureScript -Distro $WslDistro
if ($LASTEXITCODE -ne 0) {
  throw "Ensure-WSLDeliveryPrereqs failed for distro '$WslDistro'."
}
$ensureResult = (($ensureOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)

$cycle = 0
$activeDaemonPid = [int]0
$codexStateHygiene = $null
$deliveryMemory = $null
$hostSignal = Read-JsonFile -Path $hostSignalPath
$hostIsolation = Update-HostIsolationState -Path $hostIsolationPath -Repo $Repo -RuntimeDir $RuntimeDir -Distro $WslDistro -HostSignalPath $hostSignalPath -HostSignal $hostSignal
$wslNativeDocker = Read-JsonFile -Path $wslNativeDockerPath

try {
  while ($true) {
    if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) {
      break
    }
    if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
      break
    }

    $cycle += 1
    $pidState = Read-JsonFile -Path $wslPidPath
    $activeDaemonPid = Get-OptionalIntProperty -InputObject $pidState -Name 'pid'
    $daemonAlive = Test-WslProcessAlive -Distro $WslDistro -ProcessId $activeDaemonPid
    $previousFingerprint = if ($hostSignal -and $hostSignal.PSObject.Properties['daemonFingerprint']) {
      [string]$hostSignal.daemonFingerprint
    } else {
      $null
    }

    $hostSignalResult = Invoke-DeliveryHostSignal `
      -Mode 'collect' `
      -RepoRoot $repoRoot `
      -Distro $WslDistro `
      -ReportPath $hostSignalPath `
      -IsolationPath $hostIsolationPath `
      -PreviousFingerprint $previousFingerprint
    $hostSignal = $hostSignalResult.report
    $hostIsolation = $hostSignalResult.isolation
    $wslNativeDocker = Read-JsonFile -Path $wslNativeDockerPath

    if ($hostSignal.status -eq 'runner-conflict') {
      if ($daemonAlive) {
        Stop-WslRuntimeDaemon -Distro $WslDistro -ProcessId $activeDaemonPid
        $daemonAlive = $false
      }
      $hostSignalResult = Invoke-DeliveryHostSignal `
        -Mode 'isolate' `
        -RepoRoot $repoRoot `
        -Distro $WslDistro `
        -ReportPath $hostSignalPath `
        -IsolationPath $hostIsolationPath `
        -PreviousFingerprint $hostSignal.daemonFingerprint
      $hostSignal = $hostSignalResult.report
      $hostIsolation = $hostSignalResult.isolation
    }

    $blockedByHostConflict = $false
    if ($hostSignal.status -ne 'native-wsl') {
      if ($daemonAlive) {
        Stop-WslRuntimeDaemon -Distro $WslDistro -ProcessId $activeDaemonPid
        $daemonAlive = $false
      }
      Remove-Item -LiteralPath $wslPidPath -Force -ErrorAction SilentlyContinue
      $hostIsolation = Update-HostIsolationState `
        -Path $hostIsolationPath `
        -Repo $Repo `
        -RuntimeDir $RuntimeDir `
        -Distro $WslDistro `
        -HostSignalPath $hostSignalPath `
        -CounterName 'cyclesBlockedByHostRuntimeConflict' `
        -Increment 1 `
        -LastEventType 'host-runtime-conflict' `
        -LastEventDetail ("status={0}" -f $hostSignal.status) `
        -HostSignal $hostSignal

      $repairError = $null
      try {
        $ensureOutput = & pwsh -NoLogo -NoProfile -File $ensureScript -Distro $WslDistro
        if ($LASTEXITCODE -ne 0) {
          throw "Ensure-WSLDeliveryPrereqs failed for distro '$WslDistro'."
        }
        $ensureResult = (($ensureOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
        $hostSignal = Read-JsonFile -Path $hostSignalPath
        $hostIsolation = Update-HostIsolationState `
          -Path $hostIsolationPath `
          -Repo $Repo `
          -RuntimeDir $RuntimeDir `
          -Distro $WslDistro `
          -HostSignalPath $hostSignalPath `
          -CounterName 'nativeDaemonRepairCount' `
          -Increment 1 `
          -LastEventType 'native-daemon-repaired' `
          -LastEventDetail ("status={0}" -f $hostSignal.status) `
          -HostSignal $hostSignal
        $wslNativeDocker = Read-JsonFile -Path $wslNativeDockerPath
      } catch {
        $repairError = $_.Exception.Message
        $hostIsolation = Update-HostIsolationState `
          -Path $hostIsolationPath `
          -Repo $Repo `
          -RuntimeDir $RuntimeDir `
          -Distro $WslDistro `
          -HostSignalPath $hostSignalPath `
          -LastEventType 'native-daemon-repair-failed' `
          -LastEventDetail $repairError `
          -HostSignal $hostSignal
      }

      if (-not $repairError) {
        $postRepairFingerprint = if ($hostSignal -and $hostSignal.PSObject.Properties['daemonFingerprint']) {
          [string]$hostSignal.daemonFingerprint
        } else {
          $null
        }
        $hostSignalResult = Invoke-DeliveryHostSignal `
          -Mode 'collect' `
          -RepoRoot $repoRoot `
          -Distro $WslDistro `
          -ReportPath $hostSignalPath `
          -IsolationPath $hostIsolationPath `
          -PreviousFingerprint $postRepairFingerprint
        $hostSignal = $hostSignalResult.report
        $hostIsolation = $hostSignalResult.isolation
      }

      $blockedByHostConflict = ($hostSignal.status -ne 'native-wsl')
    }

    if (-not $blockedByHostConflict -and -not $daemonAlive) {
      $activeDaemonPid = Start-WslRuntimeDaemon `
        -RepoRootWsl $repoRootWsl `
        -RuntimeDir $RuntimeDir `
        -LogPathWsl $daemonLogPathWsl `
        -LaunchScriptPath $launchScriptPath `
        -Distro $WslDistro `
        -Repo $Repo `
        -DaemonPollIntervalSeconds $DaemonPollIntervalSeconds `
        -LeaseOwner $leaseOwner `
        -StopOnIdle:($StopWhenNoOpenIssues -or $SleepMode)

      Write-JsonFile -Path $wslPidPath -Payload ([ordered]@{
          schema = 'priority/unattended-delivery-agent-wsl-daemon-pid@v1'
          startedAt = [DateTime]::UtcNow.ToString('o')
          pid = $activeDaemonPid
          repo = $Repo
          distro = $WslDistro
          command = @(
            'node',
            'tools/priority/runtime-daemon.mjs',
            '--repo',
            $Repo,
            '--runtime-dir',
            $RuntimeDir,
            '--poll-interval-seconds',
            "$DaemonPollIntervalSeconds",
            '--execute-turn'
          )
        })
      Start-Sleep -Seconds 3
      $daemonAlive = Test-WslProcessAlive -Distro $WslDistro -ProcessId $activeDaemonPid
    }

    if ($CodexHygieneIntervalCycles -gt 0 -and (($cycle -eq 1) -or (($cycle % $CodexHygieneIntervalCycles) -eq 0))) {
      $codexStateHygiene = Invoke-CodexStateHygiene -RepoRoot $repoRoot
    }

    $deliveryMemory = Invoke-DeliveryMemory -RepoRoot $repoRoot -Repo $Repo -RuntimeDir $RuntimeDir

    $heartbeat = Read-JsonFile -Path $observerHeartbeatPath
    $report = Read-JsonFile -Path $observerReportPath
    $state = [ordered]@{
      schema = $schemaState
      generatedAt = [DateTime]::UtcNow.ToString('o')
      repo = $Repo
      runtimeDir = $RuntimeDir
      distro = $WslDistro
      cycle = $cycle
      daemon = [ordered]@{
        pid = $activeDaemonPid
        alive = $daemonAlive
      }
      heartbeat = $heartbeat
      report = $report
      hostSignal = $hostSignal
      hostIsolation = $hostIsolation
      wslNativeDocker = $wslNativeDocker
      codexStateHygiene = $codexStateHygiene
      deliveryMemory = $deliveryMemory
      deliveryMemoryPath = $deliveryMemoryPath
      hostSignalPath = $hostSignalPath
      hostIsolationPath = $hostIsolationPath
      hostTracePath = $hostTracePath
      wslNativeDockerPath = $wslNativeDockerPath
      blockedByHostRuntimeConflict = $blockedByHostConflict
      stopWhenNoOpenIssues = ($StopWhenNoOpenIssues -or $SleepMode)
    }
    Write-JsonFile -Path $statePath -Payload $state
    Write-JsonFile -Path $cyclePath -Payload ([ordered]@{
        schema = $schemaCycle
        generatedAt = [DateTime]::UtcNow.ToString('o')
        cycle = $cycle
        daemon = $state.daemon
        report = $report
        hostSignal = $hostSignal
        hostIsolation = $hostIsolation
        wslNativeDocker = $wslNativeDocker
        codexStateHygiene = $codexStateHygiene
        deliveryMemory = $deliveryMemory
      })

    if ($blockedByHostConflict) {
      Start-Sleep -Seconds $CycleIntervalSeconds
      continue
    }

    if (-not $daemonAlive) {
      if (($StopWhenNoOpenIssues -or $SleepMode) -and $report -and $report.outcome -eq 'idle-stop') {
        break
      }
    }

    Start-Sleep -Seconds $CycleIntervalSeconds
  }
} finally {
  Stop-WslRuntimeDaemon -Distro $WslDistro -ProcessId $activeDaemonPid
  Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $wslPidPath -Force -ErrorAction SilentlyContinue

  try {
    $restoreResult = Invoke-DeliveryHostSignal `
      -Mode 'restore' `
      -RepoRoot $repoRoot `
      -Distro $WslDistro `
      -ReportPath $hostSignalPath `
      -IsolationPath $hostIsolationPath `
      -PreviousFingerprint (if ($hostSignal -and $hostSignal.PSObject.Properties['daemonFingerprint']) { [string]$hostSignal.daemonFingerprint } else { $null })
    $hostSignal = $restoreResult.report
    $hostIsolation = $restoreResult.isolation
  } catch {
    $hostIsolation = Update-HostIsolationState `
      -Path $hostIsolationPath `
      -Repo $Repo `
      -RuntimeDir $RuntimeDir `
      -Distro $WslDistro `
      -HostSignalPath $hostSignalPath `
      -LastEventType 'runner-service-restore-failed' `
      -LastEventDetail $_.Exception.Message `
      -HostSignal $hostSignal
  }
  $wslNativeDocker = Read-JsonFile -Path $wslNativeDockerPath

  Write-JsonFile -Path $statePath -Payload ([ordered]@{
      schema = $schemaState
      generatedAt = [DateTime]::UtcNow.ToString('o')
      repo = $Repo
      runtimeDir = $RuntimeDir
      distro = $WslDistro
      cycle = $cycle
      daemon = [ordered]@{
        pid = $activeDaemonPid
        alive = (Test-WslProcessAlive -Distro $WslDistro -ProcessId $activeDaemonPid)
      }
      hostSignal = $hostSignal
      hostIsolation = $hostIsolation
      wslNativeDocker = $wslNativeDocker
      codexStateHygiene = $codexStateHygiene
      deliveryMemory = $deliveryMemory
      deliveryMemoryPath = $deliveryMemoryPath
      hostSignalPath = $hostSignalPath
      hostIsolationPath = $hostIsolationPath
      hostTracePath = $hostTracePath
      wslNativeDockerPath = $wslNativeDockerPath
      outcome = 'stopped'
    })
}
