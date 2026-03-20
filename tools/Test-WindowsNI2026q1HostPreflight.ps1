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
  [string]$OutputJsonPath = '',
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
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

function Resolve-PathWithinRepo {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RelativePath
  )

  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $RelativePath))
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

  $inspect = Invoke-DockerCommand -Arguments @('image', 'inspect', $Image, '--format', '{{json .}}') -IgnoreExitCode
  if ($inspect.ExitCode -ne 0) {
    $pullStart = Get-Date
    $pull = Invoke-DockerCommand -Arguments @('pull', $Image) -IgnoreExitCode
    $result.pullDurationMs = [int]([Math]::Round(((Get-Date) - $pullStart).TotalMilliseconds))
    if ($pull.ExitCode -ne 0) {
      $result.pullError = [string]$pull.Text
      throw ("docker pull failed for '{0}' (exit={1}). Output: {2}" -f $Image, $pull.ExitCode, $pull.Text)
    }
    $result.pulled = $true
    $inspect = Invoke-DockerCommand -Arguments @('image', 'inspect', $Image, '--format', '{{json .}}') -IgnoreExitCode
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
  $probe = Invoke-DockerCommand -Arguments $args -IgnoreExitCode
  $durationMs = [int]([Math]::Round(((Get-Date) - $start).TotalMilliseconds))
  $text = [string]$probe.Text
  if ($text.Length -gt 2000) {
    $text = $text.Substring(0, 2000)
  }

  return [ordered]@{
    attempted = $true
    status = if ($probe.ExitCode -eq 0) { 'success' } else { 'failure' }
    exitCode = [int]$probe.ExitCode
    durationMs = $durationMs
    output = $text
    command = ($args -join ' ')
    error = if ($probe.ExitCode -eq 0) { '' } else { $text }
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

try {
  if ($ExecutionSurface -eq 'desktop-local') {
    $summary.runtimeProvider = 'docker-desktop'

    $managerOutput = @(& $runtimeManagerScript `
      -ProbeScope 'windows' `
      -WindowsImage $Image `
      -BootstrapWindowsImage:$true `
      -BootstrapLinuxImage:$false `
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
      -ManageDockerEngine:$false `
      -AllowHostEngineMutation:$false `
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
  $summary.status = 'failure'
  $summary.failureClass = 'preflight-failed'
  $summary.failureMessage = [string]$_.Exception.Message
  ($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPathResolved -Encoding utf8
  throw
}

($summary | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $jsonPathResolved -Encoding utf8

Write-GitHubOutput -Key 'windows_host_preflight_path' -Value $jsonPathResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_status' -Value ([string]$summary.status) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_surface' -Value ([string]$summary.executionSurface) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_context' -Value ([string]$summary.contexts.final) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'windows_host_preflight_ostype' -Value ([string]$summary.contexts.finalOsType) -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $lines = @(
    '### Windows Host Preflight',
    '',
    ('- execution_surface: `{0}`' -f [string]$summary.executionSurface),
    ('- status: `{0}`' -f [string]$summary.status),
    ('- image: `{0}`' -f [string]$summary.image),
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
