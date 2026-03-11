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

$repoRoot = Resolve-RepoRoot
$runtimeDirPath = Join-Path $repoRoot $RuntimeDir
$statePath = Join-Path $runtimeDirPath 'delivery-agent-manager-state.json'
$cyclePath = Join-Path $runtimeDirPath 'delivery-agent-manager-cycle.json'
$stopRequestPath = Join-Path $runtimeDirPath 'delivery-agent-manager-stop.json'
$wslPidPath = Join-Path $runtimeDirPath 'delivery-agent-wsl-daemon-pid.json'
$observerHeartbeatPath = Join-Path $runtimeDirPath 'observer-heartbeat.json'
$observerReportPath = Join-Path $runtimeDirPath 'runtime-daemon-report.json'
$daemonLogPath = Join-Path $runtimeDirPath 'runtime-daemon-wsl.log'
$launchScriptPath = Join-Path $runtimeDirPath 'start-runtime-daemon.sh'
$repoRootWsl = Convert-ToWslPath -Path $repoRoot
$daemonLogPathWsl = Convert-ToWslPath -Path $daemonLogPath
$leaseOwner = Get-StableLeaseOwner -RepoRoot $repoRoot

New-Item -ItemType Directory -Path $runtimeDirPath -Force | Out-Null

$ensureScript = Join-Path $PSScriptRoot 'Ensure-WSLDeliveryPrereqs.ps1'
& pwsh -NoLogo -NoProfile -File $ensureScript -Distro $WslDistro | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Ensure-WSLDeliveryPrereqs failed for distro '$WslDistro'."
}

$cycle = 0
$activeDaemonPid = [int]0

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

    if (-not $daemonAlive) {
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
      stopWhenNoOpenIssues = ($StopWhenNoOpenIssues -or $SleepMode)
    }
    Write-JsonFile -Path $statePath -Payload $state
    Write-JsonFile -Path $cyclePath -Payload ([ordered]@{
        schema = $schemaCycle
        generatedAt = [DateTime]::UtcNow.ToString('o')
        cycle = $cycle
        daemon = $state.daemon
        report = $report
      })

    if (-not $daemonAlive) {
      if (($StopWhenNoOpenIssues -or $SleepMode) -and $report -and $report.outcome -eq 'idle-stop') {
        break
      }
    }

    Start-Sleep -Seconds $CycleIntervalSeconds
  }
} finally {
  if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
    Stop-WslRuntimeDaemon -Distro $WslDistro -ProcessId $activeDaemonPid
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wslPidPath -Force -ErrorAction SilentlyContinue
  }

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
      outcome = 'stopped'
    })
}
