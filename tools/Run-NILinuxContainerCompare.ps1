#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a LabVIEW CLI compare inside a local NI Linux container image.

.DESCRIPTION
  Preflights Docker Linux mode/image availability, enforces runtime determinism,
  and executes CreateComparisonReport inside
  `nationalinstruments/labview:2026q1-linux` (or a caller-supplied image).
  The helper enforces headless execution and writes deterministic capture
  artifacts adjacent to the report output.

.PARAMETER BaseVi
  Path to the base VI. Required unless -Probe is set.

.PARAMETER HeadVi
  Path to the head VI. Required unless -Probe is set.

.PARAMETER Image
  Docker image tag to execute. Defaults to
  nationalinstruments/labview:2026q1-linux.

.PARAMETER ReportPath
  Optional report path on host. Defaults to
  tests/results/ni-linux-container/compare-report.<ext>.

.PARAMETER ReportType
  Host-facing report type selector: html, xml, or text.

.PARAMETER TimeoutSeconds
  Timeout for docker run execution. Defaults to 600.

.PARAMETER Flags
  Additional CLI flags appended to CreateComparisonReport.

.PARAMETER LabVIEWPath
  Optional explicit in-container LabVIEW executable path forwarded as
  -LabVIEWPath and used for prelaunch.

.PARAMETER ContainerNameLabel
  Optional deterministic label used when composing the Docker container name.
  The helper sanitizes the label and appends a short stable suffix so parallel
  runs do not collide on shared Docker hosts.

.PARAMETER Probe
  Preflight only (Docker availability, Linux container mode, and image
  presence). Does not require BaseVi/HeadVi.

.PARAMETER AutoRepairRuntime
  Allows deterministic runtime repair attempts when Docker mode/context
  mismatches are detected.

.PARAMETER RuntimeSnapshotPath
  Optional path for runtime determinism snapshot JSON.

.PARAMETER StartupRetryCount
  Retry count for transient CLI startup/connectivity failures (-350000).

.PARAMETER PrelaunchWaitSeconds
  Sleep after headless prelaunch before initial CLI invocation.

.PARAMETER RetryDelaySeconds
  Delay between retry attempts for transient startup failures.

.PARAMETER RuntimeInjectionScriptPath
  Optional bash fragment mounted into the container and sourced before CLI
  discovery so callers can inject dependencies, PATH updates, and config at
  runtime.

.PARAMETER RuntimeBootstrapContractPath
  Optional JSON contract describing a single-container smoke/bootstrap setup.
  The contract can declare the runtime injection script, extra env pairs, and
  extra mounts relative to the contract file.

.PARAMETER RuntimeInjectionEnv
  Optional additional container environment pairs in KEY=VALUE form. Values
  may reference host env vars via $env:NAME.

.PARAMETER RuntimeInjectionMount
  Optional additional runtime mounts in hostPath::/container/path form for
  dependency/config payloads that should be available inside the running
  container.

.PARAMETER PassThru
  Emit the capture object to stdout in addition to writing capture JSON.
#>
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = 'nationalinstruments/labview:2026q1-linux',
  [string]$ReportPath,
  [ValidateSet('html', 'xml', 'text')]
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [int]$HeartbeatSeconds = 15,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [string]$ContainerNameLabel,
  [switch]$Probe,
  [bool]$AutoRepairRuntime = $true,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [int]$StartupRetryCount = 1,
  [int]$PrelaunchWaitSeconds = 8,
  [int]$RetryDelaySeconds = 8,
  [string]$RuntimeInjectionScriptPath,
  [string]$RuntimeBootstrapContractPath,
  [string[]]$RuntimeInjectionEnv,
  [string[]]$RuntimeInjectionMount,
  [string]$ReuseContainerName,
  [string]$ReuseRepoHostPath,
  [string]$ReuseRepoContainerPath = '/opt/comparevi/source',
  [string]$ReuseResultsHostPath,
  [string]$ReuseResultsContainerPath = '/opt/comparevi/vi-history/results',
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$classifierScriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Compare-ExitCodeClassifier.ps1'
if (-not (Test-Path -LiteralPath $classifierScriptPath -PathType Leaf)) {
  throw ("Exit-code classifier script not found: {0}" -f $classifierScriptPath)
}
. $classifierScriptPath

$script:PreflightExitCode = 2
$script:TimeoutExitCode = 124

function Assert-Tool {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw ("Required tool not found on PATH: {0}" -f $Name)
  }
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
    @('docker', 'docker.sh')
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
  $command = Get-Command -Name 'docker' -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($command.Source)) {
    throw 'Unable to resolve docker command source path.'
  }
  return [string]$command.Source
}

function Get-EffectiveCompareFlags {
  param(
    [AllowNull()][string[]]$InputFlags
  )

  $flags = @()
  if ($InputFlags) {
    foreach ($flag in $InputFlags) {
      if (-not [string]::IsNullOrWhiteSpace([string]$flag)) {
        $flags += [string]$flag
      }
    }
  }

  $hasHeadless = $false
  foreach ($flag in $flags) {
    if ($flag.Trim().ToLowerInvariant() -eq '-headless') {
      $hasHeadless = $true
      break
    }
  }
  if (-not $hasHeadless) {
    $flags += '-Headless'
  }

  return @($flags)
}

function ConvertTo-ContainerNameSegment {
  param(
    [AllowEmptyString()][string]$Value,
    [int]$MaxLength = 40
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ''
  }

  $segment = $Value.Trim().ToLowerInvariant()
  $segment = [regex]::Replace($segment, '[^a-z0-9_.-]+', '-')
  $segment = [regex]::Replace($segment, '[-_.]{2,}', '-')
  $segment = $segment.Trim('-', '_', '.')
  if ([string]::IsNullOrWhiteSpace($segment)) {
    return ''
  }
  if ($segment.Length -gt $MaxLength) {
    $segment = $segment.Substring(0, $MaxLength).TrimEnd('-', '_', '.')
  }
  return $segment
}

function Get-DeterministicContainerSuffix {
  param([Parameter(Mandatory)][string]$Seed)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
  $hasher = [System.Security.Cryptography.MD5]::Create()
  try {
    $hash = $hasher.ComputeHash($bytes)
  } finally {
    $hasher.Dispose()
  }
  return ((($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8))
}

function New-CompareContainerName {
  param(
    [AllowEmptyString()][string]$Label,
    [AllowEmptyString()][string]$HashSeed
  )

  $prefix = 'ni-lnx-compare'
  $segment = ConvertTo-ContainerNameSegment -Value $Label
  if ([string]::IsNullOrWhiteSpace($segment)) {
    return ('{0}-{1}' -f $prefix, ([guid]::NewGuid().ToString('N').Substring(0, 12)))
  }

  $seed = if ([string]::IsNullOrWhiteSpace($HashSeed)) { $segment } else { $HashSeed }
  $suffix = Get-DeterministicContainerSuffix -Seed $seed
  return ('{0}-{1}-{2}' -f $prefix, $segment, $suffix)
}

function Resolve-EnvTokenValue {
  param([Parameter(Mandatory)][string]$Name)
  foreach ($scope in @('Process', 'User', 'Machine')) {
    $value = [Environment]::GetEnvironmentVariable($Name, $scope)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value
    }
  }
  return $null
}

function Resolve-EffectivePathInput {
  param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName
  )

  $trimmed = $InputPath.Trim()
  if ($trimmed -match '^\$env:([A-Za-z_][A-Za-z0-9_]*)$') {
    $envName = $Matches[1]
    $resolved = Resolve-EnvTokenValue -Name $envName
    if ([string]::IsNullOrWhiteSpace($resolved)) {
      throw ("Parameter -{0} references env var '{1}', but it is not set in Process/User/Machine scope." -f $ParameterName, $envName)
    }
    return $resolved
  }

  return $InputPath
}

function Resolve-ExistingFilePath {
  param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName
  )
  $effectiveInput = $InputPath
  if (-not [string]::IsNullOrWhiteSpace($effectiveInput)) {
    $effectiveInput = Resolve-EffectivePathInput -InputPath $effectiveInput -ParameterName $ParameterName
  }
  if ([string]::IsNullOrWhiteSpace($effectiveInput)) {
    throw ("Parameter -{0} is required." -f $ParameterName)
  }
  try {
    $resolved = Resolve-Path -LiteralPath $effectiveInput -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
      throw ("Path is not a file: {0}" -f $effectiveInput)
    }
    return $resolved.Path
  } catch {
    throw ("Unable to resolve -{0} file path '{1}'." -f $ParameterName, $effectiveInput)
  }
}

function Resolve-ExistingFileSystemPath {
  param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName
  )
  $effectiveInput = Resolve-EffectivePathInput -InputPath $InputPath -ParameterName $ParameterName
  if ([string]::IsNullOrWhiteSpace($effectiveInput)) {
    throw ("Parameter -{0} is required." -f $ParameterName)
  }
  try {
    $resolved = Resolve-Path -LiteralPath $effectiveInput -ErrorAction Stop
    if (
      (Test-Path -LiteralPath $resolved.Path -PathType Leaf) -or
      (Test-Path -LiteralPath $resolved.Path -PathType Container)
    ) {
      return $resolved.Path
    }
    throw ("Path is not a file or directory: {0}" -f $effectiveInput)
  } catch {
    throw ("Unable to resolve -{0} path '{1}'." -f $ParameterName, $effectiveInput)
  }
}

function Resolve-ReportTypeInfo {
  param([Parameter(Mandatory)][string]$Type)
  switch ($Type.ToLowerInvariant()) {
    'html' {
      return [pscustomobject]@{
        InputType     = 'html'
        CliReportType = 'html'
        Extension     = 'html'
      }
    }
    'xml' {
      return [pscustomobject]@{
        InputType     = 'xml'
        CliReportType = 'xml'
        Extension     = 'xml'
      }
    }
    'text' {
      return [pscustomobject]@{
        InputType     = 'text'
        CliReportType = 'text'
        Extension     = 'txt'
      }
    }
    default {
      throw ("Unsupported ReportType '{0}'." -f $Type)
    }
  }
}

function Resolve-OutputReportPath {
  param(
    [string]$PathValue,
    [Parameter(Mandatory)][string]$Extension
  )
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    $defaultRoot = Join-Path (Resolve-Path '.').Path 'tests/results/ni-linux-container'
    return (Join-Path $defaultRoot ("compare-report.{0}" -f $Extension))
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path '.').Path $PathValue))
}

function Test-DockerImageExists {
  param([Parameter(Mandatory)][string]$Tag)
  & docker image inspect $Tag *> $null
  return ($LASTEXITCODE -eq 0)
}

function Get-OrAddMountPath {
  param(
    [Parameter(Mandatory)][hashtable]$Map,
    [Parameter(Mandatory)][ref]$Index,
    [Parameter(Mandatory)][string]$HostDirectory
  )
  if (-not $Map.ContainsKey($HostDirectory)) {
    $Map[$HostDirectory] = ('/compare/m{0}' -f $Index.Value)
    $Index.Value++
  }
  return $Map[$HostDirectory]
}

function Convert-HostFileToContainerPath {
  param(
    [Parameter(Mandatory)][string]$HostFilePath,
    [Parameter(Mandatory)][hashtable]$MountMap,
    [Parameter(Mandatory)][ref]$MountIndex
  )
  $hostDir = Split-Path -Parent $HostFilePath
  $containerDir = Get-OrAddMountPath -Map $MountMap -Index $MountIndex -HostDirectory $hostDir
  return (Join-Path $containerDir (Split-Path -Leaf $HostFilePath)).Replace('\', '/')
}

function Test-HostPathWithinRoot {
  param(
    [Parameter(Mandatory)][string]$RootPath,
    [Parameter(Mandatory)][string]$HostPath
  )

  $resolvedRoot = [System.IO.Path]::GetFullPath($RootPath)
  $resolvedPath = [System.IO.Path]::GetFullPath($HostPath)
  $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $resolvedPath)
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    return $true
  }
  if ([string]::Equals($relativePath, '.', [System.StringComparison]::Ordinal)) {
    return $true
  }
  if ([System.IO.Path]::IsPathRooted($relativePath)) {
    return $false
  }
  return -not (
    [string]::Equals($relativePath, '..', [System.StringComparison]::Ordinal) -or
    $relativePath.StartsWith(('..{0}' -f [System.IO.Path]::DirectorySeparatorChar), [System.StringComparison]::Ordinal) -or
    $relativePath.StartsWith('../', [System.StringComparison]::Ordinal)
  )
}

function Convert-HostPathToExistingContainerPath {
  param(
    [Parameter(Mandatory)][string]$HostPath,
    [Parameter(Mandatory)][object[]]$Mappings,
    [Parameter(Mandatory)][string]$Description
  )

  $resolvedPath = [System.IO.Path]::GetFullPath($HostPath)
  $sortedMappings = @($Mappings | Sort-Object @{ Expression = { ([string]$_.hostPath).Length }; Descending = $true })
  foreach ($mapping in $sortedMappings) {
    $resolvedRoot = [System.IO.Path]::GetFullPath([string]$mapping.hostPath)
    if (-not (Test-HostPathWithinRoot -RootPath $resolvedRoot -HostPath $resolvedPath)) {
      continue
    }

    $relativePath = [System.IO.Path]::GetRelativePath($resolvedRoot, $resolvedPath)
    $containerRoot = [string]$mapping.containerPath
    if ([string]::Equals($relativePath, '.', [System.StringComparison]::Ordinal)) {
      return $containerRoot.Replace('\', '/')
    }

    return (Join-Path $containerRoot $relativePath).Replace('\', '/')
  }

  throw ("{0} '{1}' is not available inside the reused container mounts." -f $Description, $resolvedPath)
}

function Get-DockerContainerRecord {
  param([Parameter(Mandatory)][string]$ContainerName)

  $inspectOutput = & docker inspect $ContainerName 2>$null
  if ($LASTEXITCODE -ne 0) {
    return $null
  }

  try {
    $records = $inspectOutput | ConvertFrom-Json -Depth 12 -ErrorAction Stop
  } catch {
    return $null
  }

  $record = @($records | Select-Object -First 1)
  if ($record.Count -eq 0) {
    return $null
  }

  $state = if ($record[0].PSObject.Properties['State']) { $record[0].State } else { $null }
  $config = if ($record[0].PSObject.Properties['Config']) { $record[0].Config } else { $null }
  return [pscustomobject]@{
    name = $ContainerName
    image = if ($config -and $config.PSObject.Properties['Image']) { [string]$config.Image } else { '' }
    running = if ($state -and $state.PSObject.Properties['Running']) { [bool]$state.Running } else { $false }
    status = if ($state -and $state.PSObject.Properties['Status']) { [string]$state.Status } else { '' }
  }
}

function Resolve-RuntimeInjectionEnvEntries {
  param(
    [string[]]$Entries,
    [string[]]$ReservedNames = @()
  )

  $resolved = @()
  foreach ($entry in @($Entries)) {
    if ([string]::IsNullOrWhiteSpace([string]$entry)) {
      continue
    }

    $candidate = [string]$entry
    if ($candidate -notmatch '^(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
      throw ("Invalid -RuntimeInjectionEnv entry '{0}'. Use KEY=VALUE." -f $candidate)
    }

    $name = [string]$Matches['name']
    if ($ReservedNames -contains $name) {
      throw ("-RuntimeInjectionEnv cannot override reserved variable '{0}'." -f $name)
    }

    $value = Resolve-EffectivePathInput -InputPath ([string]$Matches['value']) -ParameterName 'RuntimeInjectionEnv'
    $resolved += [pscustomobject]@{
      name = $name
      value = [string]$value
    }
  }

  return @($resolved)
}

function Resolve-RuntimeInjectionMountEntries {
  param([string[]]$Entries)

  $resolved = @()
  foreach ($entry in @($Entries)) {
    if ([string]::IsNullOrWhiteSpace([string]$entry)) {
      continue
    }

    $candidate = [string]$entry
    $separatorIndex = $candidate.IndexOf('::', [System.StringComparison]::Ordinal)
    if ($separatorIndex -lt 1) {
      throw ("Invalid -RuntimeInjectionMount entry '{0}'. Use hostPath::/container/path." -f $candidate)
    }

    $hostPart = $candidate.Substring(0, $separatorIndex).Trim()
    $containerPart = $candidate.Substring($separatorIndex + 2).Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($hostPart) -or [string]::IsNullOrWhiteSpace($containerPart)) {
      throw ("Invalid -RuntimeInjectionMount entry '{0}'. Use hostPath::/container/path." -f $candidate)
    }
    if (-not $containerPart.StartsWith('/')) {
      throw ("-RuntimeInjectionMount container path must be absolute: {0}" -f $candidate)
    }
    if (
      [string]::Equals($containerPart, '/compare', [System.StringComparison]::Ordinal) -or
      $containerPart -match '^/compare/m\d+(/|$)'
    ) {
      throw ("-RuntimeInjectionMount container path '{0}' collides with reserved compare mounts." -f $containerPart)
    }

    $resolvedHostPath = Resolve-ExistingFileSystemPath -InputPath $hostPart -ParameterName 'RuntimeInjectionMount'
    $kind = if (Test-Path -LiteralPath $resolvedHostPath -PathType Container) { 'directory' } else { 'file' }
    $resolved += [pscustomobject]@{
      hostPath = [string]$resolvedHostPath
      containerPath = [string]$containerPart
      kind = $kind
    }
  }

  return @($resolved)
}

function Resolve-ExistingPathFromBaseDirectory {
  param(
    [Parameter(Mandatory)][string]$BaseDirectory,
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName,
    [switch]$RequireFile
  )

  $effectiveInput = Resolve-EffectivePathInput -InputPath $InputPath -ParameterName $ParameterName
  if ([string]::IsNullOrWhiteSpace($effectiveInput)) {
    throw ("Parameter -{0} is required." -f $ParameterName)
  }

  $candidate = if ([System.IO.Path]::IsPathRooted($effectiveInput)) {
    [System.IO.Path]::GetFullPath($effectiveInput)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $effectiveInput))
  }

  if ($RequireFile) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      throw ("Unable to resolve -{0} file path '{1}'." -f $ParameterName, $effectiveInput)
    }
    return $candidate
  }

  if (
    -not (Test-Path -LiteralPath $candidate -PathType Leaf) -and
    -not (Test-Path -LiteralPath $candidate -PathType Container)
  ) {
    throw ("Unable to resolve -{0} path '{1}'." -f $ParameterName, $effectiveInput)
  }

  return $candidate
}

function Resolve-OutputPathFromBaseDirectory {
  param(
    [Parameter(Mandatory)][string]$BaseDirectory,
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ParameterName
  )

  $effectiveInput = Resolve-EffectivePathInput -InputPath $InputPath -ParameterName $ParameterName
  if ([string]::IsNullOrWhiteSpace($effectiveInput)) {
    throw ("Parameter -{0} is required." -f $ParameterName)
  }

  if ([System.IO.Path]::IsPathRooted($effectiveInput)) {
    return [System.IO.Path]::GetFullPath($effectiveInput)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $effectiveInput))
}

function Invoke-WithoutGitWorkspaceOverride {
  param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

  $gitEnvNames = @(
    'GIT_DIR',
    'GIT_WORK_TREE',
    'GIT_COMMON_DIR',
    'GIT_INDEX_FILE',
    'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES',
    'GIT_PREFIX',
    'GIT_CEILING_DIRECTORIES'
  )
  $savedEnv = @{}
  foreach ($name in $gitEnvNames) {
    $savedEnv[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
    Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
    [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
  }

  try {
    $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    function local:git {
      param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = $gitPath
      $psi.WorkingDirectory = (Get-Location).Path
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      foreach ($arg in @($Arguments)) {
        [void]$psi.ArgumentList.Add([string]$arg)
      }
      foreach ($envName in $gitEnvNames) {
        [void]$psi.Environment.Remove($envName)
      }

      $proc = [System.Diagnostics.Process]::new()
      $proc.StartInfo = $psi
      try {
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $global:LASTEXITCODE = [int]$proc.ExitCode
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
          [Console]::Error.Write($stderr)
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) {
          return @()
        }
        return @($stdout -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      } finally {
        $proc.Dispose()
      }
    }
    & $ScriptBlock
  } finally {
    Remove-Item -Path Function:git -ErrorAction SilentlyContinue
    foreach ($name in $savedEnv.Keys) {
      if ($null -eq $savedEnv[$name]) {
        Remove-Item -Path ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
        [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
      } else {
        Set-Item -Path ("Env:{0}" -f $name) -Value $savedEnv[$name]
        [System.Environment]::SetEnvironmentVariable($name, $savedEnv[$name], 'Process')
      }
    }
  }
}

function Get-HostGitBranchBudget {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$BranchRef,
    [AllowEmptyString()][string]$BaselineRef,
    [Parameter(Mandatory)][int]$MaxCommitCount
  )

  $normalizedBranchRef = $BranchRef.Trim()
  $result = [ordered]@{
    sourceBranchRef = $normalizedBranchRef
    requestedBaselineRef = if ([string]::IsNullOrWhiteSpace($BaselineRef)) { $null } else { [string]$BaselineRef.Trim() }
    baselineRef = $null
    mergeBaseRef = $null
    commitRange = $null
    maxCommitCount = [int]$MaxCommitCount
    commitCount = $null
    status = 'pending'
    reason = 'not-evaluated'
  }

  if ([string]::IsNullOrWhiteSpace($normalizedBranchRef)) {
    $result.status = 'invalid'
    $result.reason = 'branch-ref-empty'
    return [pscustomobject]$result
  }

  return Invoke-WithoutGitWorkspaceOverride {
    Push-Location $RepoPath
    try {
    & git rev-parse --verify $normalizedBranchRef *> $null
    if ($LASTEXITCODE -ne 0) {
      $result.status = 'invalid'
      $result.reason = 'branch-ref-not-found'
      return [pscustomobject]$result
    }

    $effectiveBaselineRef = $null
    if (-not [string]::IsNullOrWhiteSpace($BaselineRef)) {
      $requestedBaselineRef = $BaselineRef.Trim()
      & git rev-parse --verify $requestedBaselineRef *> $null
      if ($LASTEXITCODE -ne 0) {
        $result.status = 'invalid'
        $result.reason = 'baseline-ref-not-found'
        return [pscustomobject]$result
      }
      $effectiveBaselineRef = $requestedBaselineRef
    } else {
      & git rev-parse --verify develop *> $null
      if ($LASTEXITCODE -eq 0) {
        $effectiveBaselineRef = 'develop'
      }
    }
    $result.baselineRef = $effectiveBaselineRef

    $range = if ($effectiveBaselineRef) {
      if ([string]::Equals($normalizedBranchRef, $effectiveBaselineRef, [System.StringComparison]::OrdinalIgnoreCase)) {
        ('{0}..{0}' -f $effectiveBaselineRef)
      } else {
        $mergeBaseOutput = & git merge-base $effectiveBaselineRef $normalizedBranchRef
        if ($LASTEXITCODE -ne 0) {
          $result.status = 'error'
          $result.reason = 'merge-base-query-failed'
          return [pscustomobject]$result
        }

        $mergeBaseRef = [string]($mergeBaseOutput | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($mergeBaseRef)) {
          $result.status = 'error'
          $result.reason = 'merge-base-empty'
          return [pscustomobject]$result
        }

        $result.mergeBaseRef = $mergeBaseRef
        ('{0}..{1}' -f $mergeBaseRef, $normalizedBranchRef)
      }
    } else {
      $normalizedBranchRef
    }
    $result.commitRange = $range

    $countOutput = & git rev-list --count --first-parent $range
    if ($LASTEXITCODE -ne 0) {
      $result.status = 'error'
      $result.reason = 'commit-count-query-failed'
      return [pscustomobject]$result
    }

    $countText = [string]($countOutput | Select-Object -Last 1)
    $countValue = 0
    if (-not [int]::TryParse($countText, [ref]$countValue)) {
      $result.status = 'error'
      $result.reason = 'commit-count-parse-failed'
      return [pscustomobject]$result
    }

    $result.commitCount = [int]$countValue
    if ($countValue -gt $MaxCommitCount) {
      $result.status = 'blocked'
      $result.reason = 'commit-limit-exceeded'
      throw ("VI history source branch '{0}' exceeds the commit safeguard ({1} > {2}). Narrow the branch or raise -RuntimeBootstrapContractPath maxCommitCount." -f $normalizedBranchRef, $countValue, $MaxCommitCount)
    }

    $result.status = 'ok'
    $result.reason = 'within-limit'
      return [pscustomobject]$result
    } finally {
      Pop-Location | Out-Null
    }
  }
}

function Resolve-GitWorkTreeInjection {
  param(
    [Parameter(Mandatory)][string]$RepoHostPath,
    [Parameter(Mandatory)][string]$RepoContainerPath
  )

  $empty = [pscustomobject]@{
    enabled = $false
    strategy = 'none'
    dotGitHostPath = ''
    commonGitHostPath = ''
    commonGitContainerPath = ''
    gitDirContainerPath = ''
    gitWorkTreeContainerPath = ''
    env = @()
    mounts = @()
  }

  $dotGitPath = Join-Path $RepoHostPath '.git'
  if (-not (Test-Path -LiteralPath $dotGitPath)) {
    return $empty
  }

  $resolvedDotGitHostPath = (Resolve-Path -LiteralPath $dotGitPath).Path
  if (Test-Path -LiteralPath $dotGitPath -PathType Container) {
    $gitDirContainerPath = '{0}/.git' -f $RepoContainerPath.TrimEnd('/')
    return [pscustomobject]@{
      enabled = $true
      strategy = 'git-directory'
      dotGitHostPath = $resolvedDotGitHostPath
      commonGitHostPath = $resolvedDotGitHostPath
      commonGitContainerPath = $gitDirContainerPath
      gitDirContainerPath = $gitDirContainerPath
      gitWorkTreeContainerPath = $RepoContainerPath
      env = @(
        [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_GIT_DIR'; value = $gitDirContainerPath },
        [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_GIT_WORK_TREE'; value = $RepoContainerPath }
      )
      mounts = @()
    }
  }
  if (-not (Test-Path -LiteralPath $dotGitPath -PathType Leaf)) {
    return $empty
  }

  $dotGitContent = Get-Content -LiteralPath $dotGitPath -Raw
  if (-not ($dotGitContent -match 'gitdir:\s*(?<path>.+)')) {
    return $empty
  }

  $gitDirHostPath = $Matches['path'].Trim()
  if (-not [System.IO.Path]::IsPathRooted($gitDirHostPath)) {
    $gitDirHostPath = [System.IO.Path]::GetFullPath((Join-Path $RepoHostPath $gitDirHostPath))
  }
  if (-not (Test-Path -LiteralPath $gitDirHostPath -PathType Container)) {
    throw ("Runtime bootstrap viHistory worktree gitdir path not found: {0}" -f $gitDirHostPath)
  }

  $worktreeName = Split-Path -Leaf $gitDirHostPath
  $worktreesRoot = Split-Path -Parent $gitDirHostPath
  if ([string]::IsNullOrWhiteSpace($worktreeName) -or -not $worktreesRoot) {
    throw ("Runtime bootstrap viHistory worktree gitdir path is invalid: {0}" -f $gitDirHostPath)
  }

  $commonGitHostPath = Split-Path -Parent $worktreesRoot
  if (-not (Test-Path -LiteralPath $commonGitHostPath -PathType Container)) {
    throw ("Runtime bootstrap viHistory common git dir not found: {0}" -f $commonGitHostPath)
  }

  $commonGitContainerPath = '/opt/comparevi/git/common'
  $gitDirContainerPath = '{0}/worktrees/{1}' -f $commonGitContainerPath, $worktreeName

  return [pscustomobject]@{
    enabled = $true
    strategy = 'git-worktree-file'
    dotGitHostPath = $resolvedDotGitHostPath
    commonGitHostPath = $commonGitHostPath
    commonGitContainerPath = $commonGitContainerPath
    gitDirContainerPath = $gitDirContainerPath
    gitWorkTreeContainerPath = $RepoContainerPath
    env = @(
      [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_GIT_DIR'; value = $gitDirContainerPath },
      [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_GIT_WORK_TREE'; value = $RepoContainerPath }
    )
    mounts = @(
      [pscustomobject]@{
        hostPath = $commonGitHostPath
        containerPath = $commonGitContainerPath
        kind = 'directory'
      }
    )
  }
}

function Resolve-RuntimeBootstrapViHistory {
  param(
    [AllowNull()]$ViHistory,
    [Parameter(Mandatory)][string]$ContractDirectory,
    [AllowEmptyString()][string]$Mode,
    [AllowEmptyString()][string]$BranchRef,
    [AllowNull()][int]$MaxCommitCount
  )

  $empty = [pscustomobject]@{
    enabled = $false
    repoHostPath = ''
    repoContainerPath = ''
    targetPath = ''
    baselineRef = ''
    bootstrapMode = ''
    resultsHostPath = ''
    resultsContainerPath = ''
    suiteManifestContainerPath = ''
    historyContextContainerPath = ''
    bootstrapReceiptContainerPath = ''
    bootstrapMarkerContainerPath = ''
    maxPairs = $null
    branchBudget = $null
    gitInjection = [pscustomobject]@{
      enabled = $false
      strategy = 'none'
      dotGitHostPath = ''
      commonGitHostPath = ''
      commonGitContainerPath = ''
      gitDirContainerPath = ''
      gitWorkTreeContainerPath = ''
    }
    env = @()
    mounts = @()
  }
  if (-not $ViHistory) {
    return $empty
  }

  $repoPathInput = if ($ViHistory.PSObject.Properties['repoPath']) { [string]$ViHistory.repoPath } else { '' }
  if ([string]::IsNullOrWhiteSpace($repoPathInput)) {
    throw 'Runtime bootstrap viHistory.repoPath is required.'
  }
  $targetPath = if ($ViHistory.PSObject.Properties['targetPath']) { [string]$ViHistory.targetPath } else { '' }
  if ([string]::IsNullOrWhiteSpace($targetPath)) {
    throw 'Runtime bootstrap viHistory.targetPath is required.'
  }
  $resultsPathInput = if ($ViHistory.PSObject.Properties['resultsPath']) { [string]$ViHistory.resultsPath } else { '' }
  if ([string]::IsNullOrWhiteSpace($resultsPathInput)) {
    throw 'Runtime bootstrap viHistory.resultsPath is required.'
  }

  $repoHostPath = Resolve-ExistingPathFromBaseDirectory `
    -BaseDirectory $ContractDirectory `
    -InputPath $repoPathInput `
    -ParameterName 'RuntimeBootstrapContractPath'
  if (-not (Test-Path -LiteralPath $repoHostPath -PathType Container)) {
    throw ("Runtime bootstrap viHistory.repoPath must be a directory: {0}" -f $repoHostPath)
  }
  $isGitWorkingTree = Invoke-WithoutGitWorkspaceOverride {
    & git -C $repoHostPath rev-parse --is-inside-work-tree *> $null
    return ($LASTEXITCODE -eq 0)
  }
  if (-not $isGitWorkingTree) {
    throw ("Runtime bootstrap viHistory.repoPath is not a git working tree: {0}" -f $repoHostPath)
  }

  $resultsHostPath = Resolve-OutputPathFromBaseDirectory `
    -BaseDirectory $ContractDirectory `
    -InputPath $resultsPathInput `
    -ParameterName 'RuntimeBootstrapContractPath'
  if (-not (Test-Path -LiteralPath $resultsHostPath -PathType Container)) {
    New-Item -ItemType Directory -Path $resultsHostPath -Force | Out-Null
  }

  $baselineRef = if ($ViHistory.PSObject.Properties['baselineRef'] -and -not [string]::IsNullOrWhiteSpace([string]$ViHistory.baselineRef)) {
    [string]$ViHistory.baselineRef
  } else {
    'develop'
  }
  $maxPairs = if ($ViHistory.PSObject.Properties['maxPairs'] -and $null -ne $ViHistory.maxPairs) {
    [int]$ViHistory.maxPairs
  } else {
    1
  }
  if ($maxPairs -le 0) {
    throw 'Runtime bootstrap viHistory.maxPairs must be greater than zero.'
  }

  $repoContainerPath = '/opt/comparevi/source'
  $resultsContainerPath = '/opt/comparevi/vi-history/results'
  $suiteManifestContainerPath = '{0}/suite-manifest.json' -f $resultsContainerPath
  $historyContextContainerPath = '{0}/history-context.json' -f $resultsContainerPath
  $bootstrapReceiptContainerPath = '{0}/vi-history-bootstrap-receipt.json' -f $resultsContainerPath
  $bootstrapMarkerContainerPath = '{0}/vi-history-bootstrap-ran.txt' -f $resultsContainerPath
  $gitInjection = Resolve-GitWorkTreeInjection -RepoHostPath $repoHostPath -RepoContainerPath $repoContainerPath

  $branchBudget = $null
  if (-not [string]::IsNullOrWhiteSpace($BranchRef) -and $null -ne $MaxCommitCount) {
    $branchBudget = Get-HostGitBranchBudget -RepoPath $repoHostPath -BranchRef $BranchRef -BaselineRef $baselineRef -MaxCommitCount $MaxCommitCount
  }

  $bootstrapMode = if (-not [string]::IsNullOrWhiteSpace($Mode)) {
    [string]$Mode
  } elseif (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE)) {
    [string]$env:COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE
  } else {
    'vi-history-suite-smoke'
  }

  $env = @(
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE'; value = $bootstrapMode },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_REPO_PATH'; value = $repoContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_TARGET_PATH'; value = $targetPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_BASELINE_REF'; value = $baselineRef },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_RESULTS_DIR'; value = $resultsContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_SUITE_MANIFEST'; value = $suiteManifestContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_CONTEXT'; value = $historyContextContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT'; value = $bootstrapReceiptContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER'; value = $bootstrapMarkerContainerPath },
    [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_MAX_PAIRS'; value = [string]$maxPairs }
  )
  if (-not [string]::IsNullOrWhiteSpace($BranchRef)) {
    $env += [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_SOURCE_BRANCH'; value = $BranchRef }
  }
  if ($null -ne $MaxCommitCount) {
    $env += [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS'; value = [string]$MaxCommitCount }
  }
  if ($branchBudget -and $null -ne $branchBudget.commitCount) {
    $env += [pscustomobject]@{ name = 'COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT'; value = [string]$branchBudget.commitCount }
  }
  if ($gitInjection.enabled) {
    $env += @($gitInjection.env)
  }

  $mounts = @(
    [pscustomobject]@{
      hostPath = [string]$repoHostPath
      containerPath = $repoContainerPath
      kind = 'directory'
    },
    [pscustomobject]@{
      hostPath = [string]$resultsHostPath
      containerPath = $resultsContainerPath
      kind = 'directory'
    }
  )
  if ($gitInjection.enabled) {
    $mounts += @($gitInjection.mounts)
  }

  return [pscustomobject]@{
    enabled = $true
    repoHostPath = [string]$repoHostPath
    repoContainerPath = $repoContainerPath
    targetPath = $targetPath
    baselineRef = $baselineRef
    bootstrapMode = [string]$bootstrapMode
    resultsHostPath = [string]$resultsHostPath
    resultsContainerPath = $resultsContainerPath
    suiteManifestContainerPath = $suiteManifestContainerPath
    historyContextContainerPath = $historyContextContainerPath
    bootstrapReceiptContainerPath = $bootstrapReceiptContainerPath
    bootstrapMarkerContainerPath = $bootstrapMarkerContainerPath
    maxPairs = [int]$maxPairs
    branchBudget = $branchBudget
    gitInjection = [pscustomobject]@{
      enabled = [bool]$gitInjection.enabled
      strategy = [string]$gitInjection.strategy
      dotGitHostPath = [string]$gitInjection.dotGitHostPath
      commonGitHostPath = [string]$gitInjection.commonGitHostPath
      commonGitContainerPath = [string]$gitInjection.commonGitContainerPath
      gitDirContainerPath = [string]$gitInjection.gitDirContainerPath
      gitWorkTreeContainerPath = [string]$gitInjection.gitWorkTreeContainerPath
    }
    env = @($env)
    mounts = @($mounts)
  }
}

function Resolve-RuntimeBootstrapContract {
  param(
    [string]$ContractPath,
    [string[]]$ReservedNames = @()
  )

  if ([string]::IsNullOrWhiteSpace($ContractPath)) {
    return [pscustomobject]@{
      contractPath = ''
      mode = ''
      branchRef = ''
      maxCommitCount = $null
      scriptPath = ''
      viHistory = [pscustomobject]@{
        enabled = $false
        repoHostPath = ''
        repoContainerPath = ''
        targetPath = ''
        baselineRef = ''
        resultsHostPath = ''
        resultsContainerPath = ''
        suiteManifestContainerPath = ''
        historyContextContainerPath = ''
        bootstrapReceiptContainerPath = ''
        bootstrapMarkerContainerPath = ''
        maxPairs = $null
        branchBudget = $null
        gitInjection = [pscustomobject]@{
          enabled = $false
          strategy = 'none'
          dotGitHostPath = ''
          commonGitHostPath = ''
          commonGitContainerPath = ''
          gitDirContainerPath = ''
          gitWorkTreeContainerPath = ''
        }
      }
      env = @()
      mounts = @()
    }
  }

  $resolvedContractPath = Resolve-ExistingFilePath -InputPath $ContractPath -ParameterName 'RuntimeBootstrapContractPath'
  try {
    $contract = Get-Content -LiteralPath $resolvedContractPath -Raw | ConvertFrom-Json -Depth 12 -ErrorAction Stop
  } catch {
    throw ("Unable to parse -RuntimeBootstrapContractPath JSON '{0}'." -f $resolvedContractPath)
  }

  $schema = if ($contract -and $contract.PSObject.Properties['schema']) { [string]$contract.schema } else { '' }
  if (-not [string]::Equals($schema, 'ni-linux-runtime-bootstrap/v1', [System.StringComparison]::Ordinal)) {
    throw ("Unsupported runtime bootstrap schema '{0}' in {1}." -f $schema, $resolvedContractPath)
  }

  $contractDirectory = Split-Path -Parent $resolvedContractPath
  $resolvedScriptPath = ''
  if ($contract.PSObject.Properties['scriptPath'] -and -not [string]::IsNullOrWhiteSpace([string]$contract.scriptPath)) {
    $resolvedScriptPath = Resolve-ExistingPathFromBaseDirectory `
      -BaseDirectory $contractDirectory `
      -InputPath ([string]$contract.scriptPath) `
      -ParameterName 'RuntimeBootstrapContractPath' `
      -RequireFile
  }

  $resolvedEnv = @()
  foreach ($entry in @($(if ($contract.PSObject.Properties['env']) { $contract.env } else { @() }))) {
    if (-not $entry) { continue }
    $name = if ($entry.PSObject.Properties['name']) { [string]$entry.name } else { '' }
    if ([string]::IsNullOrWhiteSpace($name)) {
      throw ("Runtime bootstrap env entry in {0} is missing 'name'." -f $resolvedContractPath)
    }
    if ($ReservedNames -contains $name) {
      throw ("Runtime bootstrap contract cannot override reserved variable '{0}'." -f $name)
    }

    $hasLiteralValue = $entry.PSObject.Properties['value'] -and $null -ne $entry.value
    $hasHostEnv = $entry.PSObject.Properties['fromHostEnv'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.fromHostEnv)
    if ($hasLiteralValue -eq $hasHostEnv) {
      throw ("Runtime bootstrap env entry '{0}' in {1} must set exactly one of 'value' or 'fromHostEnv'." -f $name, $resolvedContractPath)
    }

    $value = if ($hasHostEnv) {
      $hostEnvName = [string]$entry.fromHostEnv
      $resolvedValue = Resolve-EnvTokenValue -Name $hostEnvName
      if ([string]::IsNullOrWhiteSpace($resolvedValue)) {
        throw ("Runtime bootstrap env entry '{0}' references host env '{1}', but it is not set." -f $name, $hostEnvName)
      }
      [string]$resolvedValue
    } else {
      [string]$entry.value
    }

    $resolvedEnv += [pscustomobject]@{
      name = $name
      value = $value
    }
  }

  $resolvedMounts = @()
  foreach ($entry in @($(if ($contract.PSObject.Properties['mounts']) { $contract.mounts } else { @() }))) {
    if (-not $entry) { continue }
    $hostPathValue = if ($entry.PSObject.Properties['hostPath']) { [string]$entry.hostPath } else { '' }
    $containerPath = if ($entry.PSObject.Properties['containerPath']) { [string]$entry.containerPath } else { '' }
    if ([string]::IsNullOrWhiteSpace($hostPathValue) -or [string]::IsNullOrWhiteSpace($containerPath)) {
      throw ("Runtime bootstrap mount entry in {0} requires 'hostPath' and 'containerPath'." -f $resolvedContractPath)
    }

    $resolvedHostPath = Resolve-ExistingPathFromBaseDirectory `
      -BaseDirectory $contractDirectory `
      -InputPath $hostPathValue `
      -ParameterName 'RuntimeBootstrapContractPath'

    $normalizedContainerPath = $containerPath.Trim().Replace('\', '/')
    if (-not $normalizedContainerPath.StartsWith('/')) {
      throw ("Runtime bootstrap mount container path must be absolute in {0}: {1}" -f $resolvedContractPath, $containerPath)
    }
    if (
      [string]::Equals($normalizedContainerPath, '/compare', [System.StringComparison]::Ordinal) -or
      $normalizedContainerPath -match '^/compare/m\d+(/|$)'
    ) {
      throw ("Runtime bootstrap mount path '{0}' in {1} collides with reserved compare mounts." -f $normalizedContainerPath, $resolvedContractPath)
    }

    $kind = if (Test-Path -LiteralPath $resolvedHostPath -PathType Container) { 'directory' } else { 'file' }
    $resolvedMounts += [pscustomobject]@{
      hostPath = [string]$resolvedHostPath
      containerPath = [string]$normalizedContainerPath
      kind = $kind
    }
  }

  $mode = if ($contract.PSObject.Properties['mode'] -and -not [string]::IsNullOrWhiteSpace([string]$contract.mode)) {
    [string]$contract.mode
  } else {
    'single-container-smoke'
  }
  $branchRef = if ($contract.PSObject.Properties['branchRef'] -and -not [string]::IsNullOrWhiteSpace([string]$contract.branchRef)) {
    [string]$contract.branchRef
  } else {
    ''
  }
  $maxCommitCount = if ($contract.PSObject.Properties['maxCommitCount'] -and $null -ne $contract.maxCommitCount) {
    [int]$contract.maxCommitCount
  } else {
    $null
  }
  $resolvedViHistory = Resolve-RuntimeBootstrapViHistory `
    -ViHistory $(if ($contract.PSObject.Properties['viHistory']) { $contract.viHistory } else { $null }) `
    -ContractDirectory $contractDirectory `
    -Mode $mode `
    -BranchRef $branchRef `
    -MaxCommitCount $maxCommitCount
  $resolvedEnv = @($resolvedViHistory.env) + @($resolvedEnv)
  $resolvedMounts = @($resolvedViHistory.mounts) + @($resolvedMounts)

  return [pscustomobject]@{
    contractPath = $resolvedContractPath
    mode = $mode
    branchRef = $branchRef
    maxCommitCount = $maxCommitCount
    scriptPath = $resolvedScriptPath
    viHistory = $resolvedViHistory
    env = @($resolvedEnv)
    mounts = @($resolvedMounts)
  }
}

function New-ContainerCommand {
  return @'
set -u
set -o pipefail

find_cli() {
  if command -v LabVIEWCLI >/dev/null 2>&1; then
    echo "LabVIEWCLI"
    return 0
  fi
  if command -v labviewcli >/dev/null 2>&1; then
    echo "labviewcli"
    return 0
  fi
  local found
  found="$(find / -maxdepth 6 -type f \( -name LabVIEWCLI -o -name LabVIEWCLI.sh -o -name labviewcli \) 2>/dev/null | head -n 1 || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  return 1
}

find_labview() {
  if [ -n "${COMPARE_LABVIEW_PATH:-}" ] && [ -x "${COMPARE_LABVIEW_PATH}" ]; then
    echo "${COMPARE_LABVIEW_PATH}"
    return 0
  fi
  local candidates=(
    "/usr/local/natinst/LabVIEW-2026-64/labview"
    "/usr/local/natinst/LabVIEW/labview"
    "/usr/local/bin/labview"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -x "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

set_ini_timeout_token() {
  local file="$1"
  local key="$2"
  local value="$3"
  if [ ! -f "$file" ]; then
    return 0
  fi
  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
  else
    printf "%s=%s\n" "$key" "$value" >> "$file"
  fi
}

find_cli_ini() {
  local candidates=(
    "/etc/natinst/LabVIEWCLI/LabVIEWCLI.ini"
    "/usr/local/natinst/LabVIEWCLI/LabVIEWCLI.ini"
    "/usr/local/natinst/LabVIEW/LabVIEWCLI.ini"
  )
  local c
  for c in "${candidates[@]}"; do
    if [ -f "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  local found
  found="$(find / -maxdepth 6 -type f -name LabVIEWCLI.ini 2>/dev/null | head -n 1 || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  return 1
}

if [ -n "${COMPARE_RUNTIME_INJECTION_SCRIPT:-}" ]; then
  if [ ! -f "${COMPARE_RUNTIME_INJECTION_SCRIPT}" ]; then
    echo "Runtime injection script not found: ${COMPARE_RUNTIME_INJECTION_SCRIPT}" 1>&2
    exit 2
  fi
  # shellcheck source=/dev/null
  if ! . "${COMPARE_RUNTIME_INJECTION_SCRIPT}"; then
    echo "Runtime injection script failed: ${COMPARE_RUNTIME_INJECTION_SCRIPT}" 1>&2
    exit 2
  fi
fi

require_compare_input() {
  local label="$1"
  local path="$2"
  if [ -z "$path" ]; then
    echo "${label} is required after runtime bootstrap." 1>&2
    exit 2
  fi
  if [ ! -f "$path" ]; then
    echo "${label} not found: ${path}" 1>&2
    exit 2
  fi
}

if [ -z "${COMPARE_REPORT_PATH:-}" ]; then
  echo "COMPARE_REPORT_PATH is required after runtime bootstrap." 1>&2
  exit 2
fi

PAIR_PLAN_PATH="${COMPAREVI_VI_HISTORY_PAIR_PLAN:-}"
PAIR_RESULT_LEDGER="${COMPAREVI_VI_HISTORY_RESULT_LEDGER:-}"
if [ -n "${PAIR_PLAN_PATH}" ] && [ ! -f "${PAIR_PLAN_PATH}" ]; then
  echo "COMPAREVI_VI_HISTORY_PAIR_PLAN not found: ${PAIR_PLAN_PATH}" 1>&2
  exit 2
fi
if [ -n "${PAIR_PLAN_PATH}" ] && [ -z "${PAIR_RESULT_LEDGER}" ]; then
  echo "COMPAREVI_VI_HISTORY_RESULT_LEDGER is required when COMPAREVI_VI_HISTORY_PAIR_PLAN is set." 1>&2
  exit 2
fi
if [ -z "${PAIR_PLAN_PATH}" ] || [ ! -s "${PAIR_PLAN_PATH}" ]; then
  require_compare_input "COMPARE_BASE_VI" "${COMPARE_BASE_VI:-}"
  require_compare_input "COMPARE_HEAD_VI" "${COMPARE_HEAD_VI:-}"
fi

if ! CLI_PATH="$(find_cli)"; then
  echo "LabVIEWCLI not found in container. Ensure NI image includes LabVIEW CLI component." 1>&2
  exit 2
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found. Linux headless container compares require Xvfb." 1>&2
  exit 2
fi

declare -a CLI_ARGS_BASE

if [ -n "${COMPARE_LABVIEW_PATH:-}" ]; then
  CLI_ARGS_BASE+=("-LabVIEWPath" "${COMPARE_LABVIEW_PATH}")
else
  if LV_PATH="$(find_labview)"; then
    CLI_ARGS_BASE+=("-LabVIEWPath" "${LV_PATH}")
  fi
fi

CLI_ARGS_BASE+=("-OperationName" "CreateComparisonReport")
CLI_ARGS_BASE+=("-ReportType" "${COMPARE_REPORT_TYPE}")
CLI_ARGS_BASE+=("-Headless" "true")

if [ -n "${COMPARE_FLAGS_B64:-}" ]; then
  while IFS= read -r flag; do
    if [ -n "$flag" ]; then
      CLI_ARGS_BASE+=("$flag")
    fi
  done < <(printf "%s" "${COMPARE_FLAGS_B64}" | base64 -d 2>/dev/null || true)
fi

INI_PATH=""
if INI_PATH="$(find_cli_ini)"; then
  set_ini_timeout_token "$INI_PATH" "OpenAppReferenceTimeoutInSecond" "${COMPARE_OPEN_APP_TIMEOUT:-180}"
  set_ini_timeout_token "$INI_PATH" "AfterLaunchOpenAppReferenceTimeoutInSecond" "${COMPARE_AFTER_LAUNCH_TIMEOUT:-180}"
fi

PRELAUNCH_ATTEMPTED=0
if [ "${COMPARE_PRELAUNCH_ENABLED:-1}" = "1" ]; then
  if LV_PATH="$(find_labview)"; then
    PRELAUNCH_ATTEMPTED=1
    "${LV_PATH}" --headless >/tmp/labview-prelaunch.log 2>&1 &
    sleep "${COMPARE_PRELAUNCH_WAIT_SECONDS:-8}"
  fi
fi

MAX_RETRIES="${COMPARE_STARTUP_RETRY_COUNT:-1}"
RETRY_DELAY="${COMPARE_RETRY_DELAY_SECONDS:-8}"
RETRY_TRIGGERED=0
TOTAL_COMPARE_ATTEMPTS=0
TOTAL_PROCESSED_PAIRS=0
EXIT_CODE=0
SUITE_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
LAST_COMPARE_EXIT_CODE=0
LAST_COMPARE_STARTED_AT="${SUITE_STARTED_AT}"

run_compare_with_retry() {
  local base_vi_path="$1"
  local head_vi_path="$2"
  local report_path="$3"
  local attempt=0
  local output_text=""
  local output_file=""
  local exit_code=1
  local started_at
  local -a run_args

  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  run_args=("${CLI_ARGS_BASE[@]}")
  run_args+=("-VI1" "${base_vi_path}")
  run_args+=("-VI2" "${head_vi_path}")
  run_args+=("-ReportPath" "${report_path}")

  if [ "${COMPARE_TRACE_ARGS:-0}" = "1" ]; then
    printf '[ni-linux-cli] path=%s\n' "${CLI_PATH}"
    printf '[ni-linux-cli] args='
    printf '%q ' "${run_args[@]}"
    printf '\n'
  fi

  while true; do
    attempt=$((attempt + 1))
    output_file="$(mktemp "/tmp/comparevi-cli-output-${attempt}-XXXXXX.log")"
    xvfb-run -a "${CLI_PATH}" "${run_args[@]}" </dev/null >"${output_file}" 2>&1
    exit_code=$?
    output_text="$(cat "${output_file}")"
    rm -f "${output_file}"
    printf "%s\n" "${output_text}"

    if [ "${exit_code}" = "0" ]; then
      break
    fi

    if [ "${exit_code}" = "1" ] && ! printf "%s" "${output_text}" | grep -Eq "Error code|An error occurred while running the LabVIEW CLI|-350000"; then
      break
    fi

    if printf "%s" "${output_text}" | grep -q -- "-350000" && [ "${attempt}" -le "${MAX_RETRIES}" ]; then
      RETRY_TRIGGERED=1
      sleep "${RETRY_DELAY}"
      continue
    fi

    break
  done

  TOTAL_COMPARE_ATTEMPTS=$((TOTAL_COMPARE_ATTEMPTS + attempt))
  LAST_COMPARE_EXIT_CODE="${exit_code}"
  LAST_COMPARE_STARTED_AT="${started_at}"
  return 0
}

if [ -n "${PAIR_PLAN_PATH}" ] && [ -s "${PAIR_PLAN_PATH}" ]; then
  pair_ledger_dir="$(dirname "${PAIR_RESULT_LEDGER}")"
  if [ -n "${pair_ledger_dir}" ]; then
    mkdir -p "${pair_ledger_dir}" || exit 2
  fi
  : > "${PAIR_RESULT_LEDGER}" || exit 2

  while IFS="$(printf '\t')" read -r pair_index pair_base_ref pair_head_ref pair_base_vi pair_head_vi pair_report_path pair_out_name; do
    local_pair_exit_code=0
    local_pair_status="completed"
    local_pair_diff="false"
    compare_report_asset_dir="${COMPARE_REPORT_PATH%.*}_files"

    [ -z "${pair_index:-}" ] && continue
    require_compare_input "COMPARE_BASE_VI" "${pair_base_vi:-}"
    require_compare_input "COMPARE_HEAD_VI" "${pair_head_vi:-}"
    TOTAL_PROCESSED_PAIRS=$((TOTAL_PROCESSED_PAIRS + 1))

    rm -f "${COMPARE_REPORT_PATH}"
    rm -rf "${compare_report_asset_dir}"
    if [ -n "${pair_report_path:-}" ] && [ "${pair_report_path}" != "${COMPARE_REPORT_PATH}" ]; then
      rm -f "${pair_report_path}"
      rm -rf "$(dirname "${pair_report_path}")/$(basename "${pair_report_path%.*}")_files"
    fi

    run_compare_with_retry "${pair_base_vi}" "${pair_head_vi}" "${COMPARE_REPORT_PATH}"
    local_pair_exit_code="${LAST_COMPARE_EXIT_CODE}"
    if [ "${local_pair_exit_code}" = "1" ]; then
      local_pair_diff="true"
      if [ "${EXIT_CODE}" = "0" ]; then
        EXIT_CODE=1
      fi
    elif [ "${local_pair_exit_code}" != "0" ]; then
      local_pair_status="error"
      EXIT_CODE=2
    fi

    if [ -n "${pair_report_path:-}" ] && [ -f "${COMPARE_REPORT_PATH}" ]; then
      pair_report_dir="$(dirname "${pair_report_path}")"
      if [ -n "${pair_report_dir}" ]; then
        mkdir -p "${pair_report_dir}" || exit 2
      fi
      if [ "${pair_report_path}" != "${COMPARE_REPORT_PATH}" ]; then
        cp -f "${COMPARE_REPORT_PATH}" "${pair_report_path}" || exit 2
      fi
      if declare -F comparevi_vi_history_stage_pair_report_bundle >/dev/null 2>&1; then
        comparevi_vi_history_stage_pair_report_bundle "${COMPARE_REPORT_PATH}" "${pair_report_path}" || exit 2
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${pair_index}" "${local_pair_exit_code}" "${local_pair_status}" "${local_pair_diff}" "${pair_report_path:-${COMPARE_REPORT_PATH}}" "${LAST_COMPARE_STARTED_AT}" >> "${PAIR_RESULT_LEDGER}" || exit 2
    if [ "${local_pair_exit_code}" != "0" ] && [ "${local_pair_exit_code}" != "1" ]; then
      break
    fi
  done < "${PAIR_PLAN_PATH}"
else
  require_compare_input "COMPARE_BASE_VI" "${COMPARE_BASE_VI:-}"
  require_compare_input "COMPARE_HEAD_VI" "${COMPARE_HEAD_VI:-}"
  TOTAL_PROCESSED_PAIRS=1
  rm -f "${COMPARE_REPORT_PATH}"
  run_compare_with_retry "${COMPARE_BASE_VI}" "${COMPARE_HEAD_VI}" "${COMPARE_REPORT_PATH}"
  EXIT_CODE="${LAST_COMPARE_EXIT_CODE}"
fi

if declare -F comparevi_vi_history_emit_suite_bundle >/dev/null 2>&1; then
  if ! comparevi_vi_history_emit_suite_bundle "${EXIT_CODE}" "${COMPARE_REPORT_PATH}" "${SUITE_STARTED_AT}"; then
    echo "VI history suite bootstrap finalization failed." 1>&2
    EXIT_CODE=2
  fi
fi

printf "%s\n" "[ni-linux-meta]retryAttempts=${TOTAL_COMPARE_ATTEMPTS};retryTriggered=${RETRY_TRIGGERED};pairsProcessed=${TOTAL_PROCESSED_PAIRS};prelaunchAttempted=${PRELAUNCH_ATTEMPTED};iniPath=${INI_PATH};openTimeout=${COMPARE_OPEN_APP_TIMEOUT:-180};afterLaunchTimeout=${COMPARE_AFTER_LAUNCH_TIMEOUT:-180}"
exit "${EXIT_CODE}"
'@
}

function New-DockerProcessInvocation {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs
  )

  $dockerCommandSource = Resolve-DockerCommandSource
  $dockerCommandDirectory = Split-Path -Parent $dockerCommandSource
  $dockerCommandStem = [System.IO.Path]::GetFileNameWithoutExtension($dockerCommandSource)
  $dockerCommandExtension = [System.IO.Path]::GetExtension($dockerCommandSource)
  if ([System.StringComparer]::OrdinalIgnoreCase.Equals($dockerCommandExtension, '.cmd') -or [System.StringComparer]::OrdinalIgnoreCase.Equals($dockerCommandExtension, '.bat')) {
    $adjacentExecutable = Join-Path $dockerCommandDirectory ('{0}.exe' -f $dockerCommandStem)
    $adjacentScript = Join-Path $dockerCommandDirectory ('{0}.ps1' -f $dockerCommandStem)
    if (Test-Path -LiteralPath $adjacentExecutable -PathType Leaf) {
      $dockerCommandSource = [System.IO.Path]::GetFullPath($adjacentExecutable)
      $dockerCommandExtension = '.exe'
    } elseif (Test-Path -LiteralPath $adjacentScript -PathType Leaf) {
      $dockerCommandSource = [System.IO.Path]::GetFullPath($adjacentScript)
      $dockerCommandExtension = '.ps1'
    }
  }

  $startFilePath = $dockerCommandSource
  $startArgs = @($DockerArgs)
  if ([System.StringComparer]::OrdinalIgnoreCase.Equals($dockerCommandExtension, '.ps1')) {
    $pwshExe = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
    $startFilePath = $pwshExe
    $startArgs = @('-NoLogo', '-NoProfile', '-File', $dockerCommandSource) + @($DockerArgs)
  }

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $startFilePath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($arg in @($startArgs)) {
    [void]$psi.ArgumentList.Add([string]$arg)
  }

  $process = [System.Diagnostics.Process]::new()
  $process.StartInfo = $psi
  [void]$process.Start()

  return [pscustomobject]@{
    Process = $process
    StdOutTask = $process.StandardOutput.ReadToEndAsync()
    StdErrTask = $process.StandardError.ReadToEndAsync()
  }
}

function Complete-DockerProcessInvocation {
  param(
    [Parameter(Mandatory)]$Invocation
  )

  $process = $Invocation.Process
  try {
    $process.WaitForExit()
  } catch {}

  return [pscustomobject]@{
    StdOut = $Invocation.StdOutTask.GetAwaiter().GetResult()
    StdErr = $Invocation.StdErrTask.GetAwaiter().GetResult()
  }
}

function Invoke-DockerRunWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$ContainerName,
    [int]$HeartbeatSeconds = 15
  )

  $invocation = $null
  try {
    $invocation = New-DockerProcessInvocation -DockerArgs $DockerArgs
    $process = $invocation.Process

    $timeoutSeconds = [Math]::Max(1, $Seconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $pollMs = 500
    $heartbeatWindow = [Math]::Max(5, $HeartbeatSeconds)
    $lastHeartbeat = Get-Date
    while (-not $process.HasExited) {
      if ((Get-Date) -ge $deadline) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        $capturedOutput = Complete-DockerProcessInvocation -Invocation $invocation
        return [pscustomobject]@{
          TimedOut = $true
          ExitCode = $script:TimeoutExitCode
          StdOut   = $capturedOutput.StdOut
          StdErr   = $capturedOutput.StdErr
        }
      }
      $elapsedSeconds = [math]::Round(((Get-Date) - $process.StartTime).TotalSeconds, 1)
      if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatWindow) {
        Write-Host ("[ni-linux-container-compare] running container={0} elapsed={1}s timeout={2}s" -f $ContainerName, $elapsedSeconds, $timeoutSeconds) -ForegroundColor DarkGray
        $lastHeartbeat = Get-Date
      }
      Start-Sleep -Milliseconds $pollMs
    }
    if (-not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      $capturedOutput = Complete-DockerProcessInvocation -Invocation $invocation
      return [pscustomobject]@{
        TimedOut = $true
        ExitCode = $script:TimeoutExitCode
        StdOut   = $capturedOutput.StdOut
        StdErr   = $capturedOutput.StdErr
      }
    }

    $capturedOutput = Complete-DockerProcessInvocation -Invocation $invocation
    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut   = $capturedOutput.StdOut
      StdErr   = $capturedOutput.StdErr
    }
  } finally {
    if ($invocation -and $invocation.Process) {
      try { $invocation.Process.Dispose() } catch {}
    }
  }
}

function Invoke-DockerExecWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$ContainerName,
    [int]$HeartbeatSeconds = 15
  )

  $invocation = $null
  try {
    $invocation = New-DockerProcessInvocation -DockerArgs $DockerArgs
    $process = $invocation.Process

    $timeoutSeconds = [Math]::Max(1, $Seconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $pollMs = 500
    $heartbeatWindow = [Math]::Max(5, $HeartbeatSeconds)
    $lastHeartbeat = Get-Date
    while (-not $process.HasExited) {
      if ((Get-Date) -ge $deadline) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        try { & docker exec $ContainerName sh -lc 'pkill -f LabVIEWCLI || true' *> $null } catch {}
        try { & docker stop --time 1 $ContainerName *> $null } catch {}
        $capturedOutput = Complete-DockerProcessInvocation -Invocation $invocation
        return [pscustomobject]@{
          TimedOut = $true
          ExitCode = $script:TimeoutExitCode
          StdOut   = $capturedOutput.StdOut
          StdErr   = $capturedOutput.StdErr
        }
      }

      if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatWindow) {
        Write-Host ("[ni-linux-container-compare] waiting for docker exec in container '{0}'..." -f $ContainerName) -ForegroundColor DarkGray
        $lastHeartbeat = Get-Date
      }
      Start-Sleep -Milliseconds $pollMs
    }

    $capturedOutput = Complete-DockerProcessInvocation -Invocation $invocation
    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut   = $capturedOutput.StdOut
      StdErr   = $capturedOutput.StdErr
    }
  } finally {
    if ($invocation -and $invocation.Process) {
      try { $invocation.Process.Dispose() } catch {}
    }
  }
}

function Write-TextArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  if ($null -eq $Content) { $Content = '' }
  Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function Write-UnixScriptArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()][string]$Content
  )
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  if ($null -eq $Content) { $Content = '' }
  $normalized = ([string]$Content) -replace "`r`n", "`n"
  $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $normalized, $utf8NoBom)
}

function Test-LabVIEWCliFailure {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut
  )

  $combined = @($StdErr, $StdOut) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }
  return (
    $combined -match 'Error code\s*:' -or
    $combined -match 'An error occurred while running the LabVIEW CLI'
  )
}

function Resolve-RunFailureMessage {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut,
    [Parameter(Mandatory)][int]$ExitCode
  )

  foreach ($candidate in @($StdErr, $StdOut)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $match = [regex]::Match($candidate, 'Error message\s*:\s*(.+)')
    if ($match.Success -and -not [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
      return $match.Groups[1].Value.Trim()
    }
    $lines = @($candidate -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0) {
      return $lines[-1].Trim()
    }
  }

  return ("Container compare failed with exit code {0}." -f $ExitCode)
}

function Parse-MetaLine {
  param([AllowNull()][string]$StdOut)
  $meta = [ordered]@{
    retryAttempts     = 0
    retryTriggered    = $false
    prelaunchAttempted= $false
    iniPath           = ''
    openTimeout       = 180
    afterLaunchTimeout= 180
  }
  if ([string]::IsNullOrWhiteSpace($StdOut)) {
    return $meta
  }
  $line = ($StdOut -split "`r?`n" | Where-Object { $_ -match '^\[ni-linux-meta\]' } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) { return $meta }
  $payload = $line -replace '^\[ni-linux-meta\]', ''
  foreach ($entry in ($payload -split ';')) {
    if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '=') { continue }
    $parts = $entry -split '=', 2
    $k = $parts[0].Trim()
    $v = $parts[1].Trim()
    switch ($k) {
      'retryAttempts' { [void][int]::TryParse($v, [ref]$meta.retryAttempts) }
      'retryTriggered' { $meta.retryTriggered = [string]::Equals($v, '1', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($v, 'true', [System.StringComparison]::OrdinalIgnoreCase) }
      'prelaunchAttempted' { $meta.prelaunchAttempted = [string]::Equals($v, '1', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($v, 'true', [System.StringComparison]::OrdinalIgnoreCase) }
      'iniPath' { $meta.iniPath = $v }
      'openTimeout' { [void][int]::TryParse($v, [ref]$meta.openTimeout) }
      'afterLaunchTimeout' { [void][int]::TryParse($v, [ref]$meta.afterLaunchTimeout) }
    }
  }
  return $meta
}

function Export-ContainerArtifacts {
  param(
    [Parameter(Mandatory)][string]$ContainerName,
    [AllowNull()][string]$ContainerReportPath,
    [AllowNull()][string]$HostReportPath,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [AllowEmptyCollection()][string[]]$AdditionalContainerPaths = @()
  )

  $exportDir = Join-Path $ReportDirectory 'container-export'
  if (-not (Test-Path -LiteralPath $exportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
  }

  $copiedPaths = New-Object System.Collections.Generic.List[string]
  $copyAttempts = New-Object System.Collections.Generic.List[object]
  $attemptCount = 0
  $successCount = 0
  $recoveredCopyCount = 0
  $reportPathExtracted = ''

  if (-not [string]::IsNullOrWhiteSpace($ContainerReportPath)) {
    $attemptCount++
    $reportLeaf = Split-Path -Leaf $ContainerReportPath
    if ([string]::IsNullOrWhiteSpace($reportLeaf)) {
      $reportLeaf = 'linux-compare-report.html'
    }
    $reportPathExtracted = Join-Path $exportDir $reportLeaf
    if (Test-Path -LiteralPath $reportPathExtracted -PathType Leaf -ErrorAction SilentlyContinue) {
      Remove-Item -LiteralPath $reportPathExtracted -Force -ErrorAction SilentlyContinue
    }
    $sourceSpec = '{0}:{1}' -f $ContainerName, $ContainerReportPath
    & docker cp $sourceSpec $reportPathExtracted *> $null
    $copyExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $artifactPresent = Test-Path -LiteralPath $reportPathExtracted -PathType Leaf -ErrorAction SilentlyContinue
    $recoveredFromNonZeroExit = ($copyExitCode -ne 0 -and $artifactPresent)
    $recoveredFromHostReport = $false
    if (
      -not $artifactPresent -and
      -not [string]::IsNullOrWhiteSpace($HostReportPath) -and
      (Test-Path -LiteralPath $HostReportPath -PathType Leaf -ErrorAction SilentlyContinue)
    ) {
      Copy-Item -LiteralPath $HostReportPath -Destination $reportPathExtracted -Force -ErrorAction Stop
      $hostReportLeaf = [System.IO.Path]::GetFileNameWithoutExtension($HostReportPath)
      $hostAssetDir = Join-Path (Split-Path -Parent $HostReportPath) ("{0}_files" -f $hostReportLeaf)
      if (Test-Path -LiteralPath $hostAssetDir -PathType Container -ErrorAction SilentlyContinue) {
        $assetDestination = Join-Path $exportDir (Split-Path -Leaf $hostAssetDir)
        if (Test-Path -LiteralPath $assetDestination -PathType Container -ErrorAction SilentlyContinue) {
          Remove-Item -LiteralPath $assetDestination -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -LiteralPath $hostAssetDir -Destination $assetDestination -Recurse -Force -ErrorAction Stop
      }
      $artifactPresent = Test-Path -LiteralPath $reportPathExtracted -PathType Leaf -ErrorAction SilentlyContinue
      $recoveredFromHostReport = [bool]$artifactPresent
    }
    if ($artifactPresent) {
      $successCount++
      $copiedPaths.Add($reportPathExtracted) | Out-Null
    }
    if ($recoveredFromNonZeroExit -or $recoveredFromHostReport) {
      $recoveredCopyCount++
    }
    $copyAttempts.Add([ordered]@{
      sourcePath = $ContainerReportPath
      destinationPath = $reportPathExtracted
      exitCode = [int]$copyExitCode
      artifactPresent = [bool]$artifactPresent
      recoveredFromNonZeroExit = [bool]$recoveredFromNonZeroExit
      recoveredFromHostReport = [bool]$recoveredFromHostReport
      recoveryKind = if ($recoveredFromHostReport) { 'host-report' } elseif ($recoveredFromNonZeroExit) { 'nonzero-exit' } else { 'none' }
    }) | Out-Null
    if (-not $artifactPresent) {
      $reportPathExtracted = ''
    }
  }

  foreach ($containerPath in @($AdditionalContainerPaths)) {
    if ([string]::IsNullOrWhiteSpace($containerPath)) { continue }
    $attemptCount++
    $safeLeaf = Split-Path -Leaf $containerPath
    if ([string]::IsNullOrWhiteSpace($safeLeaf)) {
      $safeLeaf = ($containerPath -replace '[^a-zA-Z0-9._-]', '_')
    }
    $destinationPath = Join-Path $exportDir $safeLeaf
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf -ErrorAction SilentlyContinue) {
      Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
    }
    $sourceSpec = '{0}:{1}' -f $ContainerName, $containerPath
    & docker cp $sourceSpec $destinationPath *> $null
    $copyExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $artifactPresent = Test-Path -LiteralPath $destinationPath -PathType Leaf -ErrorAction SilentlyContinue
    $recoveredFromNonZeroExit = ($copyExitCode -ne 0 -and $artifactPresent)
    if ($artifactPresent) {
      $successCount++
      $copiedPaths.Add($destinationPath) | Out-Null
    }
    if ($recoveredFromNonZeroExit) {
      $recoveredCopyCount++
    }
    $copyAttempts.Add([ordered]@{
      sourcePath = $containerPath
      destinationPath = $destinationPath
      exitCode = [int]$copyExitCode
      artifactPresent = [bool]$artifactPresent
      recoveredFromNonZeroExit = [bool]$recoveredFromNonZeroExit
      recoveredFromHostReport = $false
      recoveryKind = if ($recoveredFromNonZeroExit) { 'nonzero-exit' } else { 'none' }
    }) | Out-Null
  }

  $copyStatus = 'not-attempted'
  if ($attemptCount -gt 0) {
    if ($successCount -eq $attemptCount) {
      $copyStatus = 'success'
    } elseif ($successCount -gt 0) {
      $copyStatus = 'partial'
    } else {
      $copyStatus = 'failed'
    }
  }

  return [ordered]@{
    exportDir = $exportDir
    copiedPaths = @($copiedPaths.ToArray())
    copyAttempts = @($copyAttempts.ToArray())
    copyStatus = $copyStatus
    recoveredCopyCount = [int]$recoveredCopyCount
    reportPathExtracted = $reportPathExtracted
  }
}

function Get-ReportAnalysis {
  param([AllowNull()][string]$ExtractedReportPath)

  $analysis = [ordered]@{
    source = 'container-export'
    reportPathExtracted = ($ExtractedReportPath ?? '')
    htmlParsed = $false
    diffMarkerCount = 0
    diffDetailCount = 0
    diffImageCount = 0
    hasDiffEvidence = $false
  }

  if ([string]::IsNullOrWhiteSpace($ExtractedReportPath) -or -not (Test-Path -LiteralPath $ExtractedReportPath -PathType Leaf)) {
    return $analysis
  }

  try {
    $html = Get-Content -LiteralPath $ExtractedReportPath -Raw -ErrorAction Stop
    $analysis.htmlParsed = $true
    $analysis.diffMarkerCount = [regex]::Matches($html, 'summary\.difference-heading', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $analysis.diffDetailCount = [regex]::Matches($html, 'li\.diff-detail(?:-cosmetic)?', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $analysis.diffImageCount = [regex]::Matches($html, '<img[^>]+class\s*=\s*["''][^"'']*difference-image', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $analysis.hasDiffEvidence = (($analysis.diffMarkerCount + $analysis.diffDetailCount + $analysis.diffImageCount) -gt 0)
  } catch {
    $analysis.htmlParsed = $false
    $analysis.hasDiffEvidence = $false
  }
  return $analysis
}

if ($TimeoutSeconds -le 0) {
  throw '-TimeoutSeconds must be greater than zero.'
}
if ($StartupRetryCount -lt 0) {
  throw '-StartupRetryCount must be zero or greater.'
}

$capture = [ordered]@{
  schema         = 'ni-linux-container-compare/v1'
  generatedAt    = (Get-Date).ToUniversalTime().ToString('o')
  image          = $Image
  reportType     = $ReportType
  timeoutSeconds = $TimeoutSeconds
  probe          = [bool]$Probe
  status         = 'init'
  exitCode       = $null
  timedOut       = $false
  dockerServerOs = $null
  dockerContext  = $null
  baseVi         = $null
  headVi         = $null
  reportPath     = $null
  containerName  = $null
  command        = $null
  stdoutPath     = $null
  stderrPath     = $null
  containerExecution = [ordered]@{
    mode = if ([string]::IsNullOrWhiteSpace($ReuseContainerName)) { 'docker-run' } else { 'docker-exec' }
    reusedContainerName = if ([string]::IsNullOrWhiteSpace($ReuseContainerName)) { '' } else { $ReuseContainerName }
    repoHostPath = ''
    repoContainerPath = ''
    resultsHostPath = ''
    resultsContainerPath = ''
  }
  runtimeDeterminism = $null
  runtimeInjection = [ordered]@{
    enabled = $false
    contractPath = ''
    contractMode = ''
    branchRef = ''
    maxCommitCount = $null
    scriptHostPath = ''
    scriptContainerPath = ''
    viHistory = [ordered]@{
      enabled = $false
      repoHostPath = ''
      repoContainerPath = ''
      targetPath = ''
      baselineRef = ''
      resultsHostPath = ''
      resultsContainerPath = ''
      suiteManifestContainerPath = ''
      historyContextContainerPath = ''
      bootstrapReceiptContainerPath = ''
      bootstrapMarkerContainerPath = ''
      maxPairs = $null
      branchBudget = $null
      gitInjection = [ordered]@{
        enabled = $false
        strategy = 'none'
        dotGitHostPath = ''
        commonGitHostPath = ''
        commonGitContainerPath = ''
        gitDirContainerPath = ''
        gitWorkTreeContainerPath = ''
      }
    }
    envNames = @()
    mounts = @()
  }
  headlessContract = [ordered]@{
    required = $true
    enforcedCliHeadless = $true
    lvRteHeadlessEnv = $true
    linuxRequiresHeadlessEveryInvocation = $true
  }
  startupMitigation = [ordered]@{
    startupRetryCount = $StartupRetryCount
    prelaunchWaitSeconds = $PrelaunchWaitSeconds
    retryDelaySeconds = $RetryDelaySeconds
    retryAttempts = 0
    retryTriggered = $false
    prelaunchAttempted = $false
    iniPath = ''
    openAppReferenceTimeoutInSecond = 180
    afterLaunchOpenAppReferenceTimeoutInSecond = 180
  }
  reportAnalysis = [ordered]@{
    source = 'container-export'
    reportPathExtracted = ''
    htmlParsed = $false
    diffMarkerCount = 0
    diffDetailCount = 0
    diffImageCount = 0
    hasDiffEvidence = $false
  }
  containerArtifacts = [ordered]@{
    exportDir = ''
    copiedPaths = @()
    copyAttempts = @()
    copyStatus = 'not-attempted'
    recoveredCopyCount = 0
  }
  diffEvidenceSource = 'fallback'
  resultClass = 'failure-preflight'
  isDiff = $false
  gateOutcome = 'fail'
  failureClass = 'preflight'
  message = $null
}

$finalExitCode = 0
$stdoutContent = ''
$stderrContent = ''
$capturePath = $null
$stdoutPath = $null
$stderrPath = $null
$containerScriptHostPath = $null
$containerNameForArtifacts = ''
$containerNameForCleanup = ''
$containerReportPathForExport = ''
$reportDirectoryForExport = ''
$additionalExportPaths = @()
$runtimeInjectionScriptContainerPath = ''

try {
  Assert-Tool -Name 'docker'

  $runtimeGuardPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Assert-DockerRuntimeDeterminism.ps1'
  if (-not (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf)) {
    throw ("Runtime guard script not found: {0}" -f $runtimeGuardPath)
  }
  $runtimeSnapshot = if ([string]::IsNullOrWhiteSpace($RuntimeSnapshotPath)) {
    $defaultRoot = Join-Path (Resolve-Path '.').Path 'tests/results/ni-linux-container'
    Join-Path $defaultRoot 'runtime-determinism.json'
  } else {
    if ([System.IO.Path]::IsPathRooted($RuntimeSnapshotPath)) {
      [System.IO.Path]::GetFullPath($RuntimeSnapshotPath)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path '.').Path $RuntimeSnapshotPath))
    }
  }
  $runtimeProvider = if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_DOCKER_RUNTIME_PROVIDER)) {
    'desktop'
  } else {
    $env:COMPAREVI_DOCKER_RUNTIME_PROVIDER.Trim()
  }
  $runtimeExpectedContext = if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_DOCKER_EXPECTED_CONTEXT)) {
    if ($runtimeProvider -eq 'desktop') { 'desktop-linux' } else { '' }
  } else {
    $env:COMPAREVI_DOCKER_EXPECTED_CONTEXT.Trim()
  }
  $runtimeExpectedDockerHost = if ($runtimeProvider -eq 'native-wsl') {
    if (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_DOCKER_EXPECTED_DOCKER_HOST)) {
      $env:COMPAREVI_DOCKER_EXPECTED_DOCKER_HOST.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($env:DOCKER_HOST)) {
      $env:DOCKER_HOST.Trim()
    } else {
      'unix:///var/run/docker.sock'
    }
  } else {
    ''
  }

  & pwsh -NoLogo -NoProfile -File $runtimeGuardPath `
    -ExpectedOsType linux `
    -RuntimeProvider $runtimeProvider `
    -ExpectedContext $runtimeExpectedContext `
    -ExpectedDockerHost $runtimeExpectedDockerHost `
    -AutoRepair:$AutoRepairRuntime `
    -ManageDockerEngine:($runtimeProvider -eq 'desktop') `
    -AllowHostEngineMutation:$false `
    -EngineReadyTimeoutSeconds $RuntimeEngineReadyTimeoutSeconds `
    -EngineReadyPollSeconds $RuntimeEngineReadyPollSeconds `
    -SnapshotPath $runtimeSnapshot `
    -GitHubOutputPath ''
  if ($LASTEXITCODE -ne 0) {
    throw ("Runtime determinism guard failed with exit code {0}. Snapshot: {1}" -f $LASTEXITCODE, $runtimeSnapshot)
  }

  $runtimeStatus = 'unknown'
  try {
    $runtimeObj = Get-Content -LiteralPath $runtimeSnapshot -Raw | ConvertFrom-Json -ErrorAction Stop
    $runtimeStatus = $runtimeObj.result.status
    $capture.runtimeDeterminism = [ordered]@{
      status = $runtimeObj.result.status
      reason = $runtimeObj.result.reason
      snapshotPath = $runtimeSnapshot
      expected = $runtimeObj.expected
      observed = [ordered]@{
        osType = $runtimeObj.observed.osType
        context = $runtimeObj.observed.context
      }
    }
    $capture.dockerServerOs = $runtimeObj.observed.osType
    $capture.dockerContext = $runtimeObj.observed.context
  } catch {
    $capture.runtimeDeterminism = [ordered]@{
      status = 'error'
      reason = ("Failed to parse runtime snapshot: {0}" -f $_.Exception.Message)
      snapshotPath = $runtimeSnapshot
    }
  }
  if ($runtimeStatus -eq 'mismatch-failed') {
    throw ("Docker runtime determinism mismatch. See snapshot: {0}" -f $runtimeSnapshot)
  }

  $useExistingContainer = -not [string]::IsNullOrWhiteSpace($ReuseContainerName)
  $reusedContainerRecord = $null
  if ($useExistingContainer) {
    $reusedContainerRecord = Get-DockerContainerRecord -ContainerName $ReuseContainerName
    if ($null -eq $reusedContainerRecord) {
      throw ("Reused container '{0}' not found." -f $ReuseContainerName)
    }
    if (-not $reusedContainerRecord.running) {
      throw ("Reused container '{0}' is not running (status={1})." -f $ReuseContainerName, $reusedContainerRecord.status)
    }
    if (
      -not [string]::IsNullOrWhiteSpace($Image) -and
      -not [string]::Equals([string]$reusedContainerRecord.image, $Image, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
      throw ("Reused container '{0}' is running image '{1}', but '{2}' was requested." -f $ReuseContainerName, $reusedContainerRecord.image, $Image)
    }
    $capture.containerExecution.reusedContainerName = $ReuseContainerName
  } elseif (-not (Test-DockerImageExists -Tag $Image)) {
    throw ("Docker image '{0}' not found locally. Pull it first: docker pull {0}" -f $Image)
  }

  if ($Probe) {
    $capture.status = if ($useExistingContainer) { 'probe-reuse-ok' } else { 'probe-ok' }
    $capture.exitCode = 0
    $capture.message = if ($useExistingContainer) {
      ("Docker is in linux mode and reused container '{0}' is running image '{1}'." -f $ReuseContainerName, $reusedContainerRecord.image)
    } else {
      ("Docker is in linux mode and image '{0}' is available." -f $Image)
    }
    Write-Host ("[ni-linux-container-probe] {0}" -f $capture.message) -ForegroundColor Green
  } else {
    $reservedRuntimeInjectionVars = @(
      'COMPARE_BASE_VI',
      'COMPARE_HEAD_VI',
      'COMPARE_REPORT_PATH',
      'COMPARE_REPORT_TYPE',
      'COMPARE_FLAGS_B64',
      'LV_RTE_HEADLESS',
      'COMPARE_PRELAUNCH_ENABLED',
      'COMPARE_PRELAUNCH_WAIT_SECONDS',
      'COMPARE_STARTUP_RETRY_COUNT',
      'COMPARE_RETRY_DELAY_SECONDS',
      'COMPARE_OPEN_APP_TIMEOUT',
      'COMPARE_AFTER_LAUNCH_TIMEOUT',
      'COMPARE_LABVIEW_PATH',
      'COMPARE_RUNTIME_INJECTION_SCRIPT',
      'COMPAREVI_VI_HISTORY_BOOTSTRAP_MODE',
      'COMPAREVI_VI_HISTORY_REPO_PATH',
      'COMPAREVI_VI_HISTORY_TARGET_PATH',
      'COMPAREVI_VI_HISTORY_BASELINE_REF',
      'COMPAREVI_VI_HISTORY_RESULTS_DIR',
      'COMPAREVI_VI_HISTORY_SUITE_MANIFEST',
      'COMPAREVI_VI_HISTORY_CONTEXT',
      'COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT',
      'COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER',
      'COMPAREVI_VI_HISTORY_SOURCE_BRANCH',
      'COMPAREVI_VI_HISTORY_MAX_BRANCH_COMMITS',
      'COMPAREVI_VI_HISTORY_BRANCH_COMMIT_COUNT',
      'COMPAREVI_VI_HISTORY_MAX_PAIRS',
      'COMPAREVI_VI_HISTORY_GIT_DIR',
      'COMPAREVI_VI_HISTORY_GIT_WORK_TREE'
    )
    $resolvedRuntimeBootstrap = Resolve-RuntimeBootstrapContract `
      -ContractPath $RuntimeBootstrapContractPath `
      -ReservedNames $reservedRuntimeInjectionVars
    if (
      -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.scriptPath) -and
      -not [string]::IsNullOrWhiteSpace($RuntimeInjectionScriptPath)
    ) {
      throw 'Specify either -RuntimeBootstrapContractPath or -RuntimeInjectionScriptPath for the injection script, not both.'
    }

    $viHistoryEnabled = [bool](
      $resolvedRuntimeBootstrap.viHistory -and
      $resolvedRuntimeBootstrap.viHistory.PSObject.Properties['enabled'] -and
      $resolvedRuntimeBootstrap.viHistory.enabled
    )
    $baseViPath = if ([string]::IsNullOrWhiteSpace($BaseVi)) {
      if ($viHistoryEnabled) { '' } else { throw '-BaseVi is required unless -Probe or runtime bootstrap viHistory is configured.' }
    } else {
      Resolve-ExistingFilePath -InputPath $BaseVi -ParameterName 'BaseVi'
    }
    $headViPath = if ([string]::IsNullOrWhiteSpace($HeadVi)) {
      if ($viHistoryEnabled) { '' } else { throw '-HeadVi is required unless -Probe or runtime bootstrap viHistory is configured.' }
    } else {
      Resolve-ExistingFilePath -InputPath $HeadVi -ParameterName 'HeadVi'
    }

    $reportInfo = Resolve-ReportTypeInfo -Type $ReportType
    $resolvedReportPath = if (
      [string]::IsNullOrWhiteSpace($ReportPath) -and
      $viHistoryEnabled -and
      -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath)
    ) {
      Join-Path ([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath) ("linux-compare-report.{0}" -f $reportInfo.Extension)
    } else {
      Resolve-OutputReportPath -PathValue $ReportPath -Extension $reportInfo.Extension
    }
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf) {
      Remove-Item -LiteralPath $resolvedReportPath -Force -ErrorAction SilentlyContinue
    }

    $capturePath = Join-Path $reportDirectory 'ni-linux-container-capture.json'
    $stdoutPath = Join-Path $reportDirectory 'ni-linux-container-stdout.txt'
    $stderrPath = Join-Path $reportDirectory 'ni-linux-container-stderr.txt'
    $resolvedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      if ([string]::IsNullOrWhiteSpace($env:NI_LINUX_LABVIEW_PATH)) { '' } else { $env:NI_LINUX_LABVIEW_PATH.Trim() }
    } else {
      $LabVIEWPath.Trim()
    }

    $capture.baseVi = if ([string]::IsNullOrWhiteSpace($baseViPath)) { $null } else { $baseViPath }
    $capture.headVi = if ([string]::IsNullOrWhiteSpace($headViPath)) { $null } else { $headViPath }
    $capture.reportPath = $resolvedReportPath
    $capture.labviewPath = $resolvedLabVIEWPath
    $capture.stdoutPath = $stdoutPath
    $capture.stderrPath = $stderrPath
    $resolvedRuntimeInjectionScriptPath = if (-not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.scriptPath)) {
      [string]$resolvedRuntimeBootstrap.scriptPath
    } elseif ([string]::IsNullOrWhiteSpace($RuntimeInjectionScriptPath)) {
      ''
    } else {
      Resolve-ExistingFilePath -InputPath $RuntimeInjectionScriptPath -ParameterName 'RuntimeInjectionScriptPath'
    }
    $resolvedRuntimeInjectionEnv = @($resolvedRuntimeBootstrap.env) + @(
      Resolve-RuntimeInjectionEnvEntries `
        -Entries $RuntimeInjectionEnv `
        -ReservedNames $reservedRuntimeInjectionVars
    )
    $resolvedRuntimeInjectionMounts = @($resolvedRuntimeBootstrap.mounts) + @(
      Resolve-RuntimeInjectionMountEntries -Entries $RuntimeInjectionMount
    )
    $runtimeInjectionEnabled = (
      (-not [string]::IsNullOrWhiteSpace($resolvedRuntimeInjectionScriptPath)) -or
      $resolvedRuntimeInjectionEnv.Count -gt 0 -or
      $resolvedRuntimeInjectionMounts.Count -gt 0
    )
    $capture.runtimeInjection = [ordered]@{
      enabled = [bool]$runtimeInjectionEnabled
      contractPath = [string]$resolvedRuntimeBootstrap.contractPath
      contractMode = [string]$resolvedRuntimeBootstrap.mode
      branchRef = [string]$resolvedRuntimeBootstrap.branchRef
      maxCommitCount = $resolvedRuntimeBootstrap.maxCommitCount
      scriptHostPath = [string]$resolvedRuntimeInjectionScriptPath
      scriptContainerPath = ''
      viHistory = [ordered]@{
        enabled = [bool]$viHistoryEnabled
        repoHostPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.repoHostPath } else { '' }
        repoContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.repoContainerPath } else { '' }
        targetPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.targetPath } else { '' }
        baselineRef = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.baselineRef } else { '' }
        bootstrapMode = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.bootstrapMode } else { '' }
        resultsHostPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath } else { '' }
        resultsContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.resultsContainerPath } else { '' }
        suiteManifestContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.suiteManifestContainerPath } else { '' }
        historyContextContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.historyContextContainerPath } else { '' }
        bootstrapReceiptContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.bootstrapReceiptContainerPath } else { '' }
        bootstrapMarkerContainerPath = if ($viHistoryEnabled) { [string]$resolvedRuntimeBootstrap.viHistory.bootstrapMarkerContainerPath } else { '' }
        maxPairs = if ($viHistoryEnabled) { $resolvedRuntimeBootstrap.viHistory.maxPairs } else { $null }
        branchBudget = if ($viHistoryEnabled) { $resolvedRuntimeBootstrap.viHistory.branchBudget } else { $null }
        gitInjection = if ($viHistoryEnabled) {
          [ordered]@{
            enabled = [bool]$resolvedRuntimeBootstrap.viHistory.gitInjection.enabled
            strategy = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.strategy
            dotGitHostPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.dotGitHostPath
            commonGitHostPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.commonGitHostPath
            commonGitContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.commonGitContainerPath
            gitDirContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.gitDirContainerPath
            gitWorkTreeContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.gitWorkTreeContainerPath
          }
        } else {
          [ordered]@{
            enabled = $false
            strategy = 'none'
            dotGitHostPath = ''
            commonGitHostPath = ''
            commonGitContainerPath = ''
            gitDirContainerPath = ''
            gitWorkTreeContainerPath = ''
          }
        }
      }
      envNames = @($resolvedRuntimeInjectionEnv | ForEach-Object { [string]$_.name })
      mounts = @(
        $resolvedRuntimeInjectionMounts | ForEach-Object {
          [ordered]@{
            hostPath = [string]$_.hostPath
            containerPath = [string]$_.containerPath
            kind = [string]$_.kind
          }
        }
      )
    }
    if (-not $capture.runtimeDeterminism) {
      $capture.runtimeDeterminism = [ordered]@{
        status = 'unknown'
        snapshotPath = $runtimeSnapshot
      }
    } else {
      $capture.runtimeDeterminism.snapshotPath = $runtimeSnapshot
    }

    [string[]]$flagsPayload = @(Get-EffectiveCompareFlags -InputFlags $Flags)
    $capture.flags = @($flagsPayload)
    $flagsJoined = ''
    if ($null -ne $flagsPayload -and $flagsPayload.Length -gt 0) {
      $flagsJoined = [string]::Join("`n", [string[]]$flagsPayload)
    }
    $flagsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($flagsJoined))

    $mounts = @{}
    $mountIndex = 0
    $mountRef = [ref]$mountIndex
    $existingContainerMappings = @()
    $containerBaseVi = ''
    $containerHeadVi = ''
    $containerReportPath = ''
    if ($useExistingContainer) {
      $reuseRepoHostPathResolved = if ([string]::IsNullOrWhiteSpace($ReuseRepoHostPath)) {
        if ($viHistoryEnabled -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.viHistory.repoHostPath)) {
          Resolve-ExistingPathFromBaseDirectory `
            -BaseDirectory $reportDirectory `
            -InputPath ([string]$resolvedRuntimeBootstrap.viHistory.repoHostPath) `
            -ParameterName 'ReuseRepoHostPath'
        } else {
          throw '-ReuseRepoHostPath is required when -ReuseContainerName is set.'
        }
      } else {
        Resolve-ExistingPathFromBaseDirectory `
          -BaseDirectory $reportDirectory `
          -InputPath $ReuseRepoHostPath `
          -ParameterName 'ReuseRepoHostPath'
      }
      if (-not (Test-Path -LiteralPath $reuseRepoHostPathResolved -PathType Container)) {
        throw ("-ReuseRepoHostPath must resolve to a directory: {0}" -f $reuseRepoHostPathResolved)
      }

      $reuseResultsHostPathResolved = if ([string]::IsNullOrWhiteSpace($ReuseResultsHostPath)) {
        if ($viHistoryEnabled -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath)) {
          [System.IO.Path]::GetFullPath([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath)
        } else {
          $reportDirectory
        }
      } else {
        $effectiveResultsInput = Resolve-EffectivePathInput -InputPath $ReuseResultsHostPath -ParameterName 'ReuseResultsHostPath'
        if ([System.IO.Path]::IsPathRooted($effectiveResultsInput)) {
          [System.IO.Path]::GetFullPath($effectiveResultsInput)
        } else {
          [System.IO.Path]::GetFullPath((Join-Path $reportDirectory $effectiveResultsInput))
        }
      }
      if (-not (Test-Path -LiteralPath $reuseResultsHostPathResolved -PathType Container)) {
        New-Item -ItemType Directory -Path $reuseResultsHostPathResolved -Force | Out-Null
      }

      if ($viHistoryEnabled) {
        if (-not (Test-HostPathWithinRoot -RootPath $reuseRepoHostPathResolved -HostPath ([string]$resolvedRuntimeBootstrap.viHistory.repoHostPath))) {
          throw ("Runtime bootstrap repo path '{0}' is not covered by -ReuseRepoHostPath '{1}'." -f [string]$resolvedRuntimeBootstrap.viHistory.repoHostPath, $reuseRepoHostPathResolved)
        }
        if (-not (Test-HostPathWithinRoot -RootPath $reuseResultsHostPathResolved -HostPath ([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath))) {
          throw ("Runtime bootstrap results path '{0}' is not covered by -ReuseResultsHostPath '{1}'." -f [string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath, $reuseResultsHostPathResolved)
        }
      }

      $existingContainerMappings += [pscustomobject]@{
        hostPath = [string]$reuseResultsHostPathResolved
        containerPath = [string]$ReuseResultsContainerPath
      }
      $existingContainerMappings += [pscustomobject]@{
        hostPath = [string]$reuseRepoHostPathResolved
        containerPath = [string]$ReuseRepoContainerPath
      }
      if (
        $viHistoryEnabled -and
        $resolvedRuntimeBootstrap.viHistory.gitInjection.enabled -and
        -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.viHistory.gitInjection.commonGitHostPath)
      ) {
        $existingContainerMappings += [pscustomobject]@{
          hostPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.commonGitHostPath
          containerPath = [string]$resolvedRuntimeBootstrap.viHistory.gitInjection.commonGitContainerPath
        }
      }
      if ($viHistoryEnabled) {
        $mappedViHistoryResultsContainerPath = Convert-HostPathToExistingContainerPath `
          -HostPath ([string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath) `
          -Mappings $existingContainerMappings `
          -Description 'Runtime bootstrap results path'
        $resolvedRuntimeBootstrap.viHistory.resultsContainerPath = $mappedViHistoryResultsContainerPath
        $resolvedRuntimeBootstrap.viHistory.suiteManifestContainerPath = '{0}/suite-manifest.json' -f $mappedViHistoryResultsContainerPath.TrimEnd('/')
        $resolvedRuntimeBootstrap.viHistory.historyContextContainerPath = '{0}/history-context.json' -f $mappedViHistoryResultsContainerPath.TrimEnd('/')
        $resolvedRuntimeBootstrap.viHistory.bootstrapReceiptContainerPath = '{0}/vi-history-bootstrap-receipt.json' -f $mappedViHistoryResultsContainerPath.TrimEnd('/')
        $resolvedRuntimeBootstrap.viHistory.bootstrapMarkerContainerPath = '{0}/vi-history-bootstrap-ran.txt' -f $mappedViHistoryResultsContainerPath.TrimEnd('/')
        $capture.runtimeInjection.viHistory.resultsContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.resultsContainerPath
        $capture.runtimeInjection.viHistory.suiteManifestContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.suiteManifestContainerPath
        $capture.runtimeInjection.viHistory.historyContextContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.historyContextContainerPath
        $capture.runtimeInjection.viHistory.bootstrapReceiptContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.bootstrapReceiptContainerPath
        $capture.runtimeInjection.viHistory.bootstrapMarkerContainerPath = [string]$resolvedRuntimeBootstrap.viHistory.bootstrapMarkerContainerPath

        foreach ($runtimeMount in @($resolvedRuntimeInjectionMounts)) {
          if ([string]::Equals([string]$runtimeMount.hostPath, [string]$resolvedRuntimeBootstrap.viHistory.resultsHostPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $runtimeMount.containerPath = [string]$resolvedRuntimeBootstrap.viHistory.resultsContainerPath
          }
        }

        foreach ($runtimeEnv in @($resolvedRuntimeInjectionEnv)) {
          switch ([string]$runtimeEnv.name) {
            'COMPAREVI_VI_HISTORY_RESULTS_DIR' { $runtimeEnv.value = [string]$resolvedRuntimeBootstrap.viHistory.resultsContainerPath }
            'COMPAREVI_VI_HISTORY_SUITE_MANIFEST' { $runtimeEnv.value = [string]$resolvedRuntimeBootstrap.viHistory.suiteManifestContainerPath }
            'COMPAREVI_VI_HISTORY_CONTEXT' { $runtimeEnv.value = [string]$resolvedRuntimeBootstrap.viHistory.historyContextContainerPath }
            'COMPAREVI_VI_HISTORY_BOOTSTRAP_RECEIPT' { $runtimeEnv.value = [string]$resolvedRuntimeBootstrap.viHistory.bootstrapReceiptContainerPath }
            'COMPAREVI_VI_HISTORY_BOOTSTRAP_MARKER' { $runtimeEnv.value = [string]$resolvedRuntimeBootstrap.viHistory.bootstrapMarkerContainerPath }
          }
        }
      }

      foreach ($runtimeMount in @($resolvedRuntimeInjectionMounts)) {
        $mappedContainerPath = Convert-HostPathToExistingContainerPath `
          -HostPath ([string]$runtimeMount.hostPath) `
          -Mappings $existingContainerMappings `
          -Description 'Runtime injection mount'
        $expectedContainerPath = ([string]$runtimeMount.containerPath).Replace('\', '/').TrimEnd('/')
        if (-not [string]::Equals($mappedContainerPath.TrimEnd('/'), $expectedContainerPath, [System.StringComparison]::Ordinal)) {
          throw ("Runtime injection mount '{0}' expects container path '{1}', but the reused container projects it as '{2}'." -f [string]$runtimeMount.hostPath, $expectedContainerPath, $mappedContainerPath)
        }
      }

      $containerBaseVi = if ([string]::IsNullOrWhiteSpace($baseViPath)) {
        ''
      } else {
        Convert-HostPathToExistingContainerPath -HostPath $baseViPath -Mappings $existingContainerMappings -Description 'Base VI'
      }
      $containerHeadVi = if ([string]::IsNullOrWhiteSpace($headViPath)) {
        ''
      } else {
        Convert-HostPathToExistingContainerPath -HostPath $headViPath -Mappings $existingContainerMappings -Description 'Head VI'
      }
      $containerReportPath = Convert-HostPathToExistingContainerPath -HostPath $resolvedReportPath -Mappings $existingContainerMappings -Description 'Report path'
      $capture.containerExecution.repoHostPath = [string]$reuseRepoHostPathResolved
      $capture.containerExecution.repoContainerPath = [string]$ReuseRepoContainerPath
      $capture.containerExecution.resultsHostPath = [string]$reuseResultsHostPathResolved
      $capture.containerExecution.resultsContainerPath = [string]$ReuseResultsContainerPath
    } else {
      $containerBaseVi = if ([string]::IsNullOrWhiteSpace($baseViPath)) {
        ''
      } else {
        Convert-HostFileToContainerPath -HostFilePath $baseViPath -MountMap $mounts -MountIndex $mountRef
      }
      $containerHeadVi = if ([string]::IsNullOrWhiteSpace($headViPath)) {
        ''
      } else {
        Convert-HostFileToContainerPath -HostFilePath $headViPath -MountMap $mounts -MountIndex $mountRef
      }
      $containerReportPath = Convert-HostFileToContainerPath -HostFilePath $resolvedReportPath -MountMap $mounts -MountIndex $mountRef
    }

    $effectiveContainerLabel = if ([string]::IsNullOrWhiteSpace($ContainerNameLabel)) {
      if ($viHistoryEnabled -and -not [string]::IsNullOrWhiteSpace([string]$resolvedRuntimeBootstrap.mode)) {
        [string]$resolvedRuntimeBootstrap.mode
      } else {
        ''
      }
    } else {
      $ContainerNameLabel
    }
    $containerName = if ($useExistingContainer) {
      $ReuseContainerName
    } else {
      New-CompareContainerName -Label $effectiveContainerLabel -HashSeed $reportDirectory
    }
    $containerNameForArtifacts = $containerName
    $containerNameForCleanup = if ($useExistingContainer) { '' } else { $containerName }
    $capture.containerName = $containerName
    $containerReportPathForExport = $containerReportPath
    $reportDirectoryForExport = $reportDirectory
    $containerCommand = New-ContainerCommand
    $containerScriptHostPath = Join-Path $reportDirectory ('linux-compare-entrypoint-{0}.sh' -f $containerName)
    Write-UnixScriptArtifact -Path $containerScriptHostPath -Content $containerCommand
    $containerScriptPath = if ($useExistingContainer) {
      Convert-HostPathToExistingContainerPath -HostPath $containerScriptHostPath -Mappings $existingContainerMappings -Description 'Container entrypoint script'
    } else {
      Convert-HostFileToContainerPath -HostFilePath $containerScriptHostPath -MountMap $mounts -MountIndex $mountRef
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedRuntimeInjectionScriptPath)) {
      $runtimeInjectionScriptContainerPath = if ($useExistingContainer) {
        Convert-HostPathToExistingContainerPath `
          -HostPath $resolvedRuntimeInjectionScriptPath `
          -Mappings $existingContainerMappings `
          -Description 'Runtime injection script'
      } else {
        Convert-HostFileToContainerPath `
          -HostFilePath $resolvedRuntimeInjectionScriptPath `
          -MountMap $mounts `
          -MountIndex $mountRef
      }
      $capture.runtimeInjection.scriptContainerPath = $runtimeInjectionScriptContainerPath
    }

    $dockerArgs = if ($useExistingContainer) {
      @(
        'exec',
        '--workdir', $ReuseRepoContainerPath
      )
    } else {
      @(
        'run',
        '--name', $containerName,
        '--workdir', '/compare'
      )
    }
    if (-not $useExistingContainer) {
      foreach ($entry in ($mounts.GetEnumerator() | Sort-Object Name)) {
        $volumeSpec = '{0}:{1}' -f $entry.Name, $entry.Value
        $dockerArgs += @('-v', $volumeSpec)
      }
      foreach ($runtimeMount in $resolvedRuntimeInjectionMounts) {
        $dockerArgs += @('-v', ('{0}:{1}' -f $runtimeMount.hostPath, $runtimeMount.containerPath))
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($containerBaseVi)) {
      $dockerArgs += @('--env', ("COMPARE_BASE_VI={0}" -f $containerBaseVi))
    }
    if (-not [string]::IsNullOrWhiteSpace($containerHeadVi)) {
      $dockerArgs += @('--env', ("COMPARE_HEAD_VI={0}" -f $containerHeadVi))
    }
    $dockerArgs += @('--env', ("COMPARE_REPORT_PATH={0}" -f $containerReportPath))
    $dockerArgs += @('--env', ("COMPARE_REPORT_TYPE={0}" -f $reportInfo.CliReportType))
    $dockerArgs += @('--env', ("COMPARE_FLAGS_B64={0}" -f $flagsB64))
    $dockerArgs += @('--env', 'LV_RTE_HEADLESS=1')
    $dockerArgs += @('--env', ("COMPARE_PRELAUNCH_ENABLED={0}" -f 1))
    $dockerArgs += @('--env', ("COMPARE_PRELAUNCH_WAIT_SECONDS={0}" -f [Math]::Max(0, $PrelaunchWaitSeconds)))
    $dockerArgs += @('--env', ("COMPARE_STARTUP_RETRY_COUNT={0}" -f [Math]::Max(0, $StartupRetryCount)))
    $dockerArgs += @('--env', ("COMPARE_RETRY_DELAY_SECONDS={0}" -f [Math]::Max(0, $RetryDelaySeconds)))
    $dockerArgs += @('--env', 'COMPARE_OPEN_APP_TIMEOUT=180')
    $dockerArgs += @('--env', 'COMPARE_AFTER_LAUNCH_TIMEOUT=180')
    foreach ($stubVar in @('DOCKER_STUB_RUN_EXIT_CODE', 'DOCKER_STUB_RUN_SLEEP_SECONDS', 'DOCKER_STUB_RUN_STDOUT', 'DOCKER_STUB_RUN_STDERR', 'DOCKER_STUB_CP_REPORT_HTML', 'DOCKER_STUB_CP_FAIL', 'DOCKER_STUB_RUN_WRITE_REPORT', 'DOCKER_STUB_RUN_WRITE_HISTORY_SUITE')) {
      $stubValue = [Environment]::GetEnvironmentVariable($stubVar, 'Process')
      if (-not [string]::IsNullOrWhiteSpace($stubValue)) {
        $dockerArgs += @('--env', ("{0}={1}" -f $stubVar, $stubValue))
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedLabVIEWPath)) {
      $dockerArgs += @('--env', ("COMPARE_LABVIEW_PATH={0}" -f $resolvedLabVIEWPath))
    }
    if ($useExistingContainer) {
      $dockerArgs += @('--env', ("COMPARE_REUSE_REPO_HOST_PATH={0}" -f $capture.containerExecution.repoHostPath))
      $dockerArgs += @('--env', ("COMPARE_REUSE_REPO_CONTAINER_PATH={0}" -f $capture.containerExecution.repoContainerPath))
      $dockerArgs += @('--env', ("COMPARE_REUSE_RESULTS_HOST_PATH={0}" -f $capture.containerExecution.resultsHostPath))
      $dockerArgs += @('--env', ("COMPARE_REUSE_RESULTS_CONTAINER_PATH={0}" -f $capture.containerExecution.resultsContainerPath))
    }
    foreach ($runtimeEnv in $resolvedRuntimeInjectionEnv) {
      $dockerArgs += @('--env', ('{0}={1}' -f $runtimeEnv.name, $runtimeEnv.value))
    }
    if (-not [string]::IsNullOrWhiteSpace($runtimeInjectionScriptContainerPath)) {
      $dockerArgs += @('--env', ("COMPARE_RUNTIME_INJECTION_SCRIPT={0}" -f $runtimeInjectionScriptContainerPath))
    }
    if ($useExistingContainer) {
      $dockerArgs += @(
        $containerName,
        'bash',
        $containerScriptPath
      )
      $capture.command = ('docker exec --workdir {0} {1} bash {2}' -f $ReuseRepoContainerPath, $containerName, $containerScriptPath)
      Write-Host ("[ni-linux-container-compare] mode=docker-exec container={0} image={1} report={2}" -f $containerName, $Image, $resolvedReportPath) -ForegroundColor Cyan
      $runResult = Invoke-DockerExecWithTimeout `
        -DockerArgs $dockerArgs `
        -Seconds $TimeoutSeconds `
        -ContainerName $containerName `
        -HeartbeatSeconds $HeartbeatSeconds
    } else {
      $dockerArgs += @(
        $Image,
        'bash',
        $containerScriptPath
      )
      $capture.command = ('docker run --name {0} ... {1} bash -lc <linux-compare-script>' -f $containerName, $Image)
      Write-Host ("[ni-linux-container-compare] mode=docker-run image={0} report={1}" -f $Image, $resolvedReportPath) -ForegroundColor Cyan
      $runResult = Invoke-DockerRunWithTimeout `
        -DockerArgs $dockerArgs `
        -Seconds $TimeoutSeconds `
        -ContainerName $containerName `
        -HeartbeatSeconds $HeartbeatSeconds
    }
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

    $meta = Parse-MetaLine -StdOut $stdoutContent
    $capture.startupMitigation.retryAttempts = $meta.retryAttempts
    $capture.startupMitigation.retryTriggered = [bool]$meta.retryTriggered
    $capture.startupMitigation.prelaunchAttempted = [bool]$meta.prelaunchAttempted
    $capture.startupMitigation.iniPath = $meta.iniPath
    $capture.startupMitigation.openAppReferenceTimeoutInSecond = $meta.openTimeout
    $capture.startupMitigation.afterLaunchOpenAppReferenceTimeoutInSecond = $meta.afterLaunchTimeout
    $additionalExportPaths = @()

    if ($runResult.TimedOut) {
      $capture.status = 'timeout'
      $capture.timedOut = $true
      $capture.exitCode = $script:TimeoutExitCode
      $capture.message = ("Container compare timed out after {0} second(s)." -f $TimeoutSeconds)
      $finalExitCode = $script:TimeoutExitCode
    } else {
      $exitCode = [int]$runResult.ExitCode
      $capture.exitCode = $exitCode
      switch ($exitCode) {
        0 { $capture.status = 'ok' }
        1 {
          if (Test-LabVIEWCliFailure -StdErr $stderrContent -StdOut $stdoutContent) {
            $capture.status = 'error'
            $capture.message = Resolve-RunFailureMessage -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
          } else {
            $capture.status = 'diff'
          }
        }
        default {
          $capture.status = 'error'
          $capture.message = Resolve-RunFailureMessage -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
        }
      }
      $finalExitCode = $exitCode
    }
  }
} catch {
  $capture.status = 'preflight-error'
  $capture.exitCode = $script:PreflightExitCode
  $capture.message = $_.Exception.Message
  $finalExitCode = $script:PreflightExitCode
} finally {
  if (-not $Probe -and -not [string]::IsNullOrWhiteSpace($containerNameForArtifacts) -and -not [string]::IsNullOrWhiteSpace($reportDirectoryForExport)) {
    $exportResult = Export-ContainerArtifacts `
      -ContainerName $containerNameForArtifacts `
      -ContainerReportPath $containerReportPathForExport `
      -HostReportPath $resolvedReportPath `
      -ReportDirectory $reportDirectoryForExport `
      -AdditionalContainerPaths $additionalExportPaths
    $capture.containerArtifacts = [ordered]@{
      exportDir = [string]$exportResult.exportDir
      copiedPaths = @($exportResult.copiedPaths)
      copyAttempts = @($exportResult.copyAttempts)
      copyStatus = [string]$exportResult.copyStatus
      recoveredCopyCount = [int]$exportResult.recoveredCopyCount
    }
    $capture.reportAnalysis = Get-ReportAnalysis -ExtractedReportPath ([string]$exportResult.reportPathExtracted)
  }

  if (-not [string]::IsNullOrWhiteSpace($containerNameForCleanup)) {
    try { & docker rm -f $containerNameForCleanup *> $null } catch {}
  }
  if (-not [string]::IsNullOrWhiteSpace($containerScriptHostPath) -and (Test-Path -LiteralPath $containerScriptHostPath -PathType Leaf)) {
    Remove-Item -LiteralPath $containerScriptHostPath -Force -ErrorAction SilentlyContinue
  }

  $runtimeStatusForClassification = ''
  $runtimeReasonForClassification = ''
  if ($capture.runtimeDeterminism) {
    if ($capture.runtimeDeterminism.PSObject.Properties['status']) {
      $runtimeStatusForClassification = [string]$capture.runtimeDeterminism.status
    }
    if ($capture.runtimeDeterminism.PSObject.Properties['reason']) {
      $runtimeReasonForClassification = [string]$capture.runtimeDeterminism.reason
    }
  }
  $effectiveExitCode = if ($null -eq $capture.exitCode) { [int]$finalExitCode } else { [int]$capture.exitCode }
  $classification = Get-CompareExitClassification `
    -ExitCode $effectiveExitCode `
    -CaptureStatus ([string]$capture.status) `
    -StdOut $stdoutContent `
    -StdErr $stderrContent `
    -Message ([string]$capture.message) `
    -RuntimeDeterminismStatus $runtimeStatusForClassification `
    -RuntimeDeterminismReason $runtimeReasonForClassification `
    -TimedOut:([bool]$capture.timedOut)

  $hasHtmlDiffEvidence = $false
  $reportAnalysis = $null
  if ($capture -is [System.Collections.IDictionary]) {
    if ($capture.Contains('reportAnalysis')) {
      $reportAnalysis = $capture['reportAnalysis']
    }
  } elseif ($capture.PSObject.Properties['reportAnalysis']) {
    $reportAnalysis = $capture.reportAnalysis
  }
  if ($reportAnalysis) {
    if ($reportAnalysis -is [System.Collections.IDictionary]) {
      if ($reportAnalysis.Contains('hasDiffEvidence')) {
        $hasHtmlDiffEvidence = [bool]$reportAnalysis['hasDiffEvidence']
      }
    } elseif ($reportAnalysis.PSObject.Properties['hasDiffEvidence']) {
      $hasHtmlDiffEvidence = [bool]$reportAnalysis.hasDiffEvidence
    }
  }
  if (
    $hasHtmlDiffEvidence -and
    (
      [string]::IsNullOrWhiteSpace([string]$classification.failureClass) -or
      [string]::Equals([string]$classification.failureClass, 'none', [System.StringComparison]::OrdinalIgnoreCase)
    )
  ) {
    $capture.status = 'diff'
    $classification = [pscustomobject]@{
      resultClass = 'success-diff'
      isDiff = $true
      gateOutcome = 'pass'
      failureClass = 'none'
    }
    $capture.diffEvidenceSource = 'html'
  } elseif ([bool]$classification.isDiff) {
    $capture.diffEvidenceSource = 'exit-code'
  } else {
    $capture.diffEvidenceSource = 'fallback'
  }

  $capture.resultClass = [string]$classification.resultClass
  $capture.isDiff = [bool]$classification.isDiff
  $capture.gateOutcome = [string]$classification.gateOutcome
  $capture.failureClass = [string]$classification.failureClass

  if (-not $Probe) {
    if ($stdoutPath) { Write-TextArtifact -Path $stdoutPath -Content $stdoutContent }
    if ($stderrPath) { Write-TextArtifact -Path $stderrPath -Content $stderrContent }
    if ($capturePath) {
      $capture.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      $capture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $capturePath -Encoding utf8
      Write-Host ("[ni-linux-container-compare] capture={0} status={1} exit={2}" -f $capturePath, $capture.status, $capture.exitCode) -ForegroundColor DarkGray
    }
  }
}

if ($PassThru) {
  [pscustomobject]$capture
}

if ($finalExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($capture.message)) {
  Write-Host ("[ni-linux-container-compare] {0}" -f $capture.message) -ForegroundColor Red
}

exit $finalExitCode
