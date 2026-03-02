#Requires -Version 7.0
<#
.SYNOPSIS
  Validates and repairs Docker runtime invariants for deterministic automation.

.DESCRIPTION
  Checks host/runner expectations, Docker daemon OSType, and active Docker
  context. Optionally attempts deterministic repair actions and records an
  execution snapshot JSON for diagnostics. `vmmem*` multiplicity is telemetry
  only and never a standalone failure condition.

.PARAMETER ExpectedOsType
  Required expected Docker daemon OSType: windows or linux.

.PARAMETER ExpectedContext
  Optional expected Docker context. Defaults to desktop-windows for windows
  lanes and desktop-linux for linux lanes.

.PARAMETER AutoRepair
  When true, mismatch remediation is attempted before failing.

.PARAMETER ManageDockerEngine
  When true on Windows hosts, attempts Docker Desktop engine switch to the
  expected lane OS before re-checking invariants.

.PARAMETER EngineReadyTimeoutSeconds
  Maximum wait time after repair actions before failing readiness.

.PARAMETER EngineReadyPollSeconds
  Poll interval while waiting for Docker daemon readiness.

.PARAMETER SnapshotPath
  Path to write the runtime determinism snapshot JSON.

.PARAMETER GitHubOutputPath
  Optional GitHub output file path.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('windows', 'linux')]
  [string]$ExpectedOsType,

  [string]$ExpectedContext,

  [bool]$AutoRepair = $true,

  [bool]$ManageDockerEngine = $true,

  [int]$EngineReadyTimeoutSeconds = 120,

  [int]$EngineReadyPollSeconds = 3,

  [Parameter(Mandatory = $true)]
  [string]$SnapshotPath,

  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$DestPath
  )

  if ([string]::IsNullOrWhiteSpace($DestPath)) { return }
  $dir = Split-Path -Parent $DestPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
    New-Item -ItemType File -Path $DestPath -Force | Out-Null
  }
  Add-Content -LiteralPath $DestPath -Value ("{0}={1}" -f $Key, $Value) -Encoding utf8
}

function Get-DockerOsProbe {
  param([AllowNull()][string]$Context)

  $probe = [ordered]@{
    context = $Context
    command = ''
    exitCode = $null
    osType = $null
    parseReason = ''
    rawLines = @()
  }
  try {
    $args = @('info', '--format', '{{.OSType}}')
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
      $args = @('--context', $Context) + $args
    }
    $probe.command = ('docker {0}' -f ($args -join ' '))
    $output = & docker @args 2>&1
    $probe.exitCode = [int]$LASTEXITCODE
    $lines = @($output | ForEach-Object { [string]$_ })
    $probe.rawLines = @($lines | Select-Object -First 12)

    foreach ($line in $lines) {
      $candidate = $line.Trim().ToLowerInvariant()
      if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
        $probe.osType = $candidate
        $probe.parseReason = 'parsed'
        break
      }
    }

    if ([string]::IsNullOrWhiteSpace([string]$probe.osType)) {
      $joined = (($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
      if ([string]::IsNullOrWhiteSpace($joined)) {
        $probe.parseReason = 'empty-output'
      } elseif (
        $joined -match 'Docker Desktop is unable to start' -or
        $joined -match 'Error response from daemon' -or
        $joined -match 'DockerDesktop/Wsl/ExecError' -or
        $joined -match 'Cannot connect to the Docker daemon' -or
        $joined -match 'error during connect'
      ) {
        $probe.parseReason = 'daemon-unavailable'
      } elseif ([int]$probe.exitCode -ne 0) {
        $probe.parseReason = 'docker-info-command-failed'
      } else {
        $probe.parseReason = 'unparseable-output'
      }
    }
  } catch {
    $probe.exitCode = [int]$LASTEXITCODE
    if ($probe.exitCode -eq 0) { $probe.exitCode = $null }
    if ($_.Exception.Message) {
      $probe.rawLines = @([string]$_.Exception.Message)
    }
    $probe.parseReason = 'exception'
  }
  return [pscustomobject]$probe
}

function Format-DockerOsProbeHint {
  param([AllowNull()]$Probe)

  if ($null -eq $Probe) { return '' }
  $parseReason = ''
  if ($Probe.PSObject.Properties['parseReason']) {
    $parseReason = [string]$Probe.parseReason
  }
  if ([string]::IsNullOrWhiteSpace($parseReason)) {
    $parseReason = 'unknown'
  }
  $exitCode = ''
  if ($Probe.PSObject.Properties['exitCode'] -and $null -ne $Probe.exitCode) {
    $exitCode = [string]$Probe.exitCode
  } else {
    $exitCode = '<null>'
  }

  $sample = ''
  if ($Probe.PSObject.Properties['rawLines'] -and $Probe.rawLines) {
    $lines = @($Probe.rawLines | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0) {
      $sample = $lines[0].Trim()
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($sample) -and $sample.Length -gt 220) {
    $sample = $sample.Substring(0, 220) + '...'
  }

  if ([string]::IsNullOrWhiteSpace($sample)) {
    return ("Docker info probe: parseReason={0}, exitCode={1}" -f $parseReason, $exitCode)
  }
  return ("Docker info probe: parseReason={0}, exitCode={1}, sample='{2}'" -f $parseReason, $exitCode, $sample)
}

function Get-DockerOsType {
  param([AllowNull()][string]$Context)
  $probe = Get-DockerOsProbe -Context $Context
  if ($null -eq $probe) {
    return $null
  }
  return [string]$probe.osType
}

function Get-DockerContext {
  try {
    $output = & docker context show 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
      return $null
    }
    return $output.Trim()
  } catch {
    return $null
  }
}

function Get-DockerContexts {
  $rows = New-Object System.Collections.Generic.List[object]
  try {
    $output = & docker context ls --format '{{json .}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
      return @()
    }
    foreach ($line in @($output)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        $rows.Add($obj) | Out-Null
      } catch {}
    }
  } catch {}
  return $rows.ToArray()
}

function Get-WslDistributions {
  if (-not $IsWindows) { return @() }

  $items = New-Object System.Collections.Generic.List[object]
  try {
    $output = & wsl -l -v 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
      return @()
    }

    $lines = @($output | ForEach-Object { [string]$_ })
    if ($lines.Count -le 1) { return @() }
    foreach ($line in $lines | Select-Object -Skip 1) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $clean = $line -replace [char]0, ''
      $isDefault = $clean.TrimStart().StartsWith('*')
      $tokenized = $clean.TrimStart('*', ' ') -split '\s{2,}'
      if ($tokenized.Count -lt 1) { continue }
      $name = $tokenized[0].Trim()
      $state = if ($tokenized.Count -ge 2) { $tokenized[1].Trim() } else { '' }
      $version = if ($tokenized.Count -ge 3) { $tokenized[2].Trim() } else { '' }
      $items.Add([ordered]@{
        name      = $name
        state     = $state
        version   = $version
        isDefault = $isDefault
      }) | Out-Null
    }
  } catch {}
  return $items.ToArray()
}

function Get-VmmemProcesses {
  $items = New-Object System.Collections.Generic.List[object]
  try {
    $procs = Get-Process -Name vmmem,vmmemWSL -ErrorAction SilentlyContinue
    foreach ($proc in @($procs)) {
      $items.Add([ordered]@{
        name     = $proc.ProcessName
        id       = $proc.Id
        cpu      = [double]$proc.CPU
        wsMb     = [math]::Round(($proc.WorkingSet64 / 1MB), 2)
        startUtc = if ($proc.StartTime) { $proc.StartTime.ToUniversalTime().ToString('o') } else { $null }
      }) | Out-Null
    }
  } catch {}
  return $items.ToArray()
}

function Get-RunningContainers {
  $items = New-Object System.Collections.Generic.List[object]
  try {
    $output = & docker ps --format '{{json .}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
      return @()
    }
    foreach ($line in @($output)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        $items.Add($obj) | Out-Null
      } catch {}
    }
  } catch {}
  return $items.ToArray()
}

function Invoke-DockerContextUse {
  param([Parameter(Mandatory = $true)][string]$Context)
  try {
    $null = & docker context use $Context 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Invoke-WslShutdown {
  if (-not $IsWindows) { return $false }
  try {
    $null = & wsl --shutdown 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Resolve-DockerCliPath {
  if (-not $IsWindows) { return $null }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'),
    (Join-Path $env:ProgramFiles 'Docker\Docker\com.docker.cli.exe'),
    (Join-Path $env:ProgramW6432 'Docker\Docker\DockerCli.exe'),
    (Join-Path $env:ProgramW6432 'Docker\Docker\com.docker.cli.exe')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return $null
}

function Invoke-DockerEngineSwitch {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$TargetOsType
  )

  $result = [ordered]@{
    attempted = $false
    success = $false
    command = ''
    message = ''
  }
  if (-not $IsWindows) {
    $result.message = 'engine-switch-not-applicable-non-windows-host'
    return $result
  }
  $dockerCli = Resolve-DockerCliPath
  if ([string]::IsNullOrWhiteSpace($dockerCli)) {
    $result.message = 'docker-cli-not-found'
    return $result
  }

  $switchArg = if ($TargetOsType -eq 'windows') { '-SwitchWindowsEngine' } else { '-SwitchLinuxEngine' }
  $result.attempted = $true
  $result.command = "$dockerCli $switchArg"
  try {
    $output = & $dockerCli $switchArg 2>&1
    $exitCode = $LASTEXITCODE
    $result.success = ($exitCode -eq 0)
    if ($output) {
      $result.message = ((@($output) | ForEach-Object { [string]$_ }) -join '; ')
    } else {
      $result.message = "exit=$exitCode"
    }
  } catch {
    $result.success = $false
    $result.message = $_.Exception.Message
  }
  return $result
}

function Get-ManualRemediationSteps {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$TargetOsType,
    [Parameter(Mandatory = $true)][string]$ExpectedContext
  )

  $steps = New-Object System.Collections.Generic.List[string]
  $steps.Add(("docker context use {0}" -f $ExpectedContext)) | Out-Null
  if ($IsWindows) {
    $dockerCli = Resolve-DockerCliPath
    if (-not [string]::IsNullOrWhiteSpace($dockerCli)) {
      $switchArg = if ($TargetOsType -eq 'windows') { '-SwitchWindowsEngine' } else { '-SwitchLinuxEngine' }
      $steps.Add(('"{0}" {1}' -f $dockerCli, $switchArg)) | Out-Null
    }
    if ($TargetOsType -eq 'windows') {
      $steps.Add('wsl --shutdown') | Out-Null
    }
  }
  return @($steps.ToArray())
}

function Wait-DockerEngineReady {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$ExpectedOsType,
    [Parameter(Mandatory = $true)][string]$FallbackContext,
    [int]$TimeoutSeconds = 120,
    [int]$PollSeconds = 3
  )

  $started = Get-Date
  $deadline = $started.AddSeconds([math]::Max(10, $TimeoutSeconds))
  $poll = [math]::Max(1, $PollSeconds)
  $attempts = 0
  while ((Get-Date) -lt $deadline) {
    $attempts++
    $context = Get-DockerContext
    if ([string]::IsNullOrWhiteSpace($context)) {
      $context = $FallbackContext
    }
    $probe = Get-DockerOsProbe -Context $context
    $osType = [string]$probe.osType
    if ($osType -eq $ExpectedOsType) {
      return [ordered]@{
        ready = $true
        attempts = $attempts
        context = $context
        osType = $osType
        osProbe = $probe
      }
    }
    Start-Sleep -Seconds $poll
  }
  $finalContext = Get-DockerContext
  if ([string]::IsNullOrWhiteSpace($finalContext)) {
    $finalContext = $FallbackContext
  }
  $finalProbe = Get-DockerOsProbe -Context $finalContext
  $finalOsType = [string]$finalProbe.osType
  return [ordered]@{
    ready = $false
    attempts = $attempts
    context = $finalContext
    osType = $finalOsType
    osProbe = $finalProbe
  }
}

$effectiveExpectedContext = $ExpectedContext
if ([string]::IsNullOrWhiteSpace($effectiveExpectedContext)) {
  $effectiveExpectedContext = if ($ExpectedOsType -eq 'windows') { 'desktop-windows' } else { 'desktop-linux' }
}

$snapshotResolved = if ([System.IO.Path]::IsPathRooted($SnapshotPath)) {
  [System.IO.Path]::GetFullPath($SnapshotPath)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $SnapshotPath))
}
$snapshotDir = Split-Path -Parent $snapshotResolved
if ($snapshotDir -and -not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
  New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
}

$resultStatus = 'ok'
$reason = ''
$repairActions = New-Object System.Collections.Generic.List[string]
$initialDockerOsProbe = $null
$fallbackDockerOsProbe = $null
$lastDockerOsProbe = $null

$runnerOsRaw = $env:RUNNER_OS
$runnerOsNormalized = if ([string]::IsNullOrWhiteSpace($runnerOsRaw)) { '' } else { $runnerOsRaw.Trim().ToLowerInvariant() }
$hostIsWindows = [bool]$IsWindows
$hostAlignmentOk = $true
if ($ExpectedOsType -eq 'windows') {
  if (-not $hostIsWindows) {
    $hostAlignmentOk = $false
    $reason = 'Windows container lanes require a Windows host.'
  }
  if (-not [string]::IsNullOrWhiteSpace($runnerOsNormalized) -and $runnerOsNormalized -ne 'windows') {
    $hostAlignmentOk = $false
    $reason = "RUNNER_OS is '$runnerOsRaw', expected Windows."
  }
} elseif (-not [string]::IsNullOrWhiteSpace($runnerOsNormalized) -and $runnerOsNormalized -ne 'linux') {
  $hostAlignmentOk = $false
  $reason = "RUNNER_OS is '$runnerOsRaw', expected Linux for linux lane."
}

$observedContext = Get-DockerContext
$initialDockerOsProbe = Get-DockerOsProbe -Context $observedContext
$observedOsType = [string]$initialDockerOsProbe.osType
$lastDockerOsProbe = $initialDockerOsProbe
if ([string]::IsNullOrWhiteSpace($observedOsType)) {
  $fallbackDockerOsProbe = Get-DockerOsProbe -Context $effectiveExpectedContext
  $observedOsType = [string]$fallbackDockerOsProbe.osType
  $lastDockerOsProbe = $fallbackDockerOsProbe
}

if (-not $hostAlignmentOk) {
  $resultStatus = 'mismatch-failed'
} else {
  $osMismatch = [string]::IsNullOrWhiteSpace($observedOsType) -or ($observedOsType -ne $ExpectedOsType)
  $contextMismatch = [string]::IsNullOrWhiteSpace($observedContext) -or ($observedContext -ne $effectiveExpectedContext)

  if ($osMismatch -or $contextMismatch) {
    Write-Host ("[runtime-determinism] mismatch detected expected={0}/{1} observed={2}/{3}" -f $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>')) -ForegroundColor Yellow
    if ($AutoRepair) {
      if ($contextMismatch) {
        Write-Host ("[runtime-determinism] attempting: docker context use {0}" -f $effectiveExpectedContext) -ForegroundColor DarkGray
        $ok = Invoke-DockerContextUse -Context $effectiveExpectedContext
        $ctxResult = if ($ok) { 'ok' } else { 'failed' }
        $repairActions.Add(("docker context use {0}: {1}" -f $effectiveExpectedContext, $ctxResult)) | Out-Null
      }
      if ($ManageDockerEngine -and $hostIsWindows -and $osMismatch) {
        Write-Host ("[runtime-determinism] attempting docker engine switch to {0}" -f $ExpectedOsType) -ForegroundColor DarkGray
        $switchResult = Invoke-DockerEngineSwitch -TargetOsType $ExpectedOsType
        $switchStatus = if ([bool]$switchResult.success) { 'ok' } else { 'failed' }
        $switchMessage = if ([string]::IsNullOrWhiteSpace([string]$switchResult.message)) { '' } else { [string]$switchResult.message }
        $repairActions.Add(("docker engine switch to {0}: {1} {2}" -f $ExpectedOsType, $switchStatus, $switchMessage).Trim()) | Out-Null
      }
      if ($ExpectedOsType -eq 'windows') {
        Write-Host '[runtime-determinism] attempting: wsl --shutdown' -ForegroundColor DarkGray
        $wslOk = Invoke-WslShutdown
        $wslResult = if ($wslOk) { 'ok' } else { 'failed-or-not-applicable' }
        $repairActions.Add(("wsl --shutdown: {0}" -f $wslResult)) | Out-Null
      }

      Write-Host ("[runtime-determinism] attempting: docker context use {0} (post-switch)" -f $effectiveExpectedContext) -ForegroundColor DarkGray
      $postSwitchContext = Invoke-DockerContextUse -Context $effectiveExpectedContext
      $postSwitchStatus = if ($postSwitchContext) { 'ok' } else { 'failed' }
      $repairActions.Add(("docker context use {0} (post-switch): {1}" -f $effectiveExpectedContext, $postSwitchStatus)) | Out-Null

      Write-Host ("[runtime-determinism] waiting for docker engine readiness (timeout={0}s poll={1}s)" -f [int]$EngineReadyTimeoutSeconds, [int]$EngineReadyPollSeconds) -ForegroundColor DarkGray
      $waitResult = Wait-DockerEngineReady `
        -ExpectedOsType $ExpectedOsType `
        -FallbackContext $effectiveExpectedContext `
        -TimeoutSeconds $EngineReadyTimeoutSeconds `
        -PollSeconds $EngineReadyPollSeconds
      $waitStatus = if ([bool]$waitResult.ready) { 'ready' } else { 'timeout' }
      $waitProbeHint = Format-DockerOsProbeHint -Probe $waitResult.osProbe
      $repairActions.Add(("docker engine readiness: {0} attempts={1} observed={2}/{3} {4}" -f $waitStatus, [int]$waitResult.attempts, ([string]$waitResult.osType ?? '<null>'), ([string]$waitResult.context ?? '<null>'), $waitProbeHint).Trim()) | Out-Null

      $recheckedContext = [string]$waitResult.context
      $recheckedOsType = [string]$waitResult.osType
      if ($waitResult.osProbe) {
        $lastDockerOsProbe = $waitResult.osProbe
      }
      if ([string]::IsNullOrWhiteSpace($recheckedContext)) {
        $recheckedContext = Get-DockerContext
      }
      if ([string]::IsNullOrWhiteSpace($recheckedOsType)) {
        $recheckedProbe = Get-DockerOsProbe -Context $recheckedContext
        $recheckedOsType = [string]$recheckedProbe.osType
        if ($recheckedProbe) {
          $lastDockerOsProbe = $recheckedProbe
        }
      }
      if ([string]::IsNullOrWhiteSpace($recheckedOsType)) {
        $recheckedFallbackProbe = Get-DockerOsProbe -Context $effectiveExpectedContext
        $recheckedOsType = [string]$recheckedFallbackProbe.osType
        if ($recheckedFallbackProbe) {
          $lastDockerOsProbe = $recheckedFallbackProbe
        }
      }

      $osMismatchAfter = [string]::IsNullOrWhiteSpace($recheckedOsType) -or ($recheckedOsType -ne $ExpectedOsType)
      $contextMismatchAfter = [string]::IsNullOrWhiteSpace($recheckedContext) -or ($recheckedContext -ne $effectiveExpectedContext)

      $observedOsType = $recheckedOsType
      $observedContext = $recheckedContext

      if ($osMismatchAfter -or $contextMismatchAfter) {
        $manualSteps = Get-ManualRemediationSteps -TargetOsType $ExpectedOsType -ExpectedContext $effectiveExpectedContext
        $manualText = if ($manualSteps.Count -gt 0) { [string]::Join('; ', $manualSteps) } else { 'n/a' }
        $probeHint = Format-DockerOsProbeHint -Probe $lastDockerOsProbe
        $resultStatus = 'mismatch-failed'
        $reason = ("Runtime invariant mismatch after repair. expected os={0}, context={1}; observed os={2}, context={3}. Manual remediation: {4}. {5}" -f $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>'), $manualText, $probeHint)
      } else {
        $resultStatus = 'mismatch-repaired'
      }
    } else {
      $manualSteps = Get-ManualRemediationSteps -TargetOsType $ExpectedOsType -ExpectedContext $effectiveExpectedContext
      $manualText = if ($manualSteps.Count -gt 0) { [string]::Join('; ', $manualSteps) } else { 'n/a' }
      $probeHint = Format-DockerOsProbeHint -Probe $lastDockerOsProbe
      $resultStatus = 'mismatch-failed'
      $reason = ("Runtime invariant mismatch. expected os={0}, context={1}; observed os={2}, context={3}. Manual remediation: {4}. {5}" -f $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>'), $manualText, $probeHint)
    }
  }
}

$snapshot = [ordered]@{
  schema = 'docker-runtime-determinism@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  expected = [ordered]@{
    osType = $ExpectedOsType
    context = $effectiveExpectedContext
    autoRepair = [bool]$AutoRepair
    manageDockerEngine = [bool]$ManageDockerEngine
    engineReadyTimeoutSeconds = [int]$EngineReadyTimeoutSeconds
    engineReadyPollSeconds = [int]$EngineReadyPollSeconds
  }
  host = [ordered]@{
    isWindows = $hostIsWindows
    runnerOs = $runnerOsRaw
    alignmentOk = $hostAlignmentOk
  }
  observed = [ordered]@{
    osType = $observedOsType
    context = $observedContext
    dockerOsProbe = [ordered]@{
      initial = $initialDockerOsProbe
      fallback = $fallbackDockerOsProbe
      last = $lastDockerOsProbe
    }
    availableContexts = @(Get-DockerContexts)
    runningContainers = @(Get-RunningContainers)
    wslDistributions = @(Get-WslDistributions)
    vmmemProcesses = @(Get-VmmemProcesses)
  }
  repairActions = @($repairActions.ToArray())
  result = [ordered]@{
    status = $resultStatus
    reason = $reason
  }
}

$snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $snapshotResolved -Encoding utf8

Write-GitHubOutput -Key 'runtime-status' -Value $resultStatus -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'docker-ostype' -Value ($observedOsType ?? '') -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'docker-context' -Value ($observedContext ?? '') -DestPath $GitHubOutputPath
$dockerOsParseReason = ''
if ($lastDockerOsProbe -and $lastDockerOsProbe.PSObject.Properties['parseReason']) {
  $dockerOsParseReason = [string]$lastDockerOsProbe.parseReason
}
Write-GitHubOutput -Key 'docker-ostype-parse-reason' -Value $dockerOsParseReason -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'snapshot-path' -Value $snapshotResolved -DestPath $GitHubOutputPath

Write-Host ("[runtime-determinism] status={0} expected={1}/{2} observed={3}/{4} snapshot={5}" -f $resultStatus, $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>'), $snapshotResolved)

if ($resultStatus -eq 'mismatch-failed') {
  throw ($reason ?? 'Runtime determinism check failed.')
}
