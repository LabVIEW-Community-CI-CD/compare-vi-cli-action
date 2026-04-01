#Requires -Version 7.0
<#
.SYNOPSIS
  Manages Docker Desktop context transitions, NI image bootstrap, and runtime probes.

.DESCRIPTION
  Runs on a Windows host with Docker Desktop, acquires a host lock to avoid
  concurrent engine flips, validates Windows/Linux NI image manifests, ensures
  local image availability (bootstrap pull when missing), runs lightweight
  runtime probes, and restores the desired final context for downstream jobs.
#>
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$WindowsContext = 'desktop-windows',
  [string]$LinuxContext = 'desktop-linux',
  [string]$RestoreContext = 'desktop-windows',
  [ValidateSet('both', 'windows', 'linux')]
  [string]$ProbeScope = 'both',
  [bool]$BootstrapWindowsImage = $true,
  [bool]$BootstrapLinuxImage = $true,
  [ValidateRange(30, 900)]
  [int]$SwitchTimeoutSeconds = 120,
  [ValidateRange(1, 10)]
  [int]$SwitchRetryCount = 3,
  [ValidateRange(1, 30)]
  [int]$SwitchRetryDelaySeconds = 4,
  [ValidateRange(5, 600)]
  [int]$LockWaitSeconds = 90,
  [ValidateRange(5, 600)]
  [int]$CommandTimeoutSeconds = 45,
  [ValidateRange(5, 3600)]
  [int]$BootstrapPullTimeoutSeconds = 900,
  [ValidateRange(5, 900)]
  [int]$ProbeTimeoutSeconds = 180,
  [string]$WindowsProbeCommand = "[Console]::WriteLine('ni-runtime-probe-ok')",
  [string]$LinuxProbeCommand = "echo ni-runtime-probe-ok",
  [string]$OutputJsonPath = 'results/fixture-drift/docker-runtime-manager.json',
  [string]$GitHubOutputPath = '',
  [string]$StepSummaryPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [AllowNull()][AllowEmptyString()][string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $dest = Resolve-AbsolutePath -Path $Path
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  Add-Content -LiteralPath $dest -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Split-OutputLines {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return @() }
  return @($Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Resolve-DockerCommandSource {
  $override = $env:DOCKER_COMMAND_OVERRIDE
  if (-not [string]::IsNullOrWhiteSpace($override) -and (Test-Path -LiteralPath $override -PathType Leaf)) {
    return [System.IO.Path]::GetFullPath($override)
  }

  $pathSeparator = [System.IO.Path]::PathSeparator
  $pathEntries = @($env:PATH -split [regex]::Escape([string]$pathSeparator))
  $candidates = if ($IsWindows) {
    @('docker.exe', 'docker.cmd', 'docker.ps1', 'docker.bat', 'docker')
  } else {
    @('docker', 'docker.sh', 'docker.exe', 'docker.ps1', 'docker.cmd')
  }

  foreach ($entry in $pathEntries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    foreach ($name in $candidates) {
      $candidatePath = Join-Path $entry $name
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidatePath)
      }
    }
  }

  $command = Get-Command -Name 'docker' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command.Source)) {
    return $null
  }

  return [System.IO.Path]::GetFullPath([string]$command.Source)
}

function Invoke-ProcessWithTimeout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 45
  )

  $safeTimeout = [Math]::Max(5, [int]$TimeoutSeconds)
  $resolvedFilePath = $FilePath
  $effectiveArguments = @($Arguments)
  if ([string]::Equals($FilePath, 'docker', [System.StringComparison]::OrdinalIgnoreCase)) {
    $dockerCommandSource = Resolve-DockerCommandSource
    if (-not [string]::IsNullOrWhiteSpace($dockerCommandSource)) {
      $dockerCommandExtension = [System.IO.Path]::GetExtension($dockerCommandSource)
      if ([System.StringComparer]::OrdinalIgnoreCase.Equals($dockerCommandExtension, '.ps1')) {
        $resolvedFilePath = (Get-Command -Name 'pwsh' -ErrorAction Stop | Select-Object -First 1).Source
        $effectiveArguments = @('-NoLogo', '-NoProfile', '-File', $dockerCommandSource) + @($Arguments)
      } else {
        $resolvedFilePath = $dockerCommandSource
      }
    }
  }

  $argText = if ($effectiveArguments -and $effectiveArguments.Count -gt 0) {
    [string]::Join(' ', $effectiveArguments)
  } else {
    ''
  }
  $commandText = if ([string]::IsNullOrWhiteSpace($argText)) { $resolvedFilePath } else { "$resolvedFilePath $argText" }

  $result = [ordered]@{
    timedOut = $false
    exitCode = $null
    stdout = @()
    stderr = @()
    command = $commandText
    exception = ''
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $resolvedFilePath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($arg in @($effectiveArguments)) {
    [void]$psi.ArgumentList.Add([string]$arg)
  }

  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $psi

  try {
    [void]$proc.Start()
    $completed = $proc.WaitForExit($safeTimeout * 1000)
    if (-not $completed) {
      $result.timedOut = $true
      try { $proc.Kill($true) } catch {}
      return [pscustomobject]$result
    }

    $result.exitCode = [int]$proc.ExitCode
    $result.stdout = @(Split-OutputLines -Text $proc.StandardOutput.ReadToEnd())
    $result.stderr = @(Split-OutputLines -Text $proc.StandardError.ReadToEnd())
  } catch {
    $result.exception = [string]$_.Exception.Message
    try {
      if (-not $proc.HasExited) {
        $proc.Kill($true)
      }
    } catch {}
  } finally {
    $proc.Dispose()
  }

  return [pscustomobject]$result
}

function Invoke-DockerCommand {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [int]$TimeoutSeconds = $CommandTimeoutSeconds,
    [switch]$IgnoreExitCode
  )

  $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
  $lines = @(@($invoke.stdout) + @($invoke.stderr) | ForEach-Object { [string]$_ })
  $text = ($lines -join "`n")

  if ($invoke.timedOut) {
    $timeoutMessage = "docker {0} timed out after {1}s." -f ($Arguments -join ' '), [Math]::Max(5, [int]$TimeoutSeconds)
    if (-not $IgnoreExitCode) {
      throw $timeoutMessage
    }
    return [pscustomobject]@{
      ExitCode = 124
      TimedOut = $true
      Lines = @($timeoutMessage)
      Text = $timeoutMessage
    }
  }

  if ($invoke.exception) {
    throw ("docker {0} failed to launch: {1}" -f ($Arguments -join ' '), [string]$invoke.exception)
  }

  $exitCode = if ($null -eq $invoke.exitCode) { 1 } else { [int]$invoke.exitCode }

  if (-not $IgnoreExitCode -and $exitCode -ne 0) {
    throw ("docker {0} failed (exit={1}). Output: {2}" -f ($Arguments -join ' '), $exitCode, $text)
  }

  return [pscustomobject]@{
    ExitCode = [int]$exitCode
    TimedOut = $false
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

function Set-ContextAndWait {
  param(
    [Parameter(Mandatory)][string]$ContextName,
    [Parameter(Mandatory)][string]$ExpectedOsType,
    [ValidateRange(5, 900)][int]$TimeoutSeconds,
    [ValidateRange(1, 10)][int]$RetryCount,
    [ValidateRange(1, 60)][int]$RetryDelaySeconds
  )

  $lastError = $null
  for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
    try {
      $useContext = Invoke-DockerCommand -Arguments @('context', 'use', $ContextName) -TimeoutSeconds $CommandTimeoutSeconds -IgnoreExitCode
      if ($useContext.ExitCode -ne 0) {
        $switchError = [string]$useContext.Text
        $missingContext = ($switchError -match '(?i)context.+not found') -or ($switchError -match '(?i)cannot find the path specified')
        if ($missingContext) {
          Invoke-DockerEngineSwitchFallback -ExpectedOsType $ExpectedOsType
        } else {
          throw ("docker context use {0} failed (exit={1}). Output: {2}" -f $ContextName, $useContext.ExitCode, $switchError)
        }
      }

      $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
      do {
        $osProbe = Invoke-DockerCommand -Arguments @('info', '--format', '{{.OSType}}') -TimeoutSeconds $CommandTimeoutSeconds -IgnoreExitCode
        if ($osProbe.ExitCode -eq 0) {
          $osType = $osProbe.Text.Trim().ToLowerInvariant()
          if ($osType -eq $ExpectedOsType.Trim().ToLowerInvariant()) {
            return [pscustomobject]@{
              Context = $ContextName
              OsType = $osType
              Attempt = $attempt
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

function Get-ImageProbeResult {
  param(
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string]$ExpectedOs
  )

  $manifestOut = Invoke-DockerCommand -Arguments @('manifest', 'inspect', $Image) -TimeoutSeconds $CommandTimeoutSeconds
  $manifest = $manifestOut.Text | ConvertFrom-Json -Depth 30

  $digest = ''
  $platformValidated = $false
  $manifestList = $false
  $matchingPlatform = ''

  if ($manifest -and $manifest.PSObject.Properties['manifests'] -and $manifest.manifests) {
    $manifestList = $true
    foreach ($entry in @($manifest.manifests)) {
      $platform = $entry.platform
      if (-not $platform) { continue }
      $os = if ($platform.PSObject.Properties['os']) { [string]$platform.os } else { '' }
      $arch = if ($platform.PSObject.Properties['architecture']) { [string]$platform.architecture } else { '' }
      if ($os.Trim().ToLowerInvariant() -eq $ExpectedOs.Trim().ToLowerInvariant() -and $arch.Trim().ToLowerInvariant() -eq 'amd64') {
        $platformValidated = $true
        $matchingPlatform = ("{0}/{1}" -f $os.Trim().ToLowerInvariant(), $arch.Trim().ToLowerInvariant())
        if ($entry.PSObject.Properties['digest']) {
          $digest = [string]$entry.digest
        }
        break
      }
    }
    if (-not $platformValidated) {
      throw ("Image '{0}' does not expose platform '{1}/amd64' in manifest list." -f $Image, $ExpectedOs)
    }
  } else {
    # Single-manifest tags do not expose per-platform entries.
    $platformValidated = $true
    if ($manifest -and $manifest.PSObject.Properties['digest']) {
      $digest = [string]$manifest.digest
    }
    $matchingPlatform = ("{0}/amd64" -f $ExpectedOs.Trim().ToLowerInvariant())
  }

  return [ordered]@{
    image = $Image
    expectedOs = $ExpectedOs.Trim().ToLowerInvariant()
    digest = $digest
    manifestList = [bool]$manifestList
    platformValidated = [bool]$platformValidated
    matchingPlatform = $matchingPlatform
  }
}

function Get-RepoDigestForImage {
  param(
    [string[]]$RepoDigests,
    [Parameter(Mandatory)][string]$Image
  )

  foreach ($entry in @($RepoDigests)) {
    $candidate = [string]$entry
    if ($candidate.StartsWith("$Image@", [System.StringComparison]::OrdinalIgnoreCase)) {
      return $candidate
    }
  }
  if ($RepoDigests -and @($RepoDigests).Count -gt 0) {
    return [string]@($RepoDigests)[0]
  }
  return ''
}

function Ensure-LocalImageAvailability {
  param(
    [Parameter(Mandatory)][string]$Image,
    [bool]$BootstrapIfMissing
  )

  $result = [ordered]@{
    attempted = [bool]$BootstrapIfMissing
    pulled = $false
    imagePresent = $false
    localImageId = ''
    localRepoDigest = ''
    localDigest = ''
    pullDurationMs = 0
    pullError = ''
  }

  $inspect = Invoke-DockerCommand -Arguments @('image', 'inspect', $Image, '--format', '{{json .}}') -TimeoutSeconds $CommandTimeoutSeconds -IgnoreExitCode
  if ($inspect.TimedOut) {
    throw ("docker image inspect timed out for '{0}' after {1}s." -f $Image, [Math]::Max(5, [int]$CommandTimeoutSeconds))
  }
  if ($inspect.ExitCode -ne 0 -and $BootstrapIfMissing) {
    $pullStart = Get-Date
    $pull = Invoke-DockerCommand -Arguments @('pull', $Image) -TimeoutSeconds $BootstrapPullTimeoutSeconds -IgnoreExitCode
    $result.pullDurationMs = [int]([Math]::Round(((Get-Date) - $pullStart).TotalMilliseconds))
    if ($pull.TimedOut) {
      $result.pullError = ("docker pull timed out for '{0}' after {1}s." -f $Image, [Math]::Max(5, [int]$BootstrapPullTimeoutSeconds))
      throw $result.pullError
    }
    if ($pull.ExitCode -ne 0) {
      $result.pullError = [string]$pull.Text
      throw ("docker pull failed for '{0}' (exit={1}). Output: {2}" -f $Image, $pull.ExitCode, $pull.Text)
    }
    $result.pulled = $true
    $inspect = Invoke-DockerCommand -Arguments @('image', 'inspect', $Image, '--format', '{{json .}}') -TimeoutSeconds $CommandTimeoutSeconds -IgnoreExitCode
    if ($inspect.TimedOut) {
      throw ("docker image inspect timed out for '{0}' after pull (limit {1}s)." -f $Image, [Math]::Max(5, [int]$CommandTimeoutSeconds))
    }
  }

  if ($inspect.ExitCode -ne 0) {
    throw ("Local image inspect failed for '{0}'. Use docker pull to bootstrap and retry. Output: {1}" -f $Image, $inspect.Text)
  }

  $inspectText = $inspect.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($inspectText)) {
    throw ("Local image inspect returned empty payload for '{0}'." -f $Image)
  }

  $inspectJson = $inspectText | ConvertFrom-Json -Depth 20
  $repoDigests = @()
  if ($inspectJson.PSObject.Properties['RepoDigests']) {
    $repoDigests = @($inspectJson.RepoDigests | ForEach-Object { [string]$_ })
  }
  $repoDigest = Get-RepoDigestForImage -RepoDigests $repoDigests -Image $Image
  $digest = ''
  if ($repoDigest -match '@(?<digest>sha256:[0-9a-fA-F]+)$') {
    $digest = [string]$Matches['digest']
  }

  $result.imagePresent = $true
  if ($inspectJson.PSObject.Properties['Id']) {
    $result.localImageId = [string]$inspectJson.Id
  }
  $result.localRepoDigest = $repoDigest
  $result.localDigest = $digest

  return $result
}

function Invoke-ContainerRuntimeProbe {
  param(
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string]$ExpectedOs,
    [Parameter(Mandatory)][string]$ProbeCommand
  )

  $args = @('run', '--rm')
  if ($ExpectedOs -eq 'windows') {
    $args += @('--entrypoint', 'powershell', $Image, '-NoLogo', '-NoProfile', '-Command', $ProbeCommand)
  } else {
    $args += @('--entrypoint', '/bin/sh', $Image, '-lc', $ProbeCommand)
  }

  $start = Get-Date
  $probe = Invoke-DockerCommand -Arguments $args -TimeoutSeconds $ProbeTimeoutSeconds -IgnoreExitCode
  $durationMs = [int]([Math]::Round(((Get-Date) - $start).TotalMilliseconds))
  $text = if ($probe.TimedOut) {
    "docker run timed out after {0}s." -f [Math]::Max(5, [int]$ProbeTimeoutSeconds)
  } else {
    [string]$probe.Text
  }
  if ($text.Length -gt 2000) {
    $text = $text.Substring(0, 2000)
  }

  return [ordered]@{
    attempted = $true
    status = if ($probe.TimedOut) { 'timeout' } elseif ($probe.ExitCode -eq 0) { 'success' } else { 'failure' }
    exitCode = if ($probe.TimedOut) { 124 } else { [int]$probe.ExitCode }
    durationMs = $durationMs
    output = $text
    command = ($args -join ' ')
    error = if ($probe.TimedOut -or $probe.ExitCode -ne 0) { $text } else { '' }
  }
}

function Should-IncludeLane {
  param(
    [Parameter(Mandatory)][string]$Scope,
    [Parameter(Mandatory)][string]$Lane
  )

  $normalized = $Scope.Trim().ToLowerInvariant()
  switch ($normalized) {
    'both' { return $true }
    'windows' { return ($Lane -eq 'windows') }
    'linux' { return ($Lane -eq 'linux') }
    default { return $false }
  }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker CLI not found on host. Install Docker Desktop and ensure docker.exe is available.'
}

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputJsonResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$includeWindows = Should-IncludeLane -Scope $ProbeScope -Lane 'windows'
$includeLinux = Should-IncludeLane -Scope $ProbeScope -Lane 'linux'
if (-not $includeWindows -and -not $includeLinux) {
  throw ("ProbeScope '{0}' did not resolve to any lanes." -f $ProbeScope)
}

$summary = [ordered]@{
  schema = 'docker-runtime-manager@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  host = [ordered]@{
    machineName = $env:COMPUTERNAME
    runnerName = $env:RUNNER_NAME
    userName = $env:USERNAME
    osVersion = [System.Environment]::OSVersion.VersionString
    platform = [string][System.Environment]::OSVersion.Platform
  }
  settings = [ordered]@{
    windowsImage = $WindowsImage
    linuxImage = $LinuxImage
    windowsContext = $WindowsContext
    linuxContext = $LinuxContext
    restoreContext = $RestoreContext
    restoreExpectedOs = ''
    probeScope = $ProbeScope
    bootstrapWindowsImage = [bool]$BootstrapWindowsImage
    bootstrapLinuxImage = [bool]$BootstrapLinuxImage
    windowsProbeCommand = $WindowsProbeCommand
    linuxProbeCommand = $LinuxProbeCommand
    switchTimeoutSeconds = [int]$SwitchTimeoutSeconds
    switchRetryCount = [int]$SwitchRetryCount
    switchRetryDelaySeconds = [int]$SwitchRetryDelaySeconds
    lockWaitSeconds = [int]$LockWaitSeconds
    commandTimeoutSeconds = [int]$CommandTimeoutSeconds
    bootstrapPullTimeoutSeconds = [int]$BootstrapPullTimeoutSeconds
    probeTimeoutSeconds = [int]$ProbeTimeoutSeconds
  }
  lock = [ordered]@{
    path = ''
    acquired = $false
    acquiredAtUtc = ''
  }
  contexts = [ordered]@{
    start = ''
    startOsType = ''
    final = ''
    finalOsType = ''
  }
  probes = [ordered]@{
    windows = [ordered]@{
      enabled = [bool]$includeWindows
      status = if ($includeWindows) { 'pending' } else { 'skipped' }
      context = $WindowsContext
      osType = ''
      image = $WindowsImage
      digest = ''
      matchingPlatform = ''
      attempts = 0
      error = ''
      bootstrap = [ordered]@{
        attempted = $false
        pulled = $false
        imagePresent = $false
        localImageId = ''
        localRepoDigest = ''
        localDigest = ''
        pullDurationMs = 0
        pullError = ''
      }
      probe = [ordered]@{
        attempted = $false
        status = 'not-run'
        exitCode = -1
        durationMs = 0
        output = ''
        command = ''
        error = ''
      }
    }
    linux = [ordered]@{
      enabled = [bool]$includeLinux
      status = if ($includeLinux) { 'pending' } else { 'skipped' }
      context = $LinuxContext
      osType = ''
      image = $LinuxImage
      digest = ''
      matchingPlatform = ''
      attempts = 0
      error = ''
      bootstrap = [ordered]@{
        attempted = $false
        pulled = $false
        imagePresent = $false
        localImageId = ''
        localRepoDigest = ''
        localDigest = ''
        pullDurationMs = 0
        pullError = ''
      }
      probe = [ordered]@{
        attempted = $false
        status = 'not-run'
        exitCode = -1
        durationMs = 0
        output = ''
        command = ''
        error = ''
      }
    }
  }
  status = 'failure'
  failureClass = 'preflight'
  failureMessage = ''
  durationMs = 0
}

$runStart = Get-Date
$lockStream = $null
$caught = $null
$restoreExpectedOs = if ([string]::Equals($RestoreContext, $LinuxContext, [System.StringComparison]::OrdinalIgnoreCase)) { 'linux' } else { 'windows' }
$summary.settings.restoreExpectedOs = $restoreExpectedOs

try {
  $runnerTemp = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [System.IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
  $lockPath = Join-Path $runnerTemp 'docker-runtime-manager\engine-switch.lock'
  $summary.lock.path = $lockPath
  $lockStream = Acquire-LockStream -LockPath $lockPath -WaitSeconds $LockWaitSeconds
  $summary.lock.acquired = $true
  $summary.lock.acquiredAtUtc = (Get-Date).ToUniversalTime().ToString('o')

  $contextStart = ''
  try {
    $contextStart = (Invoke-DockerCommand -Arguments @('context', 'show') -TimeoutSeconds $CommandTimeoutSeconds).Text.Trim()
  } catch {
    $contextStart = 'unknown'
  }
  if ([string]::IsNullOrWhiteSpace($contextStart)) { $contextStart = 'unknown' }
  $summary.contexts.start = $contextStart

  try {
    $startOsProbe = Invoke-DockerCommand -Arguments @('info', '--format', '{{.OSType}}') -TimeoutSeconds $CommandTimeoutSeconds -IgnoreExitCode
    if ($startOsProbe.ExitCode -eq 0) {
      $summary.contexts.startOsType = $startOsProbe.Text.Trim().ToLowerInvariant()
    }
  } catch {}

  if ($includeWindows) {
    $windowsSwitch = Set-ContextAndWait `
      -ContextName $WindowsContext `
      -ExpectedOsType 'windows' `
      -TimeoutSeconds $SwitchTimeoutSeconds `
      -RetryCount $SwitchRetryCount `
      -RetryDelaySeconds $SwitchRetryDelaySeconds

    $summary.probes.windows.status = 'success'
    $summary.probes.windows.osType = [string]$windowsSwitch.OsType
    $summary.probes.windows.attempts = [int]$windowsSwitch.Attempt

    $windowsManifest = Get-ImageProbeResult -Image $WindowsImage -ExpectedOs 'windows'
    $summary.probes.windows.digest = [string]$windowsManifest.digest
    $summary.probes.windows.matchingPlatform = [string]$windowsManifest.matchingPlatform

    $windowsBootstrap = Ensure-LocalImageAvailability -Image $WindowsImage -BootstrapIfMissing:$BootstrapWindowsImage
    $summary.probes.windows.bootstrap.attempted = [bool]$windowsBootstrap.attempted
    $summary.probes.windows.bootstrap.pulled = [bool]$windowsBootstrap.pulled
    $summary.probes.windows.bootstrap.imagePresent = [bool]$windowsBootstrap.imagePresent
    $summary.probes.windows.bootstrap.localImageId = [string]$windowsBootstrap.localImageId
    $summary.probes.windows.bootstrap.localRepoDigest = [string]$windowsBootstrap.localRepoDigest
    $summary.probes.windows.bootstrap.localDigest = [string]$windowsBootstrap.localDigest
    $summary.probes.windows.bootstrap.pullDurationMs = [int]$windowsBootstrap.pullDurationMs
    $summary.probes.windows.bootstrap.pullError = [string]$windowsBootstrap.pullError

    $windowsProbe = Invoke-ContainerRuntimeProbe -Image $WindowsImage -ExpectedOs 'windows' -ProbeCommand $WindowsProbeCommand
    $summary.probes.windows.probe = $windowsProbe
    if ([string]$windowsProbe.status -ne 'success') {
      throw ("Runtime probe failed for Windows image '{0}' (exit={1})." -f $WindowsImage, [int]$windowsProbe.exitCode)
    }
  }

  if ($includeLinux) {
    $linuxSwitch = Set-ContextAndWait `
      -ContextName $LinuxContext `
      -ExpectedOsType 'linux' `
      -TimeoutSeconds $SwitchTimeoutSeconds `
      -RetryCount $SwitchRetryCount `
      -RetryDelaySeconds $SwitchRetryDelaySeconds

    $summary.probes.linux.status = 'success'
    $summary.probes.linux.osType = [string]$linuxSwitch.OsType
    $summary.probes.linux.attempts = [int]$linuxSwitch.Attempt

    $linuxManifest = Get-ImageProbeResult -Image $LinuxImage -ExpectedOs 'linux'
    $summary.probes.linux.digest = [string]$linuxManifest.digest
    $summary.probes.linux.matchingPlatform = [string]$linuxManifest.matchingPlatform

    $linuxBootstrap = Ensure-LocalImageAvailability -Image $LinuxImage -BootstrapIfMissing:$BootstrapLinuxImage
    $summary.probes.linux.bootstrap.attempted = [bool]$linuxBootstrap.attempted
    $summary.probes.linux.bootstrap.pulled = [bool]$linuxBootstrap.pulled
    $summary.probes.linux.bootstrap.imagePresent = [bool]$linuxBootstrap.imagePresent
    $summary.probes.linux.bootstrap.localImageId = [string]$linuxBootstrap.localImageId
    $summary.probes.linux.bootstrap.localRepoDigest = [string]$linuxBootstrap.localRepoDigest
    $summary.probes.linux.bootstrap.localDigest = [string]$linuxBootstrap.localDigest
    $summary.probes.linux.bootstrap.pullDurationMs = [int]$linuxBootstrap.pullDurationMs
    $summary.probes.linux.bootstrap.pullError = [string]$linuxBootstrap.pullError

    $linuxProbe = Invoke-ContainerRuntimeProbe -Image $LinuxImage -ExpectedOs 'linux' -ProbeCommand $LinuxProbeCommand
    $summary.probes.linux.probe = $linuxProbe
    if ([string]$linuxProbe.status -ne 'success') {
      throw ("Runtime probe failed for Linux image '{0}' (exit={1})." -f $LinuxImage, [int]$linuxProbe.exitCode)
    }
  }

  $summary.status = 'success'
  $summary.failureClass = 'none'
  $summary.failureMessage = ''
} catch {
  $caught = $_
  $message = $_.Exception.Message
  $summary.status = 'failure'
  if ($message -match '(?i)docker pull timed out') {
    $summary.failureClass = 'image-bootstrap-timeout'
  } elseif ($message -match '(?i)runtime probe failed.+exit=124|docker run timed out') {
    $summary.failureClass = 'runtime-probe-timeout'
  } elseif ($message -match '(?i)docker .+timed out') {
    $summary.failureClass = 'docker-command-timeout'
  } elseif ($message -match '(?i)failed to switch docker context|did not reach expected ostype|docker engine switch|timed out waiting for docker manager lock') {
    $summary.failureClass = 'runtime-determinism'
  } elseif ($message -match '(?i)docker pull failed|local image inspect failed') {
    $summary.failureClass = 'image-bootstrap'
  } elseif ($message -match '(?i)runtime probe failed') {
    $summary.failureClass = 'runtime-probe'
  } else {
    $summary.failureClass = 'preflight'
  }
  $summary.failureMessage = $message

  if ($message -match '(?i)docker pull timed out') {
    if ($includeWindows -and [string]::IsNullOrWhiteSpace([string]$summary.probes.windows.bootstrap.pullError)) {
      $summary.probes.windows.bootstrap.attempted = [bool]$BootstrapWindowsImage
      $summary.probes.windows.bootstrap.pullError = $message
    }
    if ($includeLinux -and [string]::IsNullOrWhiteSpace([string]$summary.probes.linux.bootstrap.pullError)) {
      $summary.probes.linux.bootstrap.attempted = [bool]$BootstrapLinuxImage
      $summary.probes.linux.bootstrap.pullError = $message
    }
  }

  if ($message -match '(?i)runtime probe failed.+exit=124|docker run timed out') {
    if ($includeWindows -and [string]::Equals([string]$summary.probes.windows.probe.status, 'not-run', [System.StringComparison]::OrdinalIgnoreCase)) {
      $summary.probes.windows.probe.attempted = $true
      $summary.probes.windows.probe.status = 'timeout'
      $summary.probes.windows.probe.exitCode = 124
      $summary.probes.windows.probe.error = $message
    }
    if ($includeLinux -and [string]::Equals([string]$summary.probes.linux.probe.status, 'not-run', [System.StringComparison]::OrdinalIgnoreCase)) {
      $summary.probes.linux.probe.attempted = $true
      $summary.probes.linux.probe.status = 'timeout'
      $summary.probes.linux.probe.exitCode = 124
      $summary.probes.linux.probe.error = $message
    }
  }

  if ($includeWindows -and $summary.probes.windows.status -eq 'pending') {
    $summary.probes.windows.status = 'failure'
    $summary.probes.windows.error = $message
  } elseif ($includeLinux -and $summary.probes.linux.status -eq 'pending') {
    $summary.probes.linux.status = 'failure'
    $summary.probes.linux.error = $message
  }
} finally {
  try {
    $restored = Set-ContextAndWait `
      -ContextName $RestoreContext `
      -ExpectedOsType $restoreExpectedOs `
      -TimeoutSeconds ([Math]::Min($SwitchTimeoutSeconds, 120)) `
      -RetryCount $SwitchRetryCount `
      -RetryDelaySeconds $SwitchRetryDelaySeconds
    $summary.contexts.final = [string]$restored.Context
    $summary.contexts.finalOsType = [string]$restored.OsType
  } catch {
    if ($summary.status -eq 'success') {
      $summary.status = 'failure'
      $summary.failureClass = 'runtime-determinism'
      $summary.failureMessage = ("Failed to restore Docker context '{0}': {1}" -f $RestoreContext, $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace([string]$summary.contexts.final)) {
      $summary.contexts.final = 'unknown'
    }
    if ([string]::IsNullOrWhiteSpace([string]$summary.contexts.finalOsType)) {
      $summary.contexts.finalOsType = 'unknown'
    }
  }

  if ($lockStream) {
    $lockStream.Dispose()
    $lockStream = $null
  }

  $summary.durationMs = [int]([Math]::Round(((Get-Date) - $runStart).TotalMilliseconds))
  ($summary | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

  $windowsDigestOut = if (-not [string]::IsNullOrWhiteSpace([string]$summary.probes.windows.bootstrap.localDigest)) {
    [string]$summary.probes.windows.bootstrap.localDigest
  } else {
    [string]$summary.probes.windows.digest
  }
  $linuxDigestOut = if (-not [string]::IsNullOrWhiteSpace([string]$summary.probes.linux.bootstrap.localDigest)) {
    [string]$summary.probes.linux.bootstrap.localDigest
  } else {
    [string]$summary.probes.linux.digest
  }

  Write-GitHubOutput -Key 'manager_status' -Value ([string]$summary.status) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'manager_summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'windows_image_digest' -Value $windowsDigestOut -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'linux_image_digest' -Value $linuxDigestOut -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'start_context' -Value ([string]$summary.contexts.start) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'final_context' -Value ([string]$summary.contexts.final) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'windows_bootstrap_status' -Value ([string]$summary.probes.windows.bootstrap.imagePresent).ToLowerInvariant() -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'linux_bootstrap_status' -Value ([string]$summary.probes.linux.bootstrap.imagePresent).ToLowerInvariant() -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'windows_probe_status' -Value ([string]$summary.probes.windows.probe.status) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'linux_probe_status' -Value ([string]$summary.probes.linux.probe.status) -Path $GitHubOutputPath

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $lines = @(
      '### Docker Runtime Manager',
      '',
      ('- status: `{0}`' -f [string]$summary.status),
      ('- start context: `{0}` (`{1}`)' -f [string]$summary.contexts.start, [string]$summary.contexts.startOsType),
      ('- final context: `{0}` (`{1}`)' -f [string]$summary.contexts.final, [string]$summary.contexts.finalOsType),
      ('- windows image: `{0}` manifestDigest=`{1}` localDigest=`{2}` pulled=`{3}` probe=`{4}`' -f [string]$summary.probes.windows.image, [string]$summary.probes.windows.digest, [string]$summary.probes.windows.bootstrap.localDigest, [bool]$summary.probes.windows.bootstrap.pulled, [string]$summary.probes.windows.probe.status),
      ('- linux image: `{0}` manifestDigest=`{1}` localDigest=`{2}` pulled=`{3}` probe=`{4}`' -f [string]$summary.probes.linux.image, [string]$summary.probes.linux.digest, [string]$summary.probes.linux.bootstrap.localDigest, [bool]$summary.probes.linux.bootstrap.pulled, [string]$summary.probes.linux.probe.status),
      ('- summary json: `{0}`' -f $outputJsonResolved)
    )
    if ($summary.status -ne 'success' -and -not [string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
      $lines += ('- failure class: `{0}`' -f [string]$summary.failureClass)
      $lines += ('- failure: {0}' -f [string]$summary.failureMessage)
    }
    $stepSummaryResolved = Resolve-AbsolutePath -Path $StepSummaryPath
    $stepSummaryParent = Split-Path -Parent $stepSummaryResolved
    if ($stepSummaryParent -and -not (Test-Path -LiteralPath $stepSummaryParent -PathType Container)) {
      New-Item -ItemType Directory -Path $stepSummaryParent -Force | Out-Null
    }
    $lines -join "`n" | Out-File -FilePath $stepSummaryResolved -Append -Encoding utf8
  }
}

if ($caught -or $summary.status -ne 'success') {
  if ($caught) { throw $caught }
  throw ("Docker runtime manager failed: {0}" -f [string]$summary.failureMessage)
}

Write-Output $outputJsonResolved
