#Requires -Version 7.0
<#
.SYNOPSIS
  Deterministic host preflight for the NI LabVIEW 2026 q1 Windows container image.

.DESCRIPTION
  Supports two execution surfaces:

  - `desktop-local`: uses the Docker runtime manager to probe a local
    Docker Desktop Windows engine and bootstrap the pinned NI image.
  - `github-hosted-windows`: validates a hosted Windows Docker engine without
    any host mutation, then bootstraps and probes the pinned NI image directly.

  The output is normalized into a stable `comparevi/windows-host-preflight@v1`
  contract so local tooling, hosted workflows, and bundle consumers can share
  one preflight artifact shape.
#>
[CmdletBinding()]
param(
  [string]$Image = 'nationalinstruments/labview:2026q1-windows',
  [string]$ResultsDir = 'tests/results/local-parity',
  [ValidateSet('desktop-local', 'github-hosted-windows')]
  [string]$ExecutionSurface = 'desktop-local',
  [bool]$ManageDockerEngine = $false,
  [bool]$AllowHostEngineMutation = $false,
  [string]$HostPlatformOverride = '',
  [ValidateRange(5, 600)]
  [int]$CommandTimeoutSeconds = 45,
  [ValidateRange(5, 3600)]
  [int]$BootstrapPullTimeoutSeconds = 900,
  [ValidateRange(5, 900)]
  [int]$RuntimeProbeTimeoutSeconds = 180,
  [switch]$AllowUnavailable,
  [string]$OutputJsonPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param([Parameter(Mandatory)][string]$Path)
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
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

function Resolve-PathWithinRepo {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RelativePath
  )

  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $RelativePath))
}

function Test-IsHostedRuntimeUnavailableMessage {
  param([Parameter(Mandatory)][string]$Message)

  if ($Message -match 'docker-info-command-failed') { return $true }
  if ($Message -match 'observed Docker OSType is empty') { return $true }
  if ($Message -match 'docker API at npipe:////\./pipe/docker_engine') { return $true }
  if ($Message -match 'The system cannot find the file specified') { return $true }
  return $false
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

function Get-DesktopDockerObservation {
  $contextResult = Invoke-DockerCommand -Arguments @('context', 'show') -IgnoreExitCode
  $infoResult = Invoke-DockerCommand -Arguments @('info', '--format', '{{.OSType}}') -IgnoreExitCode

  $context = ''
  if ($contextResult.ExitCode -eq 0) {
    $context = [string]($contextResult.Text ?? '').Trim()
  }

  $osType = ''
  if ($infoResult.ExitCode -eq 0) {
    $osType = [string]($infoResult.Text ?? '').Trim()
  }

  return [ordered]@{
    context = $context
    osType = $osType
    contextExitCode = [int]$contextResult.ExitCode
    contextError = [string]$contextResult.Text
    infoExitCode = [int]$infoResult.ExitCode
    infoError = [string]$infoResult.Text
  }
}

function Ensure-LocalImageAvailability {
  param(
    [Parameter(Mandatory)][string]$Image
  )

  $result = [ordered]@{
    attempted = $true
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
  if ($inspect.ExitCode -ne 0) {
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
    throw ("Local image inspect failed for '{0}'. Output: {1}" -f $Image, $inspect.Text)
  }

  $inspectJson = $inspect.Text.Trim() | ConvertFrom-Json -Depth 20
  $repoDigests = @()
  if ($inspectJson.PSObject.Properties['RepoDigests']) {
    $repoDigests = @($inspectJson.RepoDigests | ForEach-Object { [string]$_ })
  }
  $repoDigest = if ($repoDigests.Count -gt 0) { [string]$repoDigests[0] } else { '' }
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
    [Parameter(Mandatory)][string]$Image
  )

  $args = @(
    'run',
    '--rm',
    '--entrypoint', 'powershell',
    $Image,
    '-NoLogo',
    '-NoProfile',
    '-Command',
    "[Console]::WriteLine('ni-runtime-probe-ok')"
  )

  $start = Get-Date
  $probe = Invoke-DockerCommand -Arguments $args -TimeoutSeconds $RuntimeProbeTimeoutSeconds -IgnoreExitCode
  $durationMs = [int]([Math]::Round(((Get-Date) - $start).TotalMilliseconds))
  $text = if ($probe.TimedOut) {
    "docker run timed out after {0}s." -f [Math]::Max(5, [int]$RuntimeProbeTimeoutSeconds)
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

$repoRoot = Resolve-AbsolutePath -Path (Join-Path $PSScriptRoot '..')
$runtimeManagerScript = Resolve-PathWithinRepo -RepoRoot $repoRoot -RelativePath 'tools/Invoke-DockerRuntimeManager.ps1'
$runtimeGuardScript = Resolve-PathWithinRepo -RepoRoot $repoRoot -RelativePath 'tools/Assert-DockerRuntimeDeterminism.ps1'
if (-not (Test-Path -LiteralPath $runtimeManagerScript -PathType Leaf)) {
  throw ("Invoke-DockerRuntimeManager.ps1 not found: {0}" -f $runtimeManagerScript)
}
if (-not (Test-Path -LiteralPath $runtimeGuardScript -PathType Leaf)) {
  throw ("Assert-DockerRuntimeDeterminism.ps1 not found: {0}" -f $runtimeGuardScript)
}

$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir
if (-not (Test-Path -LiteralPath $resultsDirResolved -PathType Container)) {
  New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null
}

$jsonPathResolved = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsDirResolved 'windows-ni-2026q1-host-preflight.json'
} else {
  Resolve-AbsolutePath -Path $OutputJsonPath
}
$jsonParent = Split-Path -Parent $jsonPathResolved
if ($jsonParent -and -not (Test-Path -LiteralPath $jsonParent -PathType Container)) {
  New-Item -ItemType Directory -Path $jsonParent -Force | Out-Null
}

$summary = [ordered]@{
  schema = 'comparevi/windows-host-preflight@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  executionSurface = $ExecutionSurface
  image = $Image
  status = 'pending'
  failureClass = 'none'
  failureMessage = ''
  dockerHost = if ([string]::IsNullOrWhiteSpace($env:DOCKER_HOST)) { '' } else { [string]$env:DOCKER_HOST.Trim() }
  runnerEnvironment = if ([string]::IsNullOrWhiteSpace($env:RUNNER_ENVIRONMENT)) { '' } else { [string]$env:RUNNER_ENVIRONMENT }
  contexts = [ordered]@{
    start = ''
    startOsType = ''
    final = ''
    finalOsType = ''
  }
  runtimeProvider = ''
  runtimeDeterminism = [ordered]@{
    status = ''
    reason = ''
    snapshotPath = ''
    failureClass = ''
  }
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
  hostedContract = [ordered]@{
    hostEngineMutationAllowed = $false
    expectedContext = if ($ExecutionSurface -eq 'github-hosted-windows') { 'default' } else { 'desktop-windows' }
    expectedOs = 'windows'
  }
}

$snapshotPath = ''

try {
  if ($ExecutionSurface -eq 'desktop-local') {
    $summary.runtimeProvider = 'docker-desktop'
    $desktopObservation = Get-DesktopDockerObservation
    $summary.contexts.start = [string]$desktopObservation.context
    $summary.contexts.startOsType = [string]$desktopObservation.osType
    $summary.contexts.final = [string]$desktopObservation.context
    $summary.contexts.finalOsType = [string]$desktopObservation.osType

    $canMutateDesktopEngine = $ManageDockerEngine -and $AllowHostEngineMutation
    if ([string]::Equals([string]$desktopObservation.osType, 'linux', [System.StringComparison]::OrdinalIgnoreCase) -and -not $canMutateDesktopEngine) {
      $summary.status = 'failure'
      $summary.failureClass = 'docker-engine-mismatch'
      $summary.failureMessage = ("desktop-local Windows NI preflight requires Docker Desktop Windows containers. Observed context '{0}' with OSType '{1}'. Switch Docker Desktop to Windows containers (`desktop-windows`) and retry." -f ([string]$desktopObservation.context ?? ''), [string]$desktopObservation.osType)
      $summary.runtimeDeterminism.status = 'mismatch'
      $summary.runtimeDeterminism.reason = 'desktop-local-windows-preflight-requires-windows-engine'
      $summary.runtimeDeterminism.failureClass = 'docker-engine-mismatch'
      throw $summary.failureMessage
    }

    $managerOutput = @(& $runtimeManagerScript `
      -ProbeScope 'windows' `
      -WindowsImage $Image `
      -BootstrapWindowsImage:$true `
      -BootstrapLinuxImage:$false `
      -CommandTimeoutSeconds $CommandTimeoutSeconds `
      -BootstrapPullTimeoutSeconds $BootstrapPullTimeoutSeconds `
      -ProbeTimeoutSeconds $RuntimeProbeTimeoutSeconds `
      -RestoreContext 'desktop-windows' `
      -OutputJsonPath $jsonPathResolved `
      -GitHubOutputPath '' `
      -StepSummaryPath '')
    $managerPath = @($managerOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
    if ($managerPath.Count -eq 0) {
      throw 'Docker runtime manager did not return an output path.'
    }
    $managerPathResolved = Resolve-AbsolutePath -Path $managerPath[0]
    if (-not (Test-Path -LiteralPath $managerPathResolved -PathType Leaf)) {
      throw ("Docker runtime manager output path was not written: {0}" -f $managerPathResolved)
    }

    $manager = Get-Content -LiteralPath $managerPathResolved -Raw | ConvertFrom-Json -Depth 20
    $summary.contexts.start = [string]$manager.contexts.start
    $summary.contexts.startOsType = [string]$manager.contexts.startOsType
    $summary.contexts.final = [string]$manager.contexts.final
    $summary.contexts.finalOsType = [string]$manager.contexts.finalOsType
    $summary.bootstrap = [ordered]@{
      attempted = [bool]$manager.probes.windows.bootstrap.attempted
      pulled = [bool]$manager.probes.windows.bootstrap.pulled
      imagePresent = [bool]$manager.probes.windows.bootstrap.imagePresent
      localImageId = [string]$manager.probes.windows.bootstrap.localImageId
      localRepoDigest = [string]$manager.probes.windows.bootstrap.localRepoDigest
      localDigest = [string]$manager.probes.windows.bootstrap.localDigest
      pullDurationMs = [int]$manager.probes.windows.bootstrap.pullDurationMs
      pullError = [string]$manager.probes.windows.bootstrap.pullError
    }
    $summary.probe = [ordered]@{
      attempted = [bool]$manager.probes.windows.probe.attempted
      status = [string]$manager.probes.windows.probe.status
      exitCode = [int]$manager.probes.windows.probe.exitCode
      durationMs = [int]$manager.probes.windows.probe.durationMs
      output = [string]$manager.probes.windows.probe.output
      command = [string]$manager.probes.windows.probe.command
      error = [string]$manager.probes.windows.probe.error
    }
    $summary.runtimeDeterminism.status = 'success'
    $summary.status = if ([string]::Equals([string]$manager.status, 'success', [System.StringComparison]::OrdinalIgnoreCase)) { 'ready' } else { 'warning' }
  } else {
    $summary.runtimeProvider = 'github-hosted-windows'
    $snapshotPath = Join-Path $resultsDirResolved 'windows-hosted-runtime-determinism.json'
    & pwsh -NoLogo -NoProfile -File $runtimeGuardScript `
      -ExpectedOsType 'windows' `
      -RuntimeProvider 'desktop' `
      -ExpectedContext 'default' `
      -AutoRepair:$true `
      -ManageDockerEngine:$ManageDockerEngine `
      -AllowHostEngineMutation:$AllowHostEngineMutation `
      -HostPlatformOverride $HostPlatformOverride `
      -CommandTimeoutSeconds $CommandTimeoutSeconds `
      -SnapshotPath $snapshotPath `
      -GitHubOutputPath ''
    if ($LASTEXITCODE -ne 0) {
      throw ("Assert-DockerRuntimeDeterminism.ps1 failed with exit code {0}." -f $LASTEXITCODE)
    }

    $snapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 20
    $summary.contexts.start = [string]$snapshot.observed.context
    $summary.contexts.startOsType = [string]$snapshot.observed.osType
    $summary.contexts.final = [string]$snapshot.observed.context
    $summary.contexts.finalOsType = [string]$snapshot.observed.osType
    if ($snapshot.observed.PSObject.Properties['dockerHost']) {
      $summary.dockerHost = [string]$snapshot.observed.dockerHost
    }
    $summary.runtimeDeterminism.status = [string]$snapshot.result.status
    $summary.runtimeDeterminism.reason = [string]$snapshot.result.reason
    $summary.runtimeDeterminism.snapshotPath = $snapshotPath
    $summary.runtimeDeterminism.failureClass = [string]$snapshot.result.failureClass

    $bootstrap = Ensure-LocalImageAvailability -Image $Image
    $summary.bootstrap = $bootstrap

    $probe = Invoke-ContainerRuntimeProbe -Image $Image
    $summary.probe = $probe
    if ([string]$probe.status -ne 'success') {
      throw ("Hosted Windows runtime probe failed for image '{0}' (exit={1})." -f $Image, [int]$probe.exitCode)
    }

    $summary.status = 'ready'
  }
} catch {
  $failureMessage = [string]$_.Exception.Message
  $handledUnavailable = $false
  if ($snapshotPath -and (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
    try {
      $failureSnapshot = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -Depth 20
      if ($failureSnapshot.PSObject.Properties['observed']) {
        if ($failureSnapshot.observed.PSObject.Properties['context']) {
          $summary.contexts.start = [string]$failureSnapshot.observed.context
          $summary.contexts.final = [string]$failureSnapshot.observed.context
        }
        if ($failureSnapshot.observed.PSObject.Properties['osType']) {
          $summary.contexts.startOsType = [string]$failureSnapshot.observed.osType
          $summary.contexts.finalOsType = [string]$failureSnapshot.observed.osType
        }
        if ($failureSnapshot.observed.PSObject.Properties['dockerHost']) {
          $summary.dockerHost = [string]$failureSnapshot.observed.dockerHost
        }
      }
      if ($failureSnapshot.PSObject.Properties['result']) {
        if ($failureSnapshot.result.PSObject.Properties['status']) {
          $summary.runtimeDeterminism.status = [string]$failureSnapshot.result.status
        }
        if ($failureSnapshot.result.PSObject.Properties['reason']) {
          $summary.runtimeDeterminism.reason = [string]$failureSnapshot.result.reason
          if (-not [string]::IsNullOrWhiteSpace([string]$failureSnapshot.result.reason)) {
            $failureMessage = "{0} {1}" -f $failureMessage, [string]$failureSnapshot.result.reason
          }
        }
        if ($failureSnapshot.result.PSObject.Properties['failureClass']) {
          $summary.runtimeDeterminism.failureClass = [string]$failureSnapshot.result.failureClass
        }
      }
      $summary.runtimeDeterminism.snapshotPath = $snapshotPath
    } catch {
      # Keep the original wrapper error when snapshot hydration fails.
    }
  }

  if ($AllowUnavailable -and
      $ExecutionSurface -eq 'github-hosted-windows' -and
      (Test-IsHostedRuntimeUnavailableMessage -Message $failureMessage)) {
    $summary.status = 'unavailable'
    $summary.failureClass = 'docker-runtime-unavailable'
    $summary.failureMessage = $failureMessage
    $summary.runtimeDeterminism.status = 'unavailable'
    $summary.runtimeDeterminism.reason = 'docker-daemon-unavailable'
    $summary.runtimeDeterminism.failureClass = 'docker-runtime-unavailable'
    if ($snapshotPath -and -not [string]::IsNullOrWhiteSpace($snapshotPath)) {
      $summary.runtimeDeterminism.snapshotPath = $snapshotPath
    }
    $handledUnavailable = $true
  }

  if (-not $handledUnavailable) {
    $summary.status = 'failure'
    if ($failureMessage -match '(?i)docker pull timed out') {
      $summary.failureClass = 'image-bootstrap-timeout'
      $summary.bootstrap.attempted = $true
      $summary.bootstrap.pullError = $failureMessage
    } elseif ($failureMessage -match '(?i)runtime probe timed out|docker run timed out|Hosted Windows runtime probe failed.+exit=124') {
      $summary.failureClass = 'runtime-probe-timeout'
      $summary.probe.attempted = $true
      $summary.probe.status = 'timeout'
      $summary.probe.exitCode = 124
      $summary.probe.error = $failureMessage
    } elseif ($failureMessage -match '(?i)docker .+timed out') {
      $summary.failureClass = 'docker-command-timeout'
    } elseif ([string]::IsNullOrWhiteSpace([string]$summary.failureClass) -or [string]::Equals([string]$summary.failureClass, 'none', [System.StringComparison]::OrdinalIgnoreCase)) {
      $summary.failureClass = 'preflight-failed'
    }
    if ([string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
      $summary.failureMessage = $failureMessage
    }
    ($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPathResolved -Encoding utf8
    throw
  }
}

($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPathResolved -Encoding utf8

Write-GitHubOutput -Key 'windows_host_preflight_path' -Value $jsonPathResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_status' -Value ([string]$summary.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_failure_class' -Value ([string]$summary.failureClass) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_surface' -Value ([string]$summary.executionSurface) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_docker_host' -Value ([string]$summary.dockerHost) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_context' -Value ([string]$summary.contexts.final) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_ostype' -Value ([string]$summary.contexts.finalOsType) -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $lines = @(
    '### Windows Host Preflight',
    '',
    ('- execution_surface: `{0}`' -f [string]$summary.executionSurface),
    ('- status: `{0}`' -f [string]$summary.status),
    ('- image: `{0}`' -f [string]$summary.image),
    ('- docker_host: `{0}`' -f [string]$summary.dockerHost),
    ('- context: `{0}`' -f [string]$summary.contexts.final),
    ('- docker_ostype: `{0}`' -f [string]$summary.contexts.finalOsType),
    ('- runtime_provider: `{0}`' -f [string]$summary.runtimeProvider)
  )
  if ($summary.bootstrap.pulled) {
    $lines += ('- image_pull_ms: `{0}`' -f [int]$summary.bootstrap.pullDurationMs)
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
    $lines += ('- failure: `{0}`' -f ([string]$summary.failureMessage -replace '`', "'"))
  }
  $lines -join "`n" | Out-File -LiteralPath (Resolve-AbsolutePath -Path $StepSummaryPath) -Encoding utf8 -Append
}

Write-Output $jsonPathResolved
