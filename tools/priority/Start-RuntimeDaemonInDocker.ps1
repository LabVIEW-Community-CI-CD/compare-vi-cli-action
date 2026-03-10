#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Repo,
  [string]$RuntimeDir = 'tests/results/_agent/runtime',
  [string]$HeartbeatPath,
  [string]$Image,
  [string]$ContainerName,
  [string]$LinuxContext = 'desktop-linux',
  [int]$HeartbeatFreshSeconds = 180,
  [int]$StartGraceSeconds = 180,
  [int]$PollIntervalSeconds = 60,
  [int]$MaxCycles = 0,
  [int]$SwitchTimeoutSeconds = 120,
  [int]$SwitchRetryCount = 3,
  [int]$SwitchRetryDelaySeconds = 4,
  [int]$LockWaitSeconds = 90,
  [switch]$Detach,
  [switch]$DryRun,
  [string]$DockerCommand = 'docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$managerPath = Join-Path $PSScriptRoot 'Manage-RuntimeDaemonInDocker.ps1'
$invokeArgs = @(
  '-Action', 'start',
  '-RuntimeDir', $RuntimeDir,
  '-LinuxContext', $LinuxContext,
  '-HeartbeatFreshSeconds', "$HeartbeatFreshSeconds",
  '-StartGraceSeconds', "$StartGraceSeconds",
  '-PollIntervalSeconds', "$PollIntervalSeconds",
  '-MaxCycles', "$MaxCycles",
  '-SwitchTimeoutSeconds', "$SwitchTimeoutSeconds",
  '-SwitchRetryCount', "$SwitchRetryCount",
  '-SwitchRetryDelaySeconds', "$SwitchRetryDelaySeconds",
  '-LockWaitSeconds', "$LockWaitSeconds",
  '-DockerCommand', $DockerCommand
)

if (-not [string]::IsNullOrWhiteSpace($Repo)) {
  $invokeArgs += @('-Repo', $Repo)
}
if (-not [string]::IsNullOrWhiteSpace($HeartbeatPath)) {
  $invokeArgs += @('-HeartbeatPath', $HeartbeatPath)
}
if (-not [string]::IsNullOrWhiteSpace($Image)) {
  $invokeArgs += @('-Image', $Image)
}
if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
  $invokeArgs += @('-ContainerName', $ContainerName)
}
if (-not $Detach) {
  $invokeArgs += '-Foreground'
}
if ($DryRun) {
  $invokeArgs += '-DryRun'
}

& $managerPath @invokeArgs
exit $LASTEXITCODE
