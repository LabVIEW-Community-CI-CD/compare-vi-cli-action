#Requires -Version 7.0
<#
.SYNOPSIS
  Manages Docker Desktop context transitions and validates NI image manifests.

.DESCRIPTION
  Runs on a Windows host with Docker Desktop, acquires a host lock to avoid
  concurrent engine flips, validates Windows and Linux NI image tags, and
  restores the desired final context for downstream jobs.
#>
[CmdletBinding()]
param(
  [string]$WindowsImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LinuxImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$WindowsContext = 'desktop-windows',
  [string]$LinuxContext = 'desktop-linux',
  [string]$RestoreContext = 'desktop-windows',
  [ValidateRange(30, 900)]
  [int]$SwitchTimeoutSeconds = 120,
  [ValidateRange(1, 10)]
  [int]$SwitchRetryCount = 3,
  [ValidateRange(1, 30)]
  [int]$SwitchRetryDelaySeconds = 4,
  [ValidateRange(5, 600)]
  [int]$LockWaitSeconds = 90,
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

function Invoke-DockerCommand {
  param(
    [Parameter(Mandatory)][string[]]$Arguments,
    [switch]$IgnoreExitCode
  )

  $raw = & docker @Arguments 2>&1
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
      Invoke-DockerCommand -Arguments @('context', 'use', $ContextName) | Out-Null
      $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
      do {
        $osProbe = Invoke-DockerCommand -Arguments @('info', '--format', '{{.OSType}}') -IgnoreExitCode
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

  $manifestOut = Invoke-DockerCommand -Arguments @('manifest', 'inspect', $Image)
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

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw 'Docker CLI not found on host. Install Docker Desktop and ensure docker.exe is available.'
}

$outputJsonResolved = Resolve-AbsolutePath -Path $OutputJsonPath
$outputParent = Split-Path -Parent $outputJsonResolved
if ($outputParent -and -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
}

$summary = [ordered]@{
  schema = 'docker-runtime-manager@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  host = [ordered]@{
    machineName = $env:COMPUTERNAME
    runnerName = $env:RUNNER_NAME
    userName = $env:USERNAME
  }
  settings = [ordered]@{
    windowsImage = $WindowsImage
    linuxImage = $LinuxImage
    windowsContext = $WindowsContext
    linuxContext = $LinuxContext
    restoreContext = $RestoreContext
    restoreExpectedOs = ''
    switchTimeoutSeconds = [int]$SwitchTimeoutSeconds
    switchRetryCount = [int]$SwitchRetryCount
    switchRetryDelaySeconds = [int]$SwitchRetryDelaySeconds
    lockWaitSeconds = [int]$LockWaitSeconds
  }
  lock = [ordered]@{
    path = ''
    acquired = $false
    acquiredAtUtc = ''
  }
  contexts = [ordered]@{
    start = ''
    final = ''
  }
  probes = [ordered]@{
    windows = [ordered]@{
      status = 'pending'
      context = $WindowsContext
      osType = ''
      image = $WindowsImage
      digest = ''
      matchingPlatform = ''
      attempts = 0
      error = ''
    }
    linux = [ordered]@{
      status = 'pending'
      context = $LinuxContext
      osType = ''
      image = $LinuxImage
      digest = ''
      matchingPlatform = ''
      attempts = 0
      error = ''
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
    $contextStart = (Invoke-DockerCommand -Arguments @('context', 'show')).Text.Trim()
  } catch {
    $contextStart = 'unknown'
  }
  if ([string]::IsNullOrWhiteSpace($contextStart)) { $contextStart = 'unknown' }
  $summary.contexts.start = $contextStart

  $windowsSwitch = Set-ContextAndWait `
    -ContextName $WindowsContext `
    -ExpectedOsType 'windows' `
    -TimeoutSeconds $SwitchTimeoutSeconds `
    -RetryCount $SwitchRetryCount `
    -RetryDelaySeconds $SwitchRetryDelaySeconds
  $summary.probes.windows.status = 'success'
  $summary.probes.windows.osType = [string]$windowsSwitch.OsType
  $summary.probes.windows.attempts = [int]$windowsSwitch.Attempt
  $windowsProbe = Get-ImageProbeResult -Image $WindowsImage -ExpectedOs 'windows'
  $summary.probes.windows.digest = [string]$windowsProbe.digest
  $summary.probes.windows.matchingPlatform = [string]$windowsProbe.matchingPlatform

  $linuxSwitch = Set-ContextAndWait `
    -ContextName $LinuxContext `
    -ExpectedOsType 'linux' `
    -TimeoutSeconds $SwitchTimeoutSeconds `
    -RetryCount $SwitchRetryCount `
    -RetryDelaySeconds $SwitchRetryDelaySeconds
  $summary.probes.linux.status = 'success'
  $summary.probes.linux.osType = [string]$linuxSwitch.OsType
  $summary.probes.linux.attempts = [int]$linuxSwitch.Attempt
  $linuxProbe = Get-ImageProbeResult -Image $LinuxImage -ExpectedOs 'linux'
  $summary.probes.linux.digest = [string]$linuxProbe.digest
  $summary.probes.linux.matchingPlatform = [string]$linuxProbe.matchingPlatform

  $summary.status = 'success'
  $summary.failureClass = 'none'
  $summary.failureMessage = ''
} catch {
  $caught = $_
  $summary.status = 'failure'
  $summary.failureClass = 'runtime-determinism'
  $summary.failureMessage = $_.Exception.Message
  if ($summary.probes.windows.status -eq 'pending') {
    $summary.probes.windows.status = 'failure'
    $summary.probes.windows.error = $_.Exception.Message
  } elseif ($summary.probes.linux.status -eq 'pending') {
    $summary.probes.linux.status = 'failure'
    $summary.probes.linux.error = $_.Exception.Message
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
  } catch {
    if ($summary.status -eq 'success') {
      $summary.status = 'failure'
      $summary.failureClass = 'runtime-determinism'
      $summary.failureMessage = ("Failed to restore Docker context '{0}': {1}" -f $RestoreContext, $_.Exception.Message)
    }
    if ([string]::IsNullOrWhiteSpace([string]$summary.contexts.final)) {
      $summary.contexts.final = 'unknown'
    }
  }

  if ($lockStream) {
    $lockStream.Dispose()
    $lockStream = $null
  }

  $summary.durationMs = [int]([Math]::Round(((Get-Date) - $runStart).TotalMilliseconds))
  ($summary | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $outputJsonResolved -Encoding utf8

  Write-GitHubOutput -Key 'manager_status' -Value ([string]$summary.status) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'manager_summary_path' -Value $outputJsonResolved -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'windows_image_digest' -Value ([string]$summary.probes.windows.digest) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'linux_image_digest' -Value ([string]$summary.probes.linux.digest) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'start_context' -Value ([string]$summary.contexts.start) -Path $GitHubOutputPath
  Write-GitHubOutput -Key 'final_context' -Value ([string]$summary.contexts.final) -Path $GitHubOutputPath

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $lines = @(
      '### Docker Runtime Manager',
      '',
      ('- status: `{0}`' -f [string]$summary.status),
      ('- start context: `{0}`' -f [string]$summary.contexts.start),
      ('- final context: `{0}`' -f [string]$summary.contexts.final),
      ('- windows image: `{0}` digest=`{1}`' -f [string]$summary.probes.windows.image, [string]$summary.probes.windows.digest),
      ('- linux image: `{0}` digest=`{1}`' -f [string]$summary.probes.linux.image, [string]$summary.probes.linux.digest),
      ('- summary json: `{0}`' -f $outputJsonResolved)
    )
    if ($summary.status -ne 'success' -and -not [string]::IsNullOrWhiteSpace([string]$summary.failureMessage)) {
      $lines += ("- failure: {0}" -f [string]$summary.failureMessage)
    }
    $lines -join "`n" | Out-File -FilePath (Resolve-AbsolutePath -Path $StepSummaryPath) -Append -Encoding utf8
  }
}

if ($caught -or $summary.status -ne 'success') {
  if ($caught) { throw $caught }
  throw ("Docker runtime manager failed: {0}" -f [string]$summary.failureMessage)
}

Write-Output $outputJsonResolved
