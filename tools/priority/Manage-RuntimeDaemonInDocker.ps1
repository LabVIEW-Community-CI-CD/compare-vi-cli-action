#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('start', 'status', 'logs', 'stop', 'reconcile')]
  [string]$Action = 'start',
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
  [switch]$StopOnIdle,
  [switch]$ExecuteTurn,
  [int]$TailLines = 200,
  [ValidateRange(5, 900)]
  [int]$SwitchTimeoutSeconds = 120,
  [ValidateRange(1, 10)]
  [int]$SwitchRetryCount = 3,
  [ValidateRange(1, 60)]
  [int]$SwitchRetryDelaySeconds = 4,
  [ValidateRange(5, 600)]
  [int]$LockWaitSeconds = 90,
  [switch]$Foreground,
  [bool]$RemoveOnStop = $true,
  [switch]$DryRun,
  [string]$DockerCommand = 'docker',
  [string]$ReconcileRoot = 'tests/results/_agent'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateSchema = 'priority/runtime-daemon-docker-state@v1'
$ReportSchema = 'priority/runtime-daemon-docker-report@v1'
$LogsSchema = 'priority/runtime-daemon-docker-logs@v1'
$EngineSchema = 'priority/runtime-daemon-docker-engine@v1'
$HealthSchema = 'priority/runtime-daemon-docker-health@v1'
$ReconcileSchema = 'priority/runtime-daemon-docker-reconcile@v1'

function Resolve-GitHubToken {
  $envToken = $env:GH_TOKEN
  if (-not [string]::IsNullOrWhiteSpace($envToken)) { return $envToken.Trim() }

  $envToken = $env:GITHUB_TOKEN
  if (-not [string]::IsNullOrWhiteSpace($envToken)) { return $envToken.Trim() }

  $candidatePaths = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN_FILE)) {
    $candidatePaths.Add($env:GH_TOKEN_FILE)
  }
  if ($IsWindows) {
    $candidatePaths.Add('C:\github_token.txt')
  }

  $userProfile = [Environment]::GetFolderPath('UserProfile')
  if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
    $candidatePaths.Add((Join-Path $userProfile '.config/github-token'))
    $candidatePaths.Add((Join-Path $userProfile '.github_token'))
  }

  foreach ($candidate in $candidatePaths) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    $line = Get-Content -LiteralPath $candidate -ErrorAction Stop |
      Where-Object { $_ -match '\S' } |
      Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace($line)) {
      return $line.Trim()
    }
  }

  return $null
}

function Get-DockerHostPath {
  param([Parameter(Mandatory)][string]$Path)

  $resolved = (Resolve-Path -LiteralPath $Path).Path
  if ($IsWindows) {
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $rest = $resolved.Substring(2).Replace('\', '/').TrimStart('/')
    return "/$drive/$rest"
  }

  return $resolved
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
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  $Payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Write-TextFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$Lines
  )

  $directory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }

  ($Lines -join [Environment]::NewLine) | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-DisplayDockerArgs {
  param([Parameter(Mandatory)][string[]]$Arguments)

  $display = [System.Collections.Generic.List[string]]::new()
  for ($index = 0; $index -lt $Arguments.Count; $index++) {
    $token = $Arguments[$index]
    if ($token -eq '-e' -and ($index + 1) -lt $Arguments.Count) {
      $next = $Arguments[$index + 1]
      if ($next -like 'GH_TOKEN=*' -or $next -like 'GITHUB_TOKEN=*') {
        $display.Add($token)
        $display.Add(($next.Split('=')[0] + '=***'))
        $index += 1
        continue
      }
    }
    $display.Add($token)
  }

  return $display.ToArray()
}

function Invoke-DockerCommand {
  param(
    [Parameter(Mandatory)][string]$DockerCommand,
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $raw = & $DockerCommand @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $lines = @($raw | ForEach-Object { [string]$_ })
  $text = ($lines -join "`n")

  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    throw ("{0} {1} failed (exit={2}). Output: {3}" -f $DockerCommand, ($Arguments -join ' '), $exitCode, $text)
  }

  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Lines = $lines
    Text = $text
  }
}

function Acquire-LockStream {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [ValidateRange(1, 600)][int]$WaitSeconds
  )

  $lockDir = Split-Path -Parent $LockPath
  if ($lockDir -and -not (Test-Path -LiteralPath $lockDir -PathType Container)) {
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
  }

  $deadline = (Get-Date).ToUniversalTime().AddSeconds($WaitSeconds)
  do {
    try {
      $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
      return $stream
    } catch [System.IO.IOException] {
      Start-Sleep -Seconds 2
    }
  } while ((Get-Date).ToUniversalTime() -lt $deadline)

  throw ("Timed out waiting for Docker manager lock: {0}" -f $LockPath)
}

function Resolve-DockerCliPath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} 'Docker\Docker\DockerCli.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Docker\Docker\DockerCli.exe')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return ''
}

function Invoke-DockerEngineSwitchFallback {
  param(
    [Parameter(Mandatory)][string]$ExpectedOsType
  )

  $dockerCliPath = Resolve-DockerCliPath
  if ([string]::IsNullOrWhiteSpace($dockerCliPath)) {
    throw ("DockerCli.exe not found. Unable to switch engine to '{0}' without context metadata." -f $ExpectedOsType)
  }

  $switchArg = switch ($ExpectedOsType.Trim().ToLowerInvariant()) {
    'windows' { '-SwitchWindowsEngine' }
    'linux' { '-SwitchLinuxEngine' }
    default { throw ("Unsupported ExpectedOsType for engine switch fallback: {0}" -f $ExpectedOsType) }
  }

  $raw = & $dockerCliPath $switchArg 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ("Docker engine switch fallback failed via '{0} {1}'. Output: {2}" -f $dockerCliPath, $switchArg, (@($raw | ForEach-Object { [string]$_ }) -join ' '))
  }
}

function Get-CurrentDockerContext {
  param([Parameter(Mandatory)][string]$DockerCommand)

  $result = Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('context', 'show') -IgnoreExitCode
  if ($result.ExitCode -ne 0) {
    return ''
  }

  return $result.Text.Trim()
}

function Set-ContextAndWait {
  param(
    [Parameter(Mandatory)][string]$DockerCommand,
    [Parameter(Mandatory)][string]$ContextName,
    [Parameter(Mandatory)][string]$ExpectedOsType,
    [ValidateRange(5, 900)][int]$TimeoutSeconds,
    [ValidateRange(1, 10)][int]$RetryCount,
    [ValidateRange(1, 60)][int]$RetryDelaySeconds
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
    try {
      $useContext = Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('context', 'use', $ContextName) -IgnoreExitCode
      $mode = 'context-use'
      if ($useContext.ExitCode -ne 0) {
        $switchError = [string]$useContext.Text
        $missingContext = ($switchError -match '(?i)context.+not found') -or ($switchError -match '(?i)cannot find the path specified')
        if ($missingContext) {
          Invoke-DockerEngineSwitchFallback -ExpectedOsType $ExpectedOsType
          $mode = 'engine-fallback'
        } else {
          throw ("{0} context use {1} failed (exit={2}). Output: {3}" -f $DockerCommand, $ContextName, $useContext.ExitCode, $switchError)
        }
      }

      $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
      do {
        $osProbe = Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('info', '--format', '{{.OSType}}') -IgnoreExitCode
        if ($osProbe.ExitCode -eq 0) {
          $osType = $osProbe.Text.Trim().ToLowerInvariant()
          if ($osType -eq $ExpectedOsType.Trim().ToLowerInvariant()) {
            return [pscustomobject]@{
              Context = $ContextName
              OsType = $osType
              Attempt = $attempt
              Mode = $mode
            }
          }
        }
        Start-Sleep -Seconds 2
      } while ((Get-Date).ToUniversalTime() -lt $deadline)

      throw ("Context '{0}' did not reach expected OSType '{1}' within {2}s." -f $ContextName, $ExpectedOsType, $TimeoutSeconds)
    } catch {
      $lastError = $_
      if ($attempt -lt $RetryCount) {
        Start-Sleep -Seconds $RetryDelaySeconds
      }
    }
  }

  throw ("Failed to switch Docker context to '{0}' with expected OSType '{1}' after {2} attempt(s): {3}" -f $ContextName, $ExpectedOsType, $RetryCount, $lastError.Exception.Message)
}

function Resolve-RuntimePaths {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [string]$HeartbeatPath
  )

  $runtimeDirHost = if ([System.IO.Path]::IsPathRooted($RuntimeDir)) {
    [System.IO.Path]::GetFullPath($RuntimeDir)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $RuntimeDir))
  }

  $heartbeatHost = if ([string]::IsNullOrWhiteSpace($HeartbeatPath)) {
    Join-Path $runtimeDirHost 'observer-heartbeat.json'
  } elseif ([System.IO.Path]::IsPathRooted($HeartbeatPath)) {
    [System.IO.Path]::GetFullPath($HeartbeatPath)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $HeartbeatPath))
  }

  return [pscustomobject]@{
    RuntimeDirHost = $runtimeDirHost
    HeartbeatPathHost = $heartbeatHost
    StatePath = (Join-Path $runtimeDirHost 'docker-daemon-state.json')
    LaunchReportPath = (Join-Path $runtimeDirHost 'docker-daemon-launch.json')
    LogsReportPath = (Join-Path $runtimeDirHost 'docker-daemon-logs.json')
    LogsTextPath = (Join-Path $runtimeDirHost 'docker-daemon-logs.txt')
    HealthReportPath = (Join-Path $runtimeDirHost 'docker-daemon-health.json')
    EngineStatePath = (Join-Path $repoRoot 'tests/results/_agent/runtime/docker-daemon-engine.json')
    EngineLockPath = (Join-Path $repoRoot 'tests/results/_agent/runtime/docker-daemon-engine.lock')
  }
}

function Resolve-HostPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$Path
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Get-ReconcileRuntimeStateFiles {
  param([Parameter(Mandatory)][string]$RootPath)

  if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $RootPath -Recurse -Filter 'docker-daemon-state.json' -File | Sort-Object FullName)
}

function Invoke-ManagerProcess {
  param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  $pwshCommand = Get-Command -Name 'pwsh' -ErrorAction Stop
  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $pwshCommand.Source
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.WorkingDirectory = (Get-Location).Path
  foreach ($token in @('-NoLogo', '-NoProfile', '-File', $ScriptPath) + $Arguments) {
    $null = $startInfo.ArgumentList.Add([string]$token)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  $null = $process.Start()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    Stdout = $stdout
    Stderr = $stderr
  }
}

function Get-ContainerRecord {
  param(
    [Parameter(Mandatory)][string]$DockerCommand,
    [Parameter(Mandatory)][string]$ContainerName
  )

  $inspect = Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('inspect', $ContainerName) -IgnoreExitCode
  if ($inspect.ExitCode -ne 0) {
    return $null
  }

  $parsed = $inspect.Text | ConvertFrom-Json -Depth 30
  $item = @($parsed)[0]
  if (-not $item) {
    return $null
  }

  $name = [string]$item.Name
  if ($name.StartsWith('/')) {
    $name = $name.Substring(1)
  }

  return [ordered]@{
    name = $name
    id = [string]$item.Id
    image = [string]$item.Config.Image
    status = [string]$item.State.Status
    running = [bool]$item.State.Running
    exitCode = if ($null -ne $item.State.ExitCode) { [int]$item.State.ExitCode } else { $null }
    createdAt = [string]$item.Created
    startedAt = [string]$item.State.StartedAt
    finishedAt = [string]$item.State.FinishedAt
    removed = $false
    removedAt = $null
  }
}

function Set-ContainerStateFromRecord {
  param(
    [Parameter(Mandatory)]$State,
    $ContainerRecord
  )

  if ($null -eq $ContainerRecord) {
    $State.container.running = $false
    if (-not $State.container.status) {
      $State.container.status = 'missing'
    }
    return
  }

  $State.container.name = $ContainerRecord.name
  $State.container.id = $ContainerRecord.id
  $State.container.image = $ContainerRecord.image
  $State.container.status = $ContainerRecord.status
  $State.container.running = [bool]$ContainerRecord.running
  $State.container.exitCode = $ContainerRecord.exitCode
  $State.container.createdAt = $ContainerRecord.createdAt
  $State.container.startedAt = $ContainerRecord.startedAt
  $State.container.finishedAt = $ContainerRecord.finishedAt
  $State.container.removed = [bool]$ContainerRecord.removed
  $State.container.removedAt = $ContainerRecord.removedAt
}

function New-BaseState {
  param(
    $ExistingState,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)]$Paths,
    [string]$HeartbeatPath,
    [string]$ContainerName,
    [string]$Image,
    [Parameter(Mandatory)][string]$DockerCommand,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][bool]$Detached,
    [Parameter(Mandatory)][int]$PollIntervalSeconds,
    [Parameter(Mandatory)][int]$MaxCycles
  )

  $state = [ordered]@{
    schema = $StateSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    runtimeAdapter = 'comparevi'
    repository = $Repository
    action = $Action
    outcome = 'pending'
    runtime = @{
      runtimeDir = $RuntimeDir
      runtimeDirHost = $Paths.RuntimeDirHost
      heartbeatPath = if ([string]::IsNullOrWhiteSpace($HeartbeatPath)) { $null } else { $HeartbeatPath }
      heartbeatPathHost = $Paths.HeartbeatPathHost
      heartbeatExists = (Test-Path -LiteralPath $Paths.HeartbeatPathHost -PathType Leaf)
    }
    container = @{
      name = $ContainerName
      image = $Image
      id = $null
      status = if ($Action -eq 'start') { 'planned' } else { 'unknown' }
      running = $false
      exitCode = $null
      createdAt = $null
      startedAt = $null
      finishedAt = $null
      removed = $false
      removedAt = $null
    }
    launch = @{
      detached = $Detached
      foreground = (-not $Detached)
      pollIntervalSeconds = $PollIntervalSeconds
      maxCycles = $MaxCycles
      command = @()
    }
    docker = @{
      command = $DockerCommand
      os = $null
      context = @{
        requested = $LinuxContext
        active = $null
        previous = $null
        mode = $null
        switched = $false
        attempt = 0
      }
    }
    engine = @{
      requiredOs = 'linux'
      lockPath = $Paths.EngineLockPath
      lockAcquired = $false
    }
    artifacts = @{
      statePath = $Paths.StatePath
      launchReportPath = $Paths.LaunchReportPath
      logsReportPath = $Paths.LogsReportPath
      logsTextPath = $Paths.LogsTextPath
      healthReportPath = $Paths.HealthReportPath
      engineStatePath = $Paths.EngineStatePath
    }
    lastLogs = if ($ExistingState -and $ExistingState.PSObject.Properties['lastLogs']) { $ExistingState.lastLogs } else { $null }
    health = if ($ExistingState -and $ExistingState.PSObject.Properties['health']) { $ExistingState.health } else { $null }
    lastAction = $null
  }

  if ($ExistingState -and $ExistingState.PSObject.Properties['container']) {
    $state.container.name = if ($ContainerName) { $ContainerName } elseif ($ExistingState.container.name) { [string]$ExistingState.container.name } else { $ContainerName }
    $state.container.image = if ($Image) { $Image } elseif ($ExistingState.container.image) { [string]$ExistingState.container.image } else { $Image }
    foreach ($field in @('id', 'status', 'running', 'exitCode', 'createdAt', 'startedAt', 'finishedAt', 'removed', 'removedAt')) {
      if ($ExistingState.container.PSObject.Properties[$field]) {
        $state.container[$field] = $ExistingState.container.$field
      }
    }
  }
  if ($ExistingState -and $ExistingState.PSObject.Properties['docker'] -and $ExistingState.docker.PSObject.Properties['context']) {
    foreach ($field in @('requested', 'active', 'previous', 'mode', 'switched', 'attempt')) {
      if ($ExistingState.docker.context.PSObject.Properties[$field]) {
        $state.docker.context[$field] = $ExistingState.docker.context.$field
      }
    }
  }
  if ($ExistingState -and $ExistingState.PSObject.Properties['engine']) {
    foreach ($field in @('requiredOs', 'lockPath', 'lockAcquired')) {
      if ($ExistingState.engine.PSObject.Properties[$field]) {
        $state.engine[$field] = $ExistingState.engine.$field
      }
    }
  }

  return $state
}

function New-BaseReport {
  param(
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)]$Paths,
    [Parameter(Mandatory)][string]$ContainerName
  )

  return [ordered]@{
    schema = $ReportSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    action = $Action
    repository = $Repository
    containerName = if ([string]::IsNullOrWhiteSpace($ContainerName)) { $null } else { $ContainerName }
    status = 'pass'
    outcome = 'pending'
    artifacts = @{
      statePath = $Paths.StatePath
      launchReportPath = $Paths.LaunchReportPath
      logsReportPath = $Paths.LogsReportPath
      logsTextPath = $Paths.LogsTextPath
      healthReportPath = $Paths.HealthReportPath
      heartbeatPath = $Paths.HeartbeatPathHost
      engineStatePath = $Paths.EngineStatePath
    }
  }
}

function Update-StateMetadata {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)][string]$Action,
    [Parameter(Mandatory)][string]$Outcome
  )

  $timestamp = (Get-Date).ToUniversalTime().ToString('o')
  $State.generatedAt = $timestamp
  $State.action = $Action
  $State.outcome = $Outcome
  $State.runtime.heartbeatExists = (Test-Path -LiteralPath $State.runtime.heartbeatPathHost -PathType Leaf)
  $State.lastAction = @{
    action = $Action
    generatedAt = $timestamp
    outcome = $Outcome
  }
}

function Capture-ContainerLogs {
  param(
    [Parameter(Mandatory)][string]$DockerCommand,
    [Parameter(Mandatory)][string]$ContainerName,
    [Parameter(Mandatory)][int]$TailLines,
    [Parameter(Mandatory)]$Paths,
    [switch]$IgnoreExitCode
  )

  $result = Invoke-DockerCommand `
    -DockerCommand $DockerCommand `
    -Arguments @('logs', '--tail', "$TailLines", $ContainerName) `
    -IgnoreExitCode:$IgnoreExitCode

  $logReport = [ordered]@{
    schema = $LogsSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    containerName = $ContainerName
    tailLines = $TailLines
    exitCode = $result.ExitCode
    lineCount = $result.Lines.Count
    outcome = if ($result.ExitCode -eq 0) { 'captured' } else { 'missing' }
    artifacts = @{
      logsReportPath = $Paths.LogsReportPath
      logsTextPath = $Paths.LogsTextPath
    }
    lines = $result.Lines
  }

  if ($result.ExitCode -eq 0) {
    Write-TextFile -Path $Paths.LogsTextPath -Lines $result.Lines
  }
  Write-JsonFile -Path $Paths.LogsReportPath -Payload $logReport
  return $logReport
}

function ConvertTo-UtcDateTime {
  param($Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    return [datetime]::Parse(
      [string]$Value,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
  } catch {
    return $null
  }
}

function Get-ContainerHealthReport {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$Paths,
    $ContainerRecord,
    [Parameter(Mandatory)][int]$HeartbeatFreshSeconds,
    [Parameter(Mandatory)][int]$StartGraceSeconds
  )

  $now = (Get-Date).ToUniversalTime()
  $heartbeat = Read-JsonFile -Path $Paths.HeartbeatPathHost
  $heartbeatGeneratedAt = if ($heartbeat -and $heartbeat.PSObject.Properties['generatedAt']) {
    ConvertTo-UtcDateTime -Value $heartbeat.generatedAt
  } else {
    $null
  }
  $startedAt = if ($ContainerRecord) { ConvertTo-UtcDateTime -Value $ContainerRecord.startedAt } else { $null }
  $heartbeatMatchesCurrentRun = -not ($heartbeatGeneratedAt -and $startedAt -and $heartbeatGeneratedAt -lt $startedAt)
  $heartbeatAgeSeconds = if ($heartbeatGeneratedAt) {
    [math]::Max(0, [int][math]::Floor(($now - $heartbeatGeneratedAt).TotalSeconds))
  } else {
    $null
  }
  $runtimeAgeSeconds = if ($startedAt) {
    [math]::Max(0, [int][math]::Floor(($now - $startedAt).TotalSeconds))
  } else {
    $null
  }

  $status = 'unknown'
  $reason = 'container-state-unavailable'
  if ($null -eq $ContainerRecord -or -not $ContainerRecord.running) {
    $status = 'not-running'
    $reason = 'container-not-running'
  } elseif ($heartbeatGeneratedAt -and $heartbeatMatchesCurrentRun -and $heartbeatAgeSeconds -le $HeartbeatFreshSeconds) {
    $status = 'healthy'
    $reason = 'heartbeat-fresh'
  } elseif ($heartbeatGeneratedAt -and $heartbeatMatchesCurrentRun) {
    $status = 'stale'
    $reason = 'heartbeat-stale'
  } elseif ($runtimeAgeSeconds -ne $null -and $runtimeAgeSeconds -le $StartGraceSeconds) {
    $status = 'healthy'
    $reason = 'startup-grace-window'
  } else {
    $status = 'wedged'
    $reason = if ($heartbeat -and -not $heartbeatMatchesCurrentRun) { 'heartbeat-precedes-container-start' } elseif ($heartbeat) { 'heartbeat-invalid' } else { 'heartbeat-missing' }
  }

  $report = [ordered]@{
    schema = $HealthSchema
    generatedAt = $now.ToString('o')
    repository = $State.repository
    containerName = if ($ContainerRecord) { $ContainerRecord.name } else { $State.container.name }
    status = $status
    reason = $reason
    heartbeatFreshSeconds = $HeartbeatFreshSeconds
    startGraceSeconds = $StartGraceSeconds
    heartbeat = @{
      path = $Paths.HeartbeatPathHost
      present = [bool]$heartbeat
      generatedAt = if ($heartbeatGeneratedAt) { $heartbeatGeneratedAt.ToString('o') } else { $null }
      ageSeconds = $heartbeatAgeSeconds
      matchesCurrentRun = $heartbeatMatchesCurrentRun
      cyclesCompleted = if ($heartbeat -and $heartbeat.PSObject.Properties['cyclesCompleted']) { $heartbeat.cyclesCompleted } else { $null }
      outcome = if ($heartbeat -and $heartbeat.PSObject.Properties['outcome']) { $heartbeat.outcome } else { $null }
      stopRequested = if ($heartbeat -and $heartbeat.PSObject.Properties['stopRequested']) { [bool]$heartbeat.stopRequested } else { $null }
    }
    container = @{
      running = if ($ContainerRecord) { [bool]$ContainerRecord.running } else { $false }
      status = if ($ContainerRecord) { $ContainerRecord.status } else { $State.container.status }
      startedAt = if ($startedAt) { $startedAt.ToString('o') } else { $null }
      runtimeAgeSeconds = $runtimeAgeSeconds
    }
  }

  $State.health = $report
  Write-JsonFile -Path $Paths.HealthReportPath -Payload $report
  return $report
}

if ($PollIntervalSeconds -lt 0) {
  throw '-PollIntervalSeconds must be zero or greater.'
}
if ($HeartbeatFreshSeconds -le 0) {
  throw '-HeartbeatFreshSeconds must be greater than zero.'
}
if ($StartGraceSeconds -le 0) {
  throw '-StartGraceSeconds must be greater than zero.'
}
if ($MaxCycles -lt 0) {
  throw '-MaxCycles must be zero or greater.'
}
if ($TailLines -le 0) {
  throw '-TailLines must be greater than zero.'
}

$repoRoot = (Resolve-Path -LiteralPath '.').Path
if ($Action -eq 'reconcile') {
  $reconcileRootHost = Resolve-HostPath -RepoRoot $repoRoot -Path $ReconcileRoot
  $reconcileArtifactRoot = if ((Split-Path -Leaf $reconcileRootHost).Trim().ToLowerInvariant() -eq 'runtime') {
    $reconcileRootHost
  } else {
    Join-Path $reconcileRootHost 'runtime'
  }
  $reconcileReportPath = Join-Path $reconcileArtifactRoot 'docker-daemon-reconcile.json'
  $stateFiles = Get-ReconcileRuntimeStateFiles -RootPath $reconcileRootHost
  $scriptPath = if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
    throw 'Unable to resolve the current script path for reconcile.'
  } else {
    $PSCommandPath
  }
  $summary = [ordered]@{
    discovered = $stateFiles.Count
    attempted = 0
    healthy = 0
    repaired = 0
    blocked = 0
    dryRun = 0
    notRunning = 0
    stale = 0
    wedged = 0
    unknown = 0
  }
  $lanes = [System.Collections.Generic.List[object]]::new()

  foreach ($stateFile in $stateFiles) {
    $summary.attempted += 1
    $laneState = Read-JsonFile -Path $stateFile.FullName
    if (-not $laneState) {
      $summary.blocked += 1
      $summary.unknown += 1
      $lanes.Add([ordered]@{
        statePath = $stateFile.FullName
        status = 'blocked'
        outcome = 'invalid-state'
        repaired = $false
        healthStatus = $null
        priorHealthStatus = $null
        repository = $null
        runtimeDir = Split-Path -Parent $stateFile.FullName
        containerName = $null
        image = $null
        childExitCode = 1
        message = 'Unable to parse docker-daemon-state.json.'
      })
      continue
    }

    $laneRuntimeDir = if (
      $laneState.PSObject.Properties['runtime'] -and
      $laneState.runtime -and
      $laneState.runtime.PSObject.Properties['runtimeDirHost'] -and
      -not [string]::IsNullOrWhiteSpace([string]$laneState.runtime.runtimeDirHost)
    ) {
      [string]$laneState.runtime.runtimeDirHost
    } else {
      Split-Path -Parent $stateFile.FullName
    }

    $laneHeartbeatPath = if (
      $laneState.PSObject.Properties['runtime'] -and
      $laneState.runtime -and
      $laneState.runtime.PSObject.Properties['heartbeatPathHost'] -and
      -not [string]::IsNullOrWhiteSpace([string]$laneState.runtime.heartbeatPathHost)
    ) {
      [string]$laneState.runtime.heartbeatPathHost
    } else {
      Join-Path $laneRuntimeDir 'observer-heartbeat.json'
    }

    $laneRepository = if (
      $laneState.PSObject.Properties['repository'] -and
      -not [string]::IsNullOrWhiteSpace([string]$laneState.repository)
    ) {
      [string]$laneState.repository
    } elseif (-not [string]::IsNullOrWhiteSpace($Repo)) {
      $Repo.Trim()
    } else {
      'unknown/unknown'
    }

    $laneContainerName = if (
      $laneState.PSObject.Properties['container'] -and
      $laneState.container -and
      $laneState.container.PSObject.Properties['name'] -and
      -not [string]::IsNullOrWhiteSpace([string]$laneState.container.name)
    ) {
      [string]$laneState.container.name
    } else {
      $null
    }

    $laneImage = if (
      $laneState.PSObject.Properties['container'] -and
      $laneState.container -and
      $laneState.container.PSObject.Properties['image'] -and
      -not [string]::IsNullOrWhiteSpace([string]$laneState.container.image)
    ) {
      [string]$laneState.container.image
    } elseif (-not [string]::IsNullOrWhiteSpace($Image)) {
      $Image.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_TOOLS_IMAGE)) {
      $env:COMPAREVI_TOOLS_IMAGE.Trim()
    } else {
      'ghcr.io/labview-community-ci-cd/comparevi-tools:latest'
    }

    $priorHealthReportPath = Join-Path $laneRuntimeDir 'docker-daemon-health.json'
    $priorHealth = Read-JsonFile -Path $priorHealthReportPath
    if (-not $priorHealth -and $laneState.PSObject.Properties['health']) {
      $priorHealth = $laneState.health
    }
    $priorHealthStatus = if (
      $priorHealth -and
      $priorHealth.PSObject.Properties['status'] -and
      -not [string]::IsNullOrWhiteSpace([string]$priorHealth.status)
    ) {
      [string]$priorHealth.status
    } else {
      $null
    }

    if ([string]::IsNullOrWhiteSpace($laneContainerName)) {
      $summary.blocked += 1
      $summary.unknown += 1
      $lanes.Add([ordered]@{
        statePath = $stateFile.FullName
        status = 'blocked'
        outcome = 'missing-container-name'
        repaired = $false
        healthStatus = $null
        priorHealthStatus = $priorHealthStatus
        repository = $laneRepository
        runtimeDir = $laneRuntimeDir
        containerName = $null
        image = $laneImage
        childExitCode = 1
        message = 'Persisted lane state is missing container.name.'
      })
      continue
    }

    $childArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($token in @(
        '-Action', 'start',
        '-Repo', $laneRepository,
        '-RuntimeDir', $laneRuntimeDir,
        '-ContainerName', $laneContainerName,
        '-Image', $laneImage,
        '-LinuxContext', $LinuxContext,
        '-HeartbeatFreshSeconds', "$HeartbeatFreshSeconds",
        '-StartGraceSeconds', "$StartGraceSeconds",
        '-PollIntervalSeconds', "$PollIntervalSeconds",
        '-MaxCycles', "$MaxCycles",
        '-TailLines', "$TailLines",
        '-SwitchTimeoutSeconds', "$SwitchTimeoutSeconds",
        '-SwitchRetryCount', "$SwitchRetryCount",
        '-SwitchRetryDelaySeconds', "$SwitchRetryDelaySeconds",
        '-LockWaitSeconds', "$LockWaitSeconds",
        '-DockerCommand', $DockerCommand
      )) {
      $null = $childArgs.Add($token)
    }
    if (-not [string]::IsNullOrWhiteSpace($laneHeartbeatPath)) {
      $null = $childArgs.Add('-HeartbeatPath')
      $null = $childArgs.Add($laneHeartbeatPath)
    }
    if ($DryRun) {
      $null = $childArgs.Add('-DryRun')
    }

    $childResult = Invoke-ManagerProcess -ScriptPath $scriptPath -Arguments $childArgs.ToArray()
    $childReport = $null
    $parseError = $null
    if (-not [string]::IsNullOrWhiteSpace($childResult.Stdout)) {
      try {
        $childReport = $childResult.Stdout | ConvertFrom-Json -Depth 40 -ErrorAction Stop
      } catch {
        $parseError = $_.Exception.Message
      }
    } else {
      $parseError = 'child process produced no JSON output'
    }

    $laneStatus = if ($childReport -and $childReport.PSObject.Properties['status']) {
      [string]$childReport.status
    } elseif ($childResult.ExitCode -eq 0) {
      'pass'
    } else {
      'blocked'
    }
    $laneOutcome = if ($childReport -and $childReport.PSObject.Properties['outcome']) {
      [string]$childReport.outcome
    } elseif ($childResult.ExitCode -eq 0) {
      'unknown'
    } else {
      'reconcile-child-failed'
    }
    $laneHealthStatus = if (
      $childReport -and
      $childReport.PSObject.Properties['health'] -and
      $childReport.health -and
      $childReport.health.PSObject.Properties['status']
    ) {
      [string]$childReport.health.status
    } elseif (
      $childReport -and
      $childReport.PSObject.Properties['state'] -and
      $childReport.state -and
      $childReport.state.PSObject.Properties['health'] -and
      $childReport.state.health -and
      $childReport.state.health.PSObject.Properties['status']
    ) {
      [string]$childReport.state.health.status
    } else {
      $null
    }
    $repaired = ($laneOutcome -eq 'started') -or ($laneOutcome -like 'restarted-*')

    switch ($laneHealthStatus) {
      'healthy' { $summary.healthy += 1 }
      'not-running' { $summary.notRunning += 1 }
      'stale' { $summary.stale += 1 }
      'wedged' { $summary.wedged += 1 }
      default { $summary.unknown += 1 }
    }

    if ($repaired) {
      $summary.repaired += 1
    }
    if ($laneStatus -eq 'blocked' -or $childResult.ExitCode -ne 0 -or $parseError) {
      $summary.blocked += 1
    }
    if ($laneOutcome -eq 'dry-run') {
      $summary.dryRun += 1
    }

    $laneMessage = if ($parseError) {
      "Failed to parse child report: $parseError"
    } elseif (-not [string]::IsNullOrWhiteSpace($childResult.Stderr)) {
      $childResult.Stderr.Trim()
    } elseif ($childReport -and $childReport.PSObject.Properties['message']) {
      [string]$childReport.message
    } else {
      $null
    }

    $lanes.Add([ordered]@{
      statePath = $stateFile.FullName
      status = $laneStatus
      outcome = $laneOutcome
      repaired = $repaired
      healthStatus = $laneHealthStatus
      priorHealthStatus = $priorHealthStatus
      repository = $laneRepository
      runtimeDir = $laneRuntimeDir
      containerName = $laneContainerName
      image = $laneImage
      childExitCode = [int]$childResult.ExitCode
      message = $laneMessage
      artifacts = if ($childReport -and $childReport.PSObject.Properties['artifacts']) { $childReport.artifacts } else { $null }
    })
  }

  $reconcileReport = [ordered]@{
    schema = $ReconcileSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    action = 'reconcile'
    status = if ($summary.blocked -gt 0) { 'blocked' } elseif ($DryRun) { 'planned' } else { 'pass' }
    outcome = if ($summary.discovered -eq 0) {
      'no-runtime-lanes'
    } elseif ($summary.blocked -gt 0) {
      'reconcile-blocked'
    } elseif ($DryRun) {
      'dry-run'
    } else {
      'reconciled'
    }
    reconcileRoot = $reconcileRootHost
    artifacts = @{
      reconcileReportPath = $reconcileReportPath
    }
    summary = $summary
    lanes = $lanes
  }

  Write-JsonFile -Path $reconcileReportPath -Payload $reconcileReport
  $reconcileReport | ConvertTo-Json -Depth 20
  if ($summary.blocked -gt 0) {
    exit 1
  }
  return
}
$paths = Resolve-RuntimePaths -RepoRoot $repoRoot -RuntimeDir $RuntimeDir -HeartbeatPath $HeartbeatPath
$existingState = Read-JsonFile -Path $paths.StatePath

$repository = if (-not [string]::IsNullOrWhiteSpace($Repo)) {
  $Repo.Trim()
} elseif ($existingState -and $existingState.PSObject.Properties['repository'] -and $existingState.repository) {
  [string]$existingState.repository
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
  $env:GITHUB_REPOSITORY.Trim()
} else {
  'unknown/unknown'
}

$resolvedImage = if (-not [string]::IsNullOrWhiteSpace($Image)) {
  $Image.Trim()
} elseif ($existingState -and $existingState.PSObject.Properties['container'] -and $existingState.container.image) {
  [string]$existingState.container.image
} elseif (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_TOOLS_IMAGE)) {
  $env:COMPAREVI_TOOLS_IMAGE.Trim()
} else {
  'ghcr.io/labview-community-ci-cd/comparevi-tools:latest'
}

$resolvedContainerName = if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
  $ContainerName.Trim()
} elseif ($existingState -and $existingState.PSObject.Properties['container'] -and $existingState.container.name) {
  [string]$existingState.container.name
} elseif ($Action -eq 'start') {
  "comparevi-runtime-daemon-$((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss'))"
} else {
  ''
}

$detached = -not [bool]$Foreground
$state = New-BaseState `
  -ExistingState $existingState `
  -Repository $repository `
  -RuntimeDir $RuntimeDir `
  -Paths $paths `
  -HeartbeatPath $HeartbeatPath `
  -ContainerName $resolvedContainerName `
  -Image $resolvedImage `
  -DockerCommand $DockerCommand `
  -Action $Action `
  -Detached $detached `
  -PollIntervalSeconds $PollIntervalSeconds `
  -MaxCycles $MaxCycles
$report = New-BaseReport -Action $Action -Repository $repository -Paths $paths -ContainerName $resolvedContainerName

function Finalize-And-Emit {
  param(
    [Parameter(Mandatory)]$State,
    [Parameter(Mandatory)]$Report
  )

  if ($null -ne $State.engine) {
    $State.engine.lockAcquired = $false
  }
  Write-JsonFile -Path $State.artifacts.statePath -Payload $State
  Write-JsonFile -Path $State.artifacts.engineStatePath -Payload ([ordered]@{
    schema = $EngineSchema
    generatedAt = $State.generatedAt
    repository = $State.repository
    requiredOs = $State.engine.requiredOs
    lockPath = $State.engine.lockPath
    lockAcquired = $State.engine.lockAcquired
    docker = @{
      command = $State.docker.command
      os = $State.docker.os
      context = $State.docker.context
    }
  })
  $Report.state = $State
  $Report | ConvertTo-Json -Depth 20
}

if ($DryRun) {
  $report.status = 'planned'
  $report.outcome = 'dry-run'
  $report.engine = @{
    requiredOs = 'linux'
    context = $LinuxContext
    lockPath = $paths.EngineLockPath
    mode = 'planned'
  }
  Update-StateMetadata -State $state -Action $Action -Outcome 'dry-run'

  if ($Action -eq 'start') {
    $report.launch = @{
      detached = $detached
      foreground = (-not $detached)
    }
    Write-JsonFile -Path $paths.LaunchReportPath -Payload $report
  } elseif ($Action -eq 'logs') {
    Write-JsonFile -Path $paths.LogsReportPath -Payload @{
      schema = $LogsSchema
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      containerName = if ([string]::IsNullOrWhiteSpace($resolvedContainerName)) { $null } else { $resolvedContainerName }
      tailLines = $TailLines
      exitCode = $null
      lineCount = 0
      outcome = 'dry-run'
      artifacts = @{
        logsReportPath = $paths.LogsReportPath
        logsTextPath = $paths.LogsTextPath
      }
      lines = @()
    }
  }

  Finalize-And-Emit -State $state -Report $report
  return
}

if (-not (Get-Command -Name $DockerCommand -ErrorAction SilentlyContinue)) {
  throw ("Docker command not found: {0}" -f $DockerCommand)
}

$engineLock = $null
try {
  $engineLock = Acquire-LockStream -LockPath $paths.EngineLockPath -WaitSeconds $LockWaitSeconds
  $state.engine.lockAcquired = $true
  $previousContext = Get-CurrentDockerContext -DockerCommand $DockerCommand
  $contextResult = Set-ContextAndWait `
    -DockerCommand $DockerCommand `
    -ContextName $LinuxContext `
    -ExpectedOsType 'linux' `
    -TimeoutSeconds $SwitchTimeoutSeconds `
    -RetryCount $SwitchRetryCount `
    -RetryDelaySeconds $SwitchRetryDelaySeconds
  $state.docker.os = $contextResult.OsType
  $state.docker.context.previous = if ([string]::IsNullOrWhiteSpace($previousContext)) { $null } else { $previousContext }
  $state.docker.context.active = $contextResult.Context
  $state.docker.context.mode = $contextResult.Mode
  $state.docker.context.attempt = $contextResult.Attempt
  $state.docker.context.switched = [bool]([string]::IsNullOrWhiteSpace($previousContext) -or $previousContext -ne $contextResult.Context -or $contextResult.Mode -ne 'context-use')
  $report.docker = @{
    command = $DockerCommand
    os = $contextResult.OsType
    context = $state.docker.context
  }
  $report.engine = @{
    requiredOs = 'linux'
    lockPath = $paths.EngineLockPath
    context = $LinuxContext
  }

  switch ($Action) {
  'start' {
    $hostPath = Get-DockerHostPath -Path $repoRoot
    $containerArgs = @(
      'node',
      'tools/priority/runtime-daemon.mjs',
      '--repo',
      $repository,
      '--runtime-dir',
      $RuntimeDir,
      '--poll-interval-seconds',
      "$PollIntervalSeconds",
      '--max-cycles',
      "$MaxCycles"
    )
    if ($StopOnIdle) {
      $containerArgs += '--stop-on-idle'
    }
    if ($ExecuteTurn) {
      $containerArgs += '--execute-turn'
    }
    if (-not [string]::IsNullOrWhiteSpace($HeartbeatPath)) {
      $containerArgs += @('--heartbeat-path', $HeartbeatPath)
    }

    $dockerArgs = @(
      'run',
      '--name',
      $resolvedContainerName,
      '--label',
      'comparevi.runtime.daemon=1',
      '--label',
      ("comparevi.runtime.dir={0}" -f $RuntimeDir),
      '-v',
      ('{0}:/work' -f $hostPath),
      '-w',
      '/work'
    )

    foreach ($key in @('GH_TOKEN', 'GITHUB_TOKEN', 'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy')) {
      $value = [Environment]::GetEnvironmentVariable($key)
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $dockerArgs += @('-e', ('{0}={1}' -f $key, $value))
      }
    }

    $resolvedGitHubToken = Resolve-GitHubToken
    if (-not [string]::IsNullOrWhiteSpace($resolvedGitHubToken)) {
      $dockerArgs += @('-e', "GH_TOKEN=$resolvedGitHubToken")
      $dockerArgs += @('-e', "GITHUB_TOKEN=$resolvedGitHubToken")
    }

    if ($detached) {
      $dockerArgs += '--detach'
    }

    $dockerArgs += @($resolvedImage)
    $dockerArgs += $containerArgs

    $state.launch.command = @($DockerCommand) + (Get-DisplayDockerArgs -Arguments $dockerArgs)
    $staleRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
    if ($staleRecord) {
      if ($staleRecord.running) {
        Set-ContainerStateFromRecord -State $state -ContainerRecord $staleRecord
        $health = Get-ContainerHealthReport `
          -State $state `
          -Paths $paths `
          -ContainerRecord $staleRecord `
          -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
          -StartGraceSeconds $StartGraceSeconds
        $report.health = $health
        if ($health.status -eq 'healthy') {
          $report.outcome = 'already-running'
          $report.containerId = $staleRecord.id
          Update-StateMetadata -State $state -Action $Action -Outcome 'already-running'
          Write-JsonFile -Path $paths.LaunchReportPath -Payload $report
          Finalize-And-Emit -State $state -Report $report
          return
        }
        $restartLogs = Capture-ContainerLogs `
          -DockerCommand $DockerCommand `
          -ContainerName $resolvedContainerName `
          -TailLines $TailLines `
          -Paths $paths `
          -IgnoreExitCode
        $state.lastLogs = @{
          generatedAt = $restartLogs.generatedAt
          tailLines = $TailLines
          logPath = $paths.LogsTextPath
          lineCount = $restartLogs.lineCount
          outcome = $restartLogs.outcome
        }
        Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('stop', $resolvedContainerName) -IgnoreExitCode | Out-Null
        Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('rm', '-f', $resolvedContainerName) -IgnoreExitCode | Out-Null
        $report.restart = @{
          reason = $health.status
          priorHealth = $health
          priorLogs = $restartLogs
        }
      }
      elseif (-not $staleRecord.running) {
        Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('rm', '-f', $resolvedContainerName) -IgnoreExitCode | Out-Null
      }
    }

    $runResult = Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments $dockerArgs
    $containerRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
    Set-ContainerStateFromRecord -State $state -ContainerRecord $containerRecord
    $health = Get-ContainerHealthReport `
      -State $state `
      -Paths $paths `
      -ContainerRecord $containerRecord `
      -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
      -StartGraceSeconds $StartGraceSeconds
    $report.health = $health
    if ($report.Contains('restart')) {
      $report.outcome = "restarted-$($report.restart.reason)"
    } else {
      $report.outcome = if ($detached) { 'started' } else { 'exited' }
    }
    $report.docker.output = $runResult.Lines
    $report.containerId = if ($containerRecord) { $containerRecord.id } else { $null }
    Update-StateMetadata -State $state -Action $Action -Outcome $report.outcome
    Write-JsonFile -Path $paths.LaunchReportPath -Payload $report
    Finalize-And-Emit -State $state -Report $report
    return
  }
  'status' {
    if ([string]::IsNullOrWhiteSpace($resolvedContainerName)) {
      $report.outcome = 'not-started'
      Update-StateMetadata -State $state -Action $Action -Outcome 'not-started'
      Finalize-And-Emit -State $state -Report $report
      return
    }

    $containerRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
    if ($containerRecord) {
      Set-ContainerStateFromRecord -State $state -ContainerRecord $containerRecord
      $report.outcome = $containerRecord.status
      $report.health = Get-ContainerHealthReport `
        -State $state `
        -Paths $paths `
        -ContainerRecord $containerRecord `
        -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
        -StartGraceSeconds $StartGraceSeconds
    } else {
      $state.container.status = if ($state.container.removed) { 'removed' } else { 'missing' }
      $state.container.running = $false
      $report.outcome = $state.container.status
      $report.health = Get-ContainerHealthReport `
        -State $state `
        -Paths $paths `
        -ContainerRecord $null `
        -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
        -StartGraceSeconds $StartGraceSeconds
    }

    Update-StateMetadata -State $state -Action $Action -Outcome $report.outcome
    Finalize-And-Emit -State $state -Report $report
    return
  }
  'logs' {
    if ([string]::IsNullOrWhiteSpace($resolvedContainerName)) {
      $report.outcome = 'not-started'
      Update-StateMetadata -State $state -Action $Action -Outcome 'not-started'
      Finalize-And-Emit -State $state -Report $report
      return
    }

    $logReport = Capture-ContainerLogs `
      -DockerCommand $DockerCommand `
      -ContainerName $resolvedContainerName `
      -TailLines $TailLines `
      -Paths $paths `
      -IgnoreExitCode
    $state.lastLogs = @{
      generatedAt = $logReport.generatedAt
      tailLines = $TailLines
      logPath = $paths.LogsTextPath
      lineCount = $logReport.lineCount
      outcome = $logReport.outcome
    }
    $containerRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
    if ($containerRecord) {
      Set-ContainerStateFromRecord -State $state -ContainerRecord $containerRecord
    }
    $report.health = Get-ContainerHealthReport `
      -State $state `
      -Paths $paths `
      -ContainerRecord $containerRecord `
      -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
      -StartGraceSeconds $StartGraceSeconds
    $report.outcome = $logReport.outcome
    $report.logs = $logReport
    Update-StateMetadata -State $state -Action $Action -Outcome $logReport.outcome
    Finalize-And-Emit -State $state -Report $report
    return
  }
  'stop' {
    if ([string]::IsNullOrWhiteSpace($resolvedContainerName)) {
      $report.outcome = 'not-started'
      Update-StateMetadata -State $state -Action $Action -Outcome 'not-started'
      Finalize-And-Emit -State $state -Report $report
      return
    }

    $containerRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
    if (-not $containerRecord) {
      $state.container.status = if ($state.container.removed) { 'removed' } else { 'missing' }
      $state.container.running = $false
      $report.outcome = $state.container.status
      Update-StateMetadata -State $state -Action $Action -Outcome $report.outcome
      Finalize-And-Emit -State $state -Report $report
      return
    }

    $logReport = Capture-ContainerLogs `
      -DockerCommand $DockerCommand `
      -ContainerName $resolvedContainerName `
      -TailLines $TailLines `
      -Paths $paths `
      -IgnoreExitCode
    $state.lastLogs = @{
      generatedAt = $logReport.generatedAt
      tailLines = $TailLines
      logPath = $paths.LogsTextPath
      lineCount = $logReport.lineCount
      outcome = $logReport.outcome
    }

    if ($containerRecord.running) {
      Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('stop', $resolvedContainerName) | Out-Null
    }

    if ($RemoveOnStop) {
      Invoke-DockerCommand -DockerCommand $DockerCommand -Arguments @('rm', '-f', $resolvedContainerName) | Out-Null
      $state.container.status = 'removed'
      $state.container.running = $false
      $state.container.removed = $true
      $state.container.removedAt = (Get-Date).ToUniversalTime().ToString('o')
      $report.outcome = 'removed'
    } else {
      $containerRecord = Get-ContainerRecord -DockerCommand $DockerCommand -ContainerName $resolvedContainerName
      Set-ContainerStateFromRecord -State $state -ContainerRecord $containerRecord
      $report.outcome = if ($containerRecord) { $containerRecord.status } else { 'stopped' }
    }

    $report.logs = $logReport
    $report.health = Get-ContainerHealthReport `
      -State $state `
      -Paths $paths `
      -ContainerRecord $null `
      -HeartbeatFreshSeconds $HeartbeatFreshSeconds `
      -StartGraceSeconds $StartGraceSeconds
    Update-StateMetadata -State $state -Action $Action -Outcome $report.outcome
    Finalize-And-Emit -State $state -Report $report
    return
  }
}
} catch {
  $report.status = 'blocked'
  $report.outcome = 'context-acquire-failed'
  $report.message = $_.Exception.Message
  Update-StateMetadata -State $state -Action $Action -Outcome 'context-acquire-failed'
  Finalize-And-Emit -State $state -Report $report
  exit 1
} finally {
  if ($engineLock) {
    try {
      $engineLock.Dispose()
    } catch {
    }
  }
}
