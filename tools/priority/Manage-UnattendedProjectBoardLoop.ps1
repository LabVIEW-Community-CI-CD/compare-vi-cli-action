#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Ensure,
  [switch]$Stop,
  [switch]$Status,
  [switch]$QueueApply,
  [switch]$NoPortfolioApply,
  [switch]$StopWhenNoOpenIssues,
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
  [string]$ProjectPortfolioTrack = 'Agent UX'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
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

function Test-ProcessAlive {
  param([int]$ProcessId)
  try {
    $null = Get-Process -Id $ProcessId -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

function Get-ProcessCommandLine {
  param([int]$ProcessId)
  try {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    return [string]$cim.CommandLine
  } catch {
    return $null
  }
}

function ConvertTo-QuotedCommandLine {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $quoted = foreach ($arg in $Arguments) {
    if ([string]::IsNullOrEmpty($arg)) {
      '""'
    } elseif ($arg -match '[\s"]') {
      '"' + ($arg.Replace('"', '\"')) + '"'
    } else {
      $arg
    }
  }

  return ($quoted -join ' ')
}

function Resolve-OrchestratorDir {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path
  )
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

$repoRoot = Resolve-RepoRoot
Set-Location -LiteralPath $repoRoot
$orchestratorDirHost = Resolve-OrchestratorDir -RepoRoot $repoRoot -Path $OrchestratorDir
Ensure-Directory -Path $orchestratorDirHost

$pidPath = Join-Path $orchestratorDirHost 'loop-pid.json'
$statePath = Join-Path $orchestratorDirHost 'state.json'
$statusPath = Join-Path $orchestratorDirHost 'status.json'
$eventsPath = Join-Path $orchestratorDirHost 'events.ndjson'
$stopRequestPath = Join-Path $orchestratorDirHost 'stop-request.json'
$stdoutPath = Join-Path $orchestratorDirHost 'loop.out'
$stderrPath = Join-Path $orchestratorDirHost 'loop.err'
$scriptPath = Join-Path $PSScriptRoot 'Run-UnattendedProjectBoardLoop.ps1'

if ($Ensure) {
  $existing = Read-JsonFile -Path $pidPath
  if ($existing -and $existing.pid) {
    $existingPid = [int]$existing.pid
    if (Test-ProcessAlive -ProcessId $existingPid) {
      $cmdLine = Get-ProcessCommandLine -ProcessId $existingPid
      if ($cmdLine -and $cmdLine.ToLowerInvariant().Contains('run-unattendedprojectboardloop.ps1')) {
        [ordered]@{
          status = 'already-running'
          pid = $existingPid
          pidPath = $pidPath
          statePath = $statePath
          statusPath = $statusPath
          eventsPath = $eventsPath
          stdoutPath = $stdoutPath
          stderrPath = $stderrPath
        } | ConvertTo-Json -Depth 20
        return
      }
    }
  }

  if (Test-Path -LiteralPath $stopRequestPath -PathType Leaf) {
    Remove-Item -LiteralPath $stopRequestPath -Force -ErrorAction SilentlyContinue
  }

  $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  $args = @(
    '-NoLogo',
    '-NoProfile',
    '-File',
    $scriptPath,
    '-Repo',
    $Repo,
    '-RuntimeDir',
    $RuntimeDir,
    '-OrchestratorDir',
    $orchestratorDirHost,
    '-DaemonContainerName',
    $DaemonContainerName,
    '-LinuxContext',
    $LinuxContext,
    '-DaemonPollIntervalSeconds',
    "$DaemonPollIntervalSeconds",
    '-CycleIntervalSeconds',
    "$CycleIntervalSeconds",
    '-MaxCycles',
    "$MaxCycles",
    '-ProjectStatus',
    $ProjectStatus,
    '-ProjectProgram',
    $ProjectProgram,
    '-ProjectPhase',
    $ProjectPhase,
    '-ProjectEnvironmentClass',
    $ProjectEnvironmentClass,
    '-ProjectBlockingSignal',
    $ProjectBlockingSignal,
    '-ProjectEvidenceState',
    $ProjectEvidenceState,
    '-ProjectPortfolioTrack',
    $ProjectPortfolioTrack
  )
  if ($QueueApply) {
    $args += '-QueueApply'
  }
  if ($NoPortfolioApply) {
    $args += '-NoPortfolioApply'
  }
  if ($StopWhenNoOpenIssues) {
    $args += '-StopWhenNoOpenIssues'
  }

  $argumentLine = ConvertTo-QuotedCommandLine -Arguments $args
  $proc = Start-Process -FilePath $pwsh `
    -ArgumentList $argumentLine `
    -WorkingDirectory $repoRoot `
    -WindowStyle Hidden `
    -PassThru `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath

  $pidPayload = [ordered]@{
    schema = 'priority/unattended-project-board-loop-pid@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    pid = $proc.Id
    scriptPath = $scriptPath
    args = $args
    workingDirectory = $repoRoot
    orchestratorDir = $orchestratorDirHost
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    stopRequestPath = $stopRequestPath
  }
  Write-JsonFile -Path $pidPath -Payload $pidPayload

  [ordered]@{
    status = 'started'
    pid = $proc.Id
    pidPath = $pidPath
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
    stopRequestPath = $stopRequestPath
  } | ConvertTo-Json -Depth 20
  return
}

if ($Stop) {
  $existing = Read-JsonFile -Path $pidPath
  $loopPid = if ($existing -and $existing.pid) { [int]$existing.pid } else { $null }
  $stopPayload = [ordered]@{
    schema = 'priority/unattended-project-board-stop-request@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    reason = 'operator-stop'
  }
  Write-JsonFile -Path $stopRequestPath -Payload $stopPayload

  $stopped = $false
  if ($loopPid) {
    $deadline = (Get-Date).ToUniversalTime().AddSeconds([math]::Max(1, $StopWaitSeconds))
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
      if (-not (Test-ProcessAlive -ProcessId $loopPid)) {
        $stopped = $true
        break
      }
      Start-Sleep -Seconds 1
    }
    if (-not $stopped -and (Test-ProcessAlive -ProcessId $loopPid)) {
      Stop-Process -Id $loopPid -Force -ErrorAction SilentlyContinue
      $stopped = $true
    }
  } else {
    $stopped = $true
  }

  Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue

  [ordered]@{
    status = if ($stopped) { 'stopped' } else { 'unknown' }
    pid = $loopPid
    pidPath = $pidPath
    stopRequestPath = $stopRequestPath
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
  } | ConvertTo-Json -Depth 20
  return
}

if ($Status) {
  $existing = Read-JsonFile -Path $pidPath
  $loopPid = if ($existing -and $existing.pid) { [int]$existing.pid } else { $null }
  $alive = if ($loopPid) { Test-ProcessAlive -ProcessId $loopPid } else { $false }
  $state = Read-JsonFile -Path $statePath
  $statusJson = Read-JsonFile -Path $statusPath
  [ordered]@{
    status = if ($alive) { 'running' } else { 'stopped' }
    pid = $loopPid
    alive = $alive
    pidPath = $pidPath
    statePath = $statePath
    statusPath = $statusPath
    eventsPath = $eventsPath
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
    stopRequestPath = $stopRequestPath
    state = $state
    statusPayload = $statusJson
  } | ConvertTo-Json -Depth 30
  return
}

[ordered]@{
  usage = @(
    'pwsh -File tools/priority/Manage-UnattendedProjectBoardLoop.ps1 -Ensure -QueueApply -StopWhenNoOpenIssues',
    'pwsh -File tools/priority/Manage-UnattendedProjectBoardLoop.ps1 -Status',
    'pwsh -File tools/priority/Manage-UnattendedProjectBoardLoop.ps1 -Stop'
  )
  orchestratorDir = $orchestratorDirHost
  pidPath = $pidPath
  statePath = $statePath
  statusPath = $statusPath
  eventsPath = $eventsPath
  stdoutPath = $stdoutPath
  stderrPath = $stderrPath
  stopRequestPath = $stopRequestPath
} | ConvertTo-Json -Depth 20
