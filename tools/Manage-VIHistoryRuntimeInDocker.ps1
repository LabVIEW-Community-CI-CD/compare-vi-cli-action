#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('start', 'status', 'logs', 'stop', 'reconcile')]
  [string]$Action = 'start',
  [string]$RepoRoot = '.',
  [string]$ResultsRoot = 'tests/results/local-vi-history/warm-dev',
  [string]$RuntimeDir = 'tests/results/local-vi-history/runtime',
  [string]$Image = 'comparevi-vi-history-dev:local',
  [string]$ContainerName = '',
  [ValidateRange(0, 8)]
  [int]$HeavyExecutionParallelism = 0,
  [string]$HostRamBudgetPath = '',
  [ValidateSet('heavy', 'windows-mirror-heavy')]
  [string]$HostRamBudgetTargetProfile = 'heavy',
  [Nullable[long]]$HostRamBudgetTotalBytes = $null,
  [Nullable[long]]$HostRamBudgetFreeBytes = $null,
  [Nullable[int]]$HostRamBudgetCpuParallelism = $null,
  [ValidateRange(5, 900)]
  [int]$HeartbeatFreshSeconds = 180,
  [ValidateRange(1, 600)]
  [int]$LockWaitSeconds = 90,
  [ValidateRange(10, 2000)]
  [int]$TailLines = 200,
  [bool]$RemoveOnStop = $true,
  [string]$DockerCommand = 'docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostRamBudget.psm1') -Force

$stateSchema = 'comparevi/local-runtime-state@v1'
$leaseSchema = 'comparevi/local-runtime-lease@v1'
$healthSchema = 'comparevi/local-runtime-health@v1'
$logsSchema = 'comparevi/local-runtime-logs@v1'
$heartbeatSchema = 'comparevi/local-runtime-heartbeat@v1'

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Payload
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $Payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
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

function Write-TextFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$Lines
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  ($Lines -join [Environment]::NewLine) | Set-Content -LiteralPath $Path -Encoding utf8
}

function Acquire-LockStream {
  param(
    [Parameter(Mandatory)][string]$LockPath,
    [ValidateRange(1, 600)][int]$WaitSeconds
  )

  $lockDir = Split-Path -Parent $LockPath
  if (-not [string]::IsNullOrWhiteSpace($lockDir) -and -not (Test-Path -LiteralPath $lockDir -PathType Container)) {
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
  }

  $deadline = (Get-Date).ToUniversalTime().AddSeconds($WaitSeconds)
  do {
    try {
      return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
      Start-Sleep -Seconds 2
    }
  } while ((Get-Date).ToUniversalTime() -lt $deadline)

  throw ("Timed out waiting for VI history runtime lock: {0}" -f $LockPath)
}

function Invoke-Docker {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $raw = & $DockerCommand @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $lines = @($raw | ForEach-Object { [string]$_ })
  $text = ($lines -join "`n")

  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    throw ("docker {0} failed (exit={1}). Output: {2}" -f ($Arguments -join ' '), $exitCode, $text)
  }

  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    Lines = $lines
    Text = $text
  }
}

function Get-OwnerStamp {
  $user = if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) { $env:USERNAME } else { 'unknown-user' }
  $hostName = if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) { $env:COMPUTERNAME } else { 'unknown-host' }
  return ('{0}@{1}' -f $user, $hostName)
}

function Parse-UtcDateTime {
  param([AllowEmptyString()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  try {
    return [datetime]::Parse(
      $Value,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
  } catch {
    return $null
  }
}

function Get-ScopeKey {
  param([Parameter(Mandatory)][string]$Seed)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $hasher.Dispose()
  }

  return $hash.Substring(0, 16)
}

function New-ContainerName {
  param([Parameter(Mandatory)][string]$RepoRootResolved)

  if (-not [string]::IsNullOrWhiteSpace($ContainerName)) {
    return $ContainerName.Trim()
  }

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($RepoRootResolved.ToLowerInvariant())
  $hasher = [System.Security.Cryptography.MD5]::Create()
  try {
    $hash = ($hasher.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $hasher.Dispose()
  }
  return ('comparevi-vi-history-warm-{0}' -f $hash.Substring(0, 8))
}

function Get-ContainerRecord {
  param([Parameter(Mandatory)][string]$Name)

  $inspect = Invoke-Docker -Arguments @('inspect', $Name) -IgnoreExitCode
  if ($inspect.ExitCode -ne 0) {
    return $null
  }

  try {
    $records = $inspect.Text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  } catch {
    return $null
  }

  $record = @($records | Select-Object -First 1)
  if ($record.Count -eq 0) {
    return $null
  }

  return [pscustomobject]@{
    id = if ($record[0].PSObject.Properties['Id']) { [string]$record[0].Id } else { '' }
    image = if ($record[0].Config -and $record[0].Config.PSObject.Properties['Image']) { [string]$record[0].Config.Image } else { '' }
    running = if ($record[0].State -and $record[0].State.PSObject.Properties['Running']) { [bool]$record[0].State.Running } else { $false }
    status = if ($record[0].State -and $record[0].State.PSObject.Properties['Status']) { [string]$record[0].State.Status } else { '' }
    startedAt = if ($record[0].State -and $record[0].State.PSObject.Properties['StartedAt']) { [string]$record[0].State.StartedAt } else { '' }
    finishedAt = if ($record[0].State -and $record[0].State.PSObject.Properties['FinishedAt']) { [string]$record[0].State.FinishedAt } else { '' }
  }
}

function Resolve-GitCommonMount {
  param([Parameter(Mandatory)][string]$RepoRootResolved)

  $gitDirOutput = & git -C $RepoRootResolved rev-parse --git-dir 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }
  $commonDirOutput = & git -C $RepoRootResolved rev-parse --git-common-dir 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  $gitDirPath = [string]($gitDirOutput | Select-Object -Last 1)
  $commonDirPath = [string]($commonDirOutput | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($gitDirPath) -or [string]::IsNullOrWhiteSpace($commonDirPath)) {
    return $null
  }

  if (-not [System.IO.Path]::IsPathRooted($commonDirPath)) {
    $commonDirPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRootResolved $commonDirPath))
  }
  if (-not (Test-Path -LiteralPath $commonDirPath -PathType Container)) {
    return $null
  }

  if (-not [System.IO.Path]::IsPathRooted($gitDirPath)) {
    $gitDirPath = [System.IO.Path]::GetFullPath((Join-Path $RepoRootResolved $gitDirPath))
  }
  if ([string]::Equals($gitDirPath, $commonDirPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  return [pscustomobject]@{
    hostPath = $commonDirPath
    containerPath = '/opt/comparevi/git/common'
  }
}

function New-HeartbeatCommand {
  param([Parameter(Mandatory)][string]$HeartbeatPathContainer)

  return @'
mkdir -p "$(dirname "$COMPAREVI_HEARTBEAT_PATH")"
while true; do
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "$COMPAREVI_HEARTBEAT_PATH" <<JSON
{"schema":"comparevi/local-runtime-heartbeat@v1","generatedAt":"$timestamp","status":"running","owner":"$COMPAREVI_RUNTIME_OWNER"}
JSON
  sleep 15
done
'@
}

function Get-Paths {
  param(
    [Parameter(Mandatory)][string]$RepoRootResolved,
    [Parameter(Mandatory)][string]$ResultsRootResolved,
    [Parameter(Mandatory)][string]$RuntimeDirResolved,
    [Parameter(Mandatory)][string]$ContainerNameResolved,
    [Parameter(Mandatory)][string]$ImageResolved,
    [AllowNull()]$GitCommonMount
  )

  return [pscustomobject]@{
    repoRoot = $RepoRootResolved
    resultsRoot = $ResultsRootResolved
    runtimeDir = $RuntimeDirResolved
    statePath = Join-Path $RuntimeDirResolved 'local-runtime-state.json'
    leasePath = Join-Path $RuntimeDirResolved 'local-runtime-lease.json'
    healthPath = Join-Path $RuntimeDirResolved 'local-runtime-health.json'
    logsPath = Join-Path $RuntimeDirResolved 'local-runtime-logs.json'
    logsTextPath = Join-Path $RuntimeDirResolved 'local-runtime-logs.txt'
    heartbeatPath = Join-Path $RuntimeDirResolved 'local-runtime-heartbeat.json'
    hostRamBudgetPath = Join-Path $RuntimeDirResolved 'host-ram-budget.json'
    lockPath = Join-Path $RuntimeDirResolved 'local-runtime.lock'
    containerName = $ContainerNameResolved
    image = $ImageResolved
    repoContainerPath = '/opt/comparevi/source'
    resultsContainerPath = '/opt/comparevi/vi-history/results'
    runtimeContainerPath = '/opt/comparevi/runtime'
    heartbeatContainerPath = '/opt/comparevi/runtime/local-runtime-heartbeat.json'
    gitCommonMount = $GitCommonMount
  }
}

function Clear-HeartbeatArtifact {
  param([Parameter(Mandatory)]$Paths)

  if (Test-Path -LiteralPath $Paths.heartbeatPath -PathType Leaf) {
    Remove-Item -LiteralPath $Paths.heartbeatPath -Force -ErrorAction SilentlyContinue
  }
}

function Write-LeaseReceipt {
  param(
    [Parameter(Mandatory)]$Paths,
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][datetime]$AcquiredAtUtc
  )

  $payload = [ordered]@{
    schema = $leaseSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    acquiredAt = $AcquiredAtUtc.ToString('o')
    owner = $Owner
    scopeKey = Get-ScopeKey -Seed ('{0}|{1}|{2}' -f $Paths.repoRoot, $Paths.runtimeDir, $Paths.containerName)
    lock = [ordered]@{
      strategy = 'exclusive-file-lock'
      path = $Paths.lockPath
      processId = $PID
    }
    runtime = [ordered]@{
      containerName = $Paths.containerName
      image = $Paths.image
      repositoryRoot = $Paths.repoRoot
      resultsRoot = $Paths.resultsRoot
      runtimeDir = $Paths.runtimeDir
    }
    artifacts = [ordered]@{
      statePath = $Paths.statePath
      healthPath = $Paths.healthPath
      leasePath = $Paths.leasePath
      heartbeatPath = $Paths.heartbeatPath
      hostRamBudgetPath = $Paths.hostRamBudgetPath
    }
  }

  Write-JsonFile -Path $Paths.leasePath -Payload $payload
  return $payload
}

function Get-HealthAssessment {
  param(
    [Parameter(Mandatory)]$Paths,
    [AllowNull()]$Record,
    [AllowNull()]$HostRamBudget
  )

  $heartbeat = Read-JsonFile -Path $Paths.heartbeatPath
  $heartbeatGeneratedAt = $null
  if ($heartbeat -and $heartbeat.PSObject.Properties['generatedAt']) {
    $heartbeatGeneratedAt = Parse-UtcDateTime -Value ([string]$heartbeat.generatedAt)
  }

  $startedAtUtc = $null
  $finishedAtUtc = $null
  $containerAgeSeconds = $null
  if ($Record) {
    $startedAtUtc = Parse-UtcDateTime -Value ([string]$Record.startedAt)
    $finishedAtUtc = Parse-UtcDateTime -Value ([string]$Record.finishedAt)
    if ($startedAtUtc) {
      $containerAgeSeconds = [int][math]::Floor(((Get-Date).ToUniversalTime() - $startedAtUtc).TotalSeconds)
    }
  }

  $ageSeconds = if ($heartbeatGeneratedAt) {
    [int][math]::Floor(((Get-Date).ToUniversalTime() - $heartbeatGeneratedAt).TotalSeconds)
  } else {
    $null
  }

  $status = 'missing'
  $reason = 'container-not-found'
  $recoveryRequired = $true
  $reuseAllowed = $false
  $imageMatches = $true

  if ($Record) {
    $imageMatches = [string]::Equals([string]$Record.image, $Paths.image, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $imageMatches) {
      $status = 'stale'
      $reason = 'image-mismatch'
    } elseif (-not $Record.running) {
      $status = 'not-running'
      $reason = if ([string]::IsNullOrWhiteSpace($Record.status)) { 'container-not-running' } else { [string]$Record.status }
    } elseif ($heartbeatGeneratedAt -and $ageSeconds -le $HeartbeatFreshSeconds) {
      $status = 'healthy'
      $reason = 'heartbeat-fresh'
      $recoveryRequired = $false
      $reuseAllowed = $true
    } elseif ($heartbeatGeneratedAt) {
      $status = 'stale'
      $reason = 'heartbeat-stale'
    } elseif ($containerAgeSeconds -ne $null -and $containerAgeSeconds -le $HeartbeatFreshSeconds) {
      $status = 'starting'
      $reason = 'heartbeat-pending'
      $recoveryRequired = $false
      $reuseAllowed = $true
    } else {
      $status = 'stale'
      $reason = 'heartbeat-missing'
    }
  }

  return [ordered]@{
    schema = $healthSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    containerName = $Paths.containerName
    image = $Paths.image
    status = $status
    reason = $reason
    heartbeatFreshSeconds = $HeartbeatFreshSeconds
    heartbeat = [ordered]@{
      schema = $heartbeatSchema
      path = $Paths.heartbeatPath
      present = [bool]$heartbeat
      generatedAt = if ($heartbeatGeneratedAt) { $heartbeatGeneratedAt.ToString('o') } else { $null }
      ageSeconds = $ageSeconds
    }
    container = [ordered]@{
      running = if ($Record) { [bool]$Record.running } else { $false }
      status = if ($Record) { [string]$Record.status } else { '' }
      startedAt = if ($startedAtUtc) { $startedAtUtc.ToString('o') } else { '' }
      finishedAt = if ($finishedAtUtc) { $finishedAtUtc.ToString('o') } else { '' }
      ageSeconds = $containerAgeSeconds
      imageMatches = $imageMatches
    }
    recoveryRequired = $recoveryRequired
    reuseAllowed = $reuseAllowed
    hostRamBudget = $HostRamBudget
  }
}

function Start-LocalRuntimeContainer {
  param([Parameter(Mandatory)]$Paths)

  $imageCheck = Invoke-Docker -Arguments @('image', 'inspect', $Paths.image) -IgnoreExitCode
  if ($imageCheck.ExitCode -ne 0) {
    throw ("Docker image '{0}' is not available locally. Build or pull it first." -f $Paths.image)
  }

  $existingRecord = Get-ContainerRecord -Name $Paths.containerName
  if ($existingRecord) {
    Invoke-Docker -Arguments @('rm', '-f', $Paths.containerName) -IgnoreExitCode | Out-Null
  }
  Clear-HeartbeatArtifact -Paths $Paths

  $heartbeatScript = New-HeartbeatCommand -HeartbeatPathContainer $Paths.heartbeatContainerPath
  $dockerArgs = [System.Collections.Generic.List[string]]::new()
  foreach ($token in @(
      'run',
      '-d',
      '--name', $Paths.containerName,
      '--workdir', $Paths.repoContainerPath,
      '-v', ('{0}:{1}' -f $Paths.repoRoot, $Paths.repoContainerPath),
      '-v', ('{0}:{1}' -f $Paths.resultsRoot, $Paths.resultsContainerPath),
      '-v', ('{0}:{1}' -f $Paths.runtimeDir, $Paths.runtimeContainerPath),
      '-e', ('COMPAREVI_HEARTBEAT_PATH={0}' -f $Paths.heartbeatContainerPath),
      '-e', ('COMPAREVI_RUNTIME_OWNER={0}' -f (Get-OwnerStamp))
    )) {
    [void]$dockerArgs.Add($token)
  }
  if ($Paths.gitCommonMount) {
    [void]$dockerArgs.Add('-v')
    [void]$dockerArgs.Add(('{0}:{1}' -f $Paths.gitCommonMount.hostPath, $Paths.gitCommonMount.containerPath))
  }
  [void]$dockerArgs.Add($Paths.image)
  [void]$dockerArgs.Add('bash')
  [void]$dockerArgs.Add('-lc')
  [void]$dockerArgs.Add($heartbeatScript)
  Invoke-Docker -Arguments $dockerArgs.ToArray() | Out-Null
  Start-Sleep -Seconds 2
  return (Get-ContainerRecord -Name $Paths.containerName)
}

function New-State {
  param(
    [Parameter(Mandatory)][string]$Outcome,
    [Parameter(Mandatory)]$Paths,
    [AllowNull()]$Record,
    [AllowNull()]$HostRamBudget
  )

  return [ordered]@{
    schema = $stateSchema
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    action = $Action
    outcome = $Outcome
    repositoryRoot = $Paths.repoRoot
    resultsRoot = $Paths.resultsRoot
    runtimeDir = $Paths.runtimeDir
    container = [ordered]@{
      name = $Paths.containerName
      image = $Paths.image
      id = if ($Record) { [string]$Record.id } else { '' }
      running = if ($Record) { [bool]$Record.running } else { $false }
      status = if ($Record) { [string]$Record.status } else { '' }
      startedAt = if ($Record) { [string]$Record.startedAt } else { '' }
      finishedAt = if ($Record) { [string]$Record.finishedAt } else { '' }
    }
    lease = [ordered]@{
      owner = Get-OwnerStamp
      lockPath = $Paths.lockPath
    }
    mounts = [ordered]@{
      repoHostPath = $Paths.repoRoot
      repoContainerPath = $Paths.repoContainerPath
      resultsHostPath = $Paths.resultsRoot
      resultsContainerPath = $Paths.resultsContainerPath
      runtimeHostPath = $Paths.runtimeDir
      runtimeContainerPath = $Paths.runtimeContainerPath
      gitCommonHostPath = if ($Paths.gitCommonMount) { [string]$Paths.gitCommonMount.hostPath } else { '' }
      gitCommonContainerPath = if ($Paths.gitCommonMount) { [string]$Paths.gitCommonMount.containerPath } else { '' }
    }
    artifacts = [ordered]@{
      statePath = $Paths.statePath
      leasePath = $Paths.leasePath
      healthPath = $Paths.healthPath
      logsPath = $Paths.logsPath
      logsTextPath = $Paths.logsTextPath
      heartbeatPath = $Paths.heartbeatPath
      hostRamBudgetPath = $Paths.hostRamBudgetPath
    }
    hostRamBudget = $HostRamBudget
  }
}

function Write-Health {
  param(
    [Parameter(Mandatory)]$Paths,
    [AllowNull()]$Record,
    [AllowNull()]$HostRamBudget
  )

  $health = Get-HealthAssessment -Paths $Paths -Record $Record -HostRamBudget $HostRamBudget
  Write-JsonFile -Path $Paths.healthPath -Payload $health
  return $health
}

$repoRootResolved = Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved
$runtimeDirResolved = Resolve-AbsolutePath -Path $RuntimeDir -BasePath $repoRootResolved
New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null
New-Item -ItemType Directory -Path $runtimeDirResolved -Force | Out-Null

$gitCommonMount = Resolve-GitCommonMount -RepoRootResolved $repoRootResolved
$resolvedContainerName = New-ContainerName -RepoRootResolved $repoRootResolved
$paths = Get-Paths `
  -RepoRootResolved $repoRootResolved `
  -ResultsRootResolved $resultsRootResolved `
  -RuntimeDirResolved $runtimeDirResolved `
  -ContainerNameResolved $resolvedContainerName `
  -ImageResolved $Image `
  -GitCommonMount $gitCommonMount
if (-not [string]::IsNullOrWhiteSpace($HostRamBudgetPath)) {
  $paths.hostRamBudgetPath = Resolve-AbsolutePath -Path $HostRamBudgetPath -BasePath $repoRootResolved
}
$hostRamBudgetReport = Resolve-CompareVIHostRamBudgetReport `
  -RepoRoot $repoRootResolved `
  -OutputPath $paths.hostRamBudgetPath `
  -TargetProfile $HostRamBudgetTargetProfile `
  -TotalBytes $HostRamBudgetTotalBytes `
  -FreeBytes $HostRamBudgetFreeBytes `
  -CpuParallelism $HostRamBudgetCpuParallelism
$hostRamBudget = New-CompareVISerialHostRamBudgetDecision `
  -BudgetReport $hostRamBudgetReport.report `
  -BudgetPath $hostRamBudgetReport.path `
  -RequestedParallelism $HeavyExecutionParallelism `
  -ReasonWhenParallelEligible 'warm-runtime-single-container'

$lockStream = Acquire-LockStream -LockPath $paths.lockPath -WaitSeconds $LockWaitSeconds
try {
  $leaseOwner = Get-OwnerStamp
  $leaseAcquiredAt = (Get-Date).ToUniversalTime()
  $leaseReceipt = Write-LeaseReceipt -Paths $paths -Owner $leaseOwner -AcquiredAtUtc $leaseAcquiredAt
  $existing = Get-ContainerRecord -Name $paths.containerName
  $existingHealth = Get-HealthAssessment -Paths $paths -Record $existing -HostRamBudget $hostRamBudget

  switch ($Action) {
    'start' {
      if ($existingHealth.reuseAllowed) {
        $state = New-State -Outcome 'reused' -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
        $state.lease = $leaseReceipt
        $state.health = Write-Health -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
        $state.recovery = [ordered]@{
          attempted = $false
          reason = ''
        }
        Write-JsonFile -Path $paths.statePath -Payload $state
        $state | ConvertTo-Json -Depth 20
        break
      }

      $record = Start-LocalRuntimeContainer -Paths $paths
      $outcome = if ($existing) { 'recovered-stale-runtime' } else { 'started' }
      $state = New-State -Outcome $outcome -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      $state.lease = $leaseReceipt
      $state.health = Write-Health -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      $state.recovery = [ordered]@{
        attempted = [bool]$existing
        previousHealth = if ($existing) { $existingHealth } else { $null }
        action = if ($existing) { 'replace-container' } else { 'start-container' }
      }
      Write-JsonFile -Path $paths.statePath -Payload $state
      $state | ConvertTo-Json -Depth 20
      break
    }
    'status' {
      $state = New-State -Outcome 'status' -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
      $state.lease = $leaseReceipt
      $state.health = Write-Health -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
      Write-JsonFile -Path $paths.statePath -Payload $state
      $state.health | ConvertTo-Json -Depth 20
      break
    }
    'logs' {
      if (-not $existing) {
        throw ("Runtime container '{0}' does not exist." -f $paths.containerName)
      }
      $logs = Invoke-Docker -Arguments @('logs', '--tail', "$TailLines", $paths.containerName) -IgnoreExitCode
      Write-TextFile -Path $paths.logsTextPath -Lines $logs.Lines
      $payload = [ordered]@{
        schema = $logsSchema
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        containerName = $paths.containerName
        image = $paths.image
        exitCode = [int]$logs.ExitCode
        lineCount = $logs.Lines.Count
        logsTextPath = $paths.logsTextPath
      }
      Write-JsonFile -Path $paths.logsPath -Payload $payload
      $payload | ConvertTo-Json -Depth 20
      break
    }
    'stop' {
      if ($existing) {
        if ($RemoveOnStop) {
          Invoke-Docker -Arguments @('rm', '-f', $paths.containerName) -IgnoreExitCode | Out-Null
        } else {
          Invoke-Docker -Arguments @('stop', $paths.containerName) -IgnoreExitCode | Out-Null
        }
      }
      Clear-HeartbeatArtifact -Paths $paths
      $record = Get-ContainerRecord -Name $paths.containerName
      $state = New-State -Outcome 'stopped' -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      $state.lease = $leaseReceipt
      $state.health = Write-Health -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      Write-JsonFile -Path $paths.statePath -Payload $state
      $state | ConvertTo-Json -Depth 20
      break
    }
    'reconcile' {
      if ($existingHealth.reuseAllowed) {
        $state = New-State -Outcome 'healthy' -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
        $state.lease = $leaseReceipt
        $state.health = Write-Health -Paths $paths -Record $existing -HostRamBudget $hostRamBudget
        $state.recovery = [ordered]@{
          attempted = $false
          reason = ''
        }
        Write-JsonFile -Path $paths.statePath -Payload $state
        $state | ConvertTo-Json -Depth 20
        break
      }

      $record = Start-LocalRuntimeContainer -Paths $paths
      $state = New-State -Outcome $(if ($existing) { 'recovered-stale-runtime' } else { 'started' }) -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      $state.lease = $leaseReceipt
      $state.health = Write-Health -Paths $paths -Record $record -HostRamBudget $hostRamBudget
      $state.recovery = [ordered]@{
        attempted = [bool]$existing
        previousHealth = $existingHealth
        action = if ($existing) { 'replace-container' } else { 'start-container' }
      }
      Write-JsonFile -Path $paths.statePath -Payload $state
      $state | ConvertTo-Json -Depth 20
      break
    }
  }
} finally {
  if ($lockStream) {
    $lockStream.Dispose()
  }
}
