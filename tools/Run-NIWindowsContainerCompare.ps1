#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a LabVIEW CLI compare inside a local NI Windows container image.

.DESCRIPTION
  Preflights Docker mode/image availability and then executes
  CreateComparisonReport inside `nationalinstruments/labview:2026q1-windows`
  (or a caller-supplied image). The helper writes deterministic capture
  artifacts adjacent to the report output.

.PARAMETER BaseVi
  Path to the base VI. Required unless -Probe is set.

.PARAMETER HeadVi
  Path to the head VI. Required unless -Probe is set.

.PARAMETER Image
  Docker image tag to execute. Defaults to
  nationalinstruments/labview:2026q1-windows.

.PARAMETER ReportPath
  Optional report path on host. Defaults to
  tests/results/ni-windows-container/compare-report.<ext>.

.PARAMETER ReportType
  Host-facing report type selector: html, xml, or text.

.PARAMETER TimeoutSeconds
  Timeout for docker run execution. Defaults to 600.

.PARAMETER Flags
  Additional CLI flags appended to CreateComparisonReport.

.PARAMETER LabVIEWPath
  Required for compare mode (non-probe). Explicit in-container LabVIEW.exe path
  forwarded to the container as COMPARE_LABVIEW_PATH.

.PARAMETER Probe
  Preflight only (Docker availability, Windows container mode, and image
  presence). Does not require BaseVi/HeadVi.

.PARAMETER PassThru
  Emit the capture object to stdout in addition to writing capture JSON.
#>
[CmdletBinding()]
param(
  [string]$BaseVi,
  [string]$HeadVi,
  [string]$Image = 'nationalinstruments/labview:2026q1-windows',
  [string]$ReportPath,
  [ValidateSet('html','xml','text')]
  [string]$ReportType = 'html',
  [int]$TimeoutSeconds = 600,
  [int]$HeartbeatSeconds = 15,
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [bool]$AutoRepairRuntime = $true,
  [bool]$ManageDockerEngine = $true,
  [bool]$AllowHostEngineMutation = $false,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [int]$StartupRetryCount = 1,
  [int]$PrelaunchWaitSeconds = 8,
  [int]$RetryDelaySeconds = 8,
  [switch]$Probe,
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

  $commands = @(Get-Command -Name 'docker' -All -ErrorAction SilentlyContinue)
  if ($commands.Count -gt 0) {
    $sourceCandidates = @()
    foreach ($command in $commands) {
      if ([string]::IsNullOrWhiteSpace([string]$command.Source)) { continue }
      $source = [string]$command.Source
      if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
      $sourceCandidates += $source
    }
    if ($sourceCandidates.Count -gt 0) {
      $exe = @($sourceCandidates | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetExtension($_), '.exe') } | Select-Object -First 1)
      if ($exe.Count -gt 0) { return [System.IO.Path]::GetFullPath($exe[0]) }
      $ps1 = @($sourceCandidates | Where-Object { [System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetExtension($_), '.ps1') } | Select-Object -First 1)
      if ($ps1.Count -gt 0) { return [System.IO.Path]::GetFullPath($ps1[0]) }
      return [System.IO.Path]::GetFullPath($sourceCandidates[0])
    }
  }

  $pathSeparator = [System.IO.Path]::PathSeparator
  $pathEntries = @($env:PATH -split [regex]::Escape([string]$pathSeparator))
  $candidates = @('docker.exe', 'docker.ps1', 'docker.cmd', 'docker.bat', 'docker')
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

function Resolve-EnvTokenValue {
  param(
    [Parameter(Mandatory)][string]$Name
  )

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
    $defaultRoot = Join-Path (Resolve-Path '.').Path 'tests/results/ni-windows-container'
    return (Join-Path $defaultRoot ("compare-report.{0}" -f $Extension))
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path '.').Path $PathValue))
}

function Get-DockerServerOsType {
  $output = & docker info --format '{{.OSType}}' 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
    throw 'Unable to query Docker daemon mode. Ensure Docker Desktop is running.'
  }
  return $output.Trim().ToLowerInvariant()
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
    $Map[$HostDirectory] = ('C:\compare\m{0}' -f $Index.Value)
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
  return (Join-Path $containerDir (Split-Path -Leaf $HostFilePath))
}

function New-ContainerCommand {
  return @'
$ErrorActionPreference = "Stop"
$cliCandidates = @(
  "C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe",
  "C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe"
)
$cliPath = $cliCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $cliPath) {
  throw "LabVIEWCLI.exe not found in container. Ensure the NI image includes the LabVIEW CLI component."
}
function Set-IniToken {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Key,
    [Parameter(Mandatory)][string]$Value
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
  if ($null -eq $content) { $content = '' }
  if ($content -match ("(?m)^\s*{0}\s*=" -f [regex]::Escape($Key))) {
    $updated = [regex]::Replace($content, ("(?m)^\s*{0}\s*=.*$" -f [regex]::Escape($Key)), ("{0}={1}" -f $Key, $Value))
  } else {
    $updated = ($content.TrimEnd() + [Environment]::NewLine + ("{0}={1}" -f $Key, $Value) + [Environment]::NewLine)
  }
  Set-Content -LiteralPath $Path -Value $updated -Encoding utf8
}
$meta = [ordered]@{
  retryAttempts = 0
  retryTriggered = $false
  prelaunchAttempted = $false
  iniPath = ''
  openTimeout = 180
  afterLaunchTimeout = 180
}
$openTimeout = 180
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_OPEN_APP_TIMEOUT)) {
  [void][int]::TryParse($env:COMPARE_OPEN_APP_TIMEOUT, [ref]$openTimeout)
}
$afterLaunchTimeout = 180
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_AFTER_LAUNCH_TIMEOUT)) {
  [void][int]::TryParse($env:COMPARE_AFTER_LAUNCH_TIMEOUT, [ref]$afterLaunchTimeout)
}
$meta.openTimeout = $openTimeout
$meta.afterLaunchTimeout = $afterLaunchTimeout
$cliIniCandidates = @(
  "C:\ProgramData\National Instruments\LabVIEW CLI\LabVIEWCLI.ini",
  "C:\ProgramData\National Instruments\LabVIEWCLI\LabVIEWCLI.ini",
  "C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini",
  "C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.ini"
)
$cliIni = $cliIniCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($cliIni) {
  Set-IniToken -Path $cliIni -Key 'OpenAppReferenceTimeoutInSecond' -Value ([string]$openTimeout)
  Set-IniToken -Path $cliIni -Key 'AfterLaunchOpenAppReferenceTimeoutInSecond' -Value ([string]$afterLaunchTimeout)
  $meta.iniPath = $cliIni
}
$args = @(
  "-OperationName", "CreateComparisonReport",
  "-VI1", $env:COMPARE_BASE_VI,
  "-VI2", $env:COMPARE_HEAD_VI,
  "-ReportPath", $env:COMPARE_REPORT_PATH,
  "-ReportType", $env:COMPARE_REPORT_TYPE,
  "-Headless"
)
$flags = @()
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_FLAGS_B64)) {
  $rawBytes = [System.Convert]::FromBase64String($env:COMPARE_FLAGS_B64)
  $rawJson = [System.Text.Encoding]::UTF8.GetString($rawBytes)
  if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
    $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    if ($parsed -is [System.Collections.IEnumerable] -and -not ($parsed -is [string])) {
      foreach ($flag in $parsed) {
        if (-not [string]::IsNullOrWhiteSpace([string]$flag)) {
          $flags += [string]$flag
        }
      }
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$parsed)) {
      $flags += [string]$parsed
    }
  }
}
if ($flags.Count -gt 0) {
  $args += $flags
}
$prelaunchEnabled = -not [string]::Equals($env:COMPARE_PRELAUNCH_ENABLED, '0', [System.StringComparison]::OrdinalIgnoreCase)
if ($prelaunchEnabled) {
  $lvCandidates = @(
    $env:COMPARE_LABVIEW_PATH,
    "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe",
    "C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe"
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
  $lvPath = $lvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($lvPath) {
    $meta.prelaunchAttempted = $true
    Start-Process -FilePath $lvPath -ArgumentList '--headless' -WindowStyle Hidden | Out-Null
    $prelaunchWait = 8
    if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_PRELAUNCH_WAIT_SECONDS)) {
      [void][int]::TryParse($env:COMPARE_PRELAUNCH_WAIT_SECONDS, [ref]$prelaunchWait)
    }
    if ($prelaunchWait -gt 0) {
      Start-Sleep -Seconds $prelaunchWait
    }
  }
}
$startupRetries = 1
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_STARTUP_RETRY_COUNT)) {
  [void][int]::TryParse($env:COMPARE_STARTUP_RETRY_COUNT, [ref]$startupRetries)
}
if ($startupRetries -lt 0) { $startupRetries = 0 }
$retryDelay = 8
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_RETRY_DELAY_SECONDS)) {
  [void][int]::TryParse($env:COMPARE_RETRY_DELAY_SECONDS, [ref]$retryDelay)
}
if ($retryDelay -lt 0) { $retryDelay = 0 }
$maxAttempts = [Math]::Max(1, $startupRetries + 1)
$attempt = 0
$lastExit = 1

function Invoke-CliWithCapturedStreams {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$ArgumentList
  )

  $stdoutPath = Join-Path $env:TEMP ("lvcli-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrPath = Join-Path $env:TEMP ("lvcli-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  try {
    $proc = Start-Process -FilePath $FilePath `
      -ArgumentList $ArgumentList `
      -NoNewWindow `
      -Wait `
      -PassThru `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath
    $stdoutText = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    $stderrText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
    $combinedText = ((@($stdoutText, $stderrText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine)
    return [pscustomobject]@{
      ExitCode = [int]$proc.ExitCode
      Output = $combinedText
    }
  } finally {
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

while ($attempt -lt $maxAttempts) {
  $attempt++
  $meta.retryAttempts = $attempt
  $cliRun = Invoke-CliWithCapturedStreams -FilePath $cliPath -ArgumentList $args
  $lastExit = [int]$cliRun.ExitCode
  $output = $cliRun.Output
  if (-not [string]::IsNullOrWhiteSpace($output)) {
    $output -split "`r?`n" | ForEach-Object {
      if (-not [string]::IsNullOrWhiteSpace($_)) {
        Write-Output $_
      }
    }
  }
  if ($lastExit -eq 0) { break }
  $text = if ([string]::IsNullOrWhiteSpace($output)) { '' } else { [string]$output }
  $isCliFailure = ($text -match 'Error code\s*:' -or $text -match 'An error occurred while running the LabVIEW CLI')
  $isStartupConnectivity = (
    $lastExit -in @(-350000, -350051) -or
    $text -match '-350000' -or
    $text -match '-350051' -or
    $text -match '(?i)Preparing modules for first use'
  )
  if ($isStartupConnectivity -and $attempt -lt $maxAttempts) {
    $meta.retryTriggered = $true
    if ($retryDelay -gt 0) {
      Start-Sleep -Seconds $retryDelay
    }
    continue
  }
  if ($lastExit -eq 1 -and -not $isCliFailure) { break }
  break
}
Write-Output ("[ni-container-meta]retryAttempts={0};retryTriggered={1};prelaunchAttempted={2};iniPath={3};openTimeout={4};afterLaunchTimeout={5}" -f $meta.retryAttempts, ($(if ($meta.retryTriggered) { 1 } else { 0 })), ($(if ($meta.prelaunchAttempted) { 1 } else { 0 })), $meta.iniPath, $meta.openTimeout, $meta.afterLaunchTimeout)
exit $lastExit
'@
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
    # Container execution is non-interactive; force headless CLI mode by default.
    $flags += '-Headless'
  }

  return @($flags)
}

function Convert-ToEncodedCommand {
  param(
    [Parameter(Mandatory)][string]$CommandText
  )
  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
}

function Invoke-DockerRunWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$ContainerName,
    [int]$HeartbeatSeconds = 15
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-windows-container-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-windows-container-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $dockerCommandSource = Resolve-DockerCommandSource
    $startFilePath = $dockerCommandSource
    $startArgs = @($DockerArgs)
    $dockerSourceExt = [System.IO.Path]::GetExtension($dockerCommandSource)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($dockerSourceExt, '.ps1')) {
      $pwshExe = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
      $startFilePath = $pwshExe
      $quotedDockerArgs = @(
        foreach ($arg in @($DockerArgs)) {
          $text = [string]$arg
          if ($text -match '\s') {
            '"{0}"' -f ($text -replace '"', '\"')
          } else {
            $text
          }
        }
      )
      $startArgs = @('-NoLogo', '-NoProfile', '-File', $dockerCommandSource) + $quotedDockerArgs
    }

    $process = Start-Process -FilePath $startFilePath `
      -ArgumentList $startArgs `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru

    $timeoutSeconds = [Math]::Max(1, $Seconds)
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $pollMs = 500
    $heartbeatWindow = [Math]::Max(5, $HeartbeatSeconds)
    $lastHeartbeat = Get-Date
    while (-not $process.HasExited) {
      if ((Get-Date) -ge $deadline) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        $stdout = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
        return [pscustomobject]@{
          TimedOut = $true
          ExitCode = $script:TimeoutExitCode
          StdOut   = $stdout
          StdErr   = $stderr
        }
      }
      $elapsedSeconds = [math]::Round(((Get-Date) - $process.StartTime).TotalSeconds, 1)
      if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $heartbeatWindow) {
        Write-Host ("[ni-container-compare] running container={0} elapsed={1}s timeout={2}s" -f $ContainerName, $elapsedSeconds, $timeoutSeconds) -ForegroundColor DarkGray
        $lastHeartbeat = Get-Date
      }
      Start-Sleep -Milliseconds $pollMs
    }
    if (-not $process.HasExited) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      $stdout = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
      $stderr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
      return [pscustomobject]@{
        TimedOut = $true
        ExitCode = $script:TimeoutExitCode
        StdOut   = $stdout
        StdErr   = $stderr
      }
    }

    $stdout = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut   = $stdout
      StdErr   = $stderr
    }
  } finally {
    if ($process) {
      try { $process.Dispose() } catch {}
    }
    Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
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

function Test-ReportOverwriteFailure {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut
  )

  $combined = @($StdErr, $StdOut) -join "`n"
  if ([string]::IsNullOrWhiteSpace($combined)) {
    return $false
  }
  return (
    $combined -match 'Report path already exists' -or
    $combined -match 'Use\s+-o\s+to overwrite existing report'
  )
}

function Resolve-RunFailureMessage {
  param(
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut,
    [Parameter(Mandatory)][int]$ExitCode
  )

  foreach ($candidate in @($StdErr, $StdOut)) {
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

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

function Resolve-RunFailureClassification {
  param(
    [Parameter(Mandatory)][string]$Image,
    [AllowNull()][string]$StdErr,
    [AllowNull()][string]$StdOut,
    [Parameter(Mandatory)][int]$ExitCode
  )

  $combined = @($StdErr, $StdOut) -join "`n"
  $message = Resolve-RunFailureMessage -StdErr $StdErr -StdOut $StdOut -ExitCode $ExitCode

  $labviewCliErrorCode = $null
  if (-not [string]::IsNullOrWhiteSpace($combined)) {
    $codeMatch = [regex]::Match($combined, 'Error code\s*:\s*(-?\d+)')
    if ($codeMatch.Success) {
      $parsedCode = 0
      if ([int]::TryParse($codeMatch.Groups[1].Value, [ref]$parsedCode)) {
        $labviewCliErrorCode = $parsedCode
      }
    }
  }

  $isStartupConnectivity = Test-CompareStartupConnectivitySignature -StdOut $StdOut -StdErr $StdErr -Message $message
  $recommendation = if ($isStartupConnectivity) {
    'LabVIEW CLI startup/connectivity failure detected. Retry after prelaunch and verify LabVIEWCLI.ini timeout settings.'
  } else {
    ('Inspect stdout/stderr artifacts and runtime logs for the failed compare in image {0}.' -f $Image)
  }

  return [pscustomobject]@{
    status = 'error'
    classification = 'run-error'
    message = $message
    labviewCliErrorCode = $labviewCliErrorCode
    recommendation = $recommendation
  }
}

function Parse-ContainerMeta {
  param([AllowNull()][string]$StdOut)

  $meta = [ordered]@{
    retryAttempts = 0
    retryTriggered = $false
    prelaunchAttempted = $false
    iniPath = ''
    openTimeout = 180
    afterLaunchTimeout = 180
  }
  if ([string]::IsNullOrWhiteSpace($StdOut)) { return $meta }
  $line = ($StdOut -split "`r?`n" | Where-Object { $_ -match '^\[ni-container-meta\]' } | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($line)) { return $meta }
  $payload = $line -replace '^\[ni-container-meta\]', ''
  foreach ($entry in ($payload -split ';')) {
    if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '=') { continue }
    $parts = $entry -split '=', 2
    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    switch ($key) {
      'retryAttempts' { [void][int]::TryParse($value, [ref]$meta.retryAttempts) }
      'retryTriggered' { $meta.retryTriggered = [string]::Equals($value, '1', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($value, 'true', [System.StringComparison]::OrdinalIgnoreCase) }
      'prelaunchAttempted' { $meta.prelaunchAttempted = [string]::Equals($value, '1', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($value, 'true', [System.StringComparison]::OrdinalIgnoreCase) }
      'iniPath' { $meta.iniPath = $value }
      'openTimeout' { [void][int]::TryParse($value, [ref]$meta.openTimeout) }
      'afterLaunchTimeout' { [void][int]::TryParse($value, [ref]$meta.afterLaunchTimeout) }
    }
  }
  return $meta
}

function Export-ContainerArtifacts {
  param(
    [Parameter(Mandatory)][string]$ContainerName,
    [AllowNull()][string]$ContainerReportPath,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [AllowEmptyCollection()][string[]]$AdditionalContainerPaths = @()
  )

  $exportDir = Join-Path $ReportDirectory 'container-export'
  if (-not (Test-Path -LiteralPath $exportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
  }

  $copiedPaths = New-Object System.Collections.Generic.List[string]
  $attemptCount = 0
  $successCount = 0
  $reportPathExtracted = ''

  if (-not [string]::IsNullOrWhiteSpace($ContainerReportPath)) {
    $attemptCount++
    $reportLeaf = Split-Path -Leaf $ContainerReportPath
    if ([string]::IsNullOrWhiteSpace($reportLeaf)) {
      $reportLeaf = 'windows-compare-report.html'
    }
    $reportPathExtracted = Join-Path $exportDir $reportLeaf
    $sourceSpec = '{0}:{1}' -f $ContainerName, $ContainerReportPath
    & docker cp $sourceSpec $reportPathExtracted *> $null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $reportPathExtracted -PathType Leaf)) {
      $successCount++
      $copiedPaths.Add($reportPathExtracted) | Out-Null
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
    $sourceSpec = '{0}:{1}' -f $ContainerName, $containerPath
    & docker cp $sourceSpec $destinationPath *> $null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $destinationPath -PathType Leaf -ErrorAction SilentlyContinue)) {
      $successCount++
      $copiedPaths.Add($destinationPath) | Out-Null
    }
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
    copyStatus = $copyStatus
    reportPathExtracted = $reportPathExtracted
  }
}

function Get-ReportAnalysis {
  param(
    [AllowNull()][string]$ExtractedReportPath
  )

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
    $analysis.diffMarkerCount = [regex]::Matches($html, '(summary\.difference-heading|<summary[^>]+class\s*=\s*["''][^"'']*difference-heading)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
    $analysis.diffDetailCount = [regex]::Matches($html, '(li\.diff-detail(?:-cosmetic)?|<li[^>]+class\s*=\s*["''][^"'']*diff-detail(?:-cosmetic)?)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
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

$capture = [ordered]@{
  schema        = 'ni-windows-container-compare/v1'
  generatedAt   = (Get-Date).ToUniversalTime().ToString('o')
  image         = $Image
  reportType    = $ReportType
  timeoutSeconds= $TimeoutSeconds
  probe         = [bool]$Probe
  status        = 'init'
  classification= 'init'
  exitCode      = $null
  timedOut      = $false
  dockerServerOs= $null
  dockerContext = $null
  baseVi        = $null
  headVi        = $null
  reportPath    = $null
  labviewPath   = $null
  flags         = @()
  command       = $null
  stdoutPath    = $null
  stderrPath    = $null
  runtimeDeterminism = $null
  headlessContract = [ordered]@{
    required = $true
    enforcedCliHeadless = $true
    lvRteHeadlessEnv = $true
    linuxRequiresHeadlessEveryInvocation = $false
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
    copyStatus = 'not-attempted'
  }
  diffEvidenceSource = 'fallback'
  resultClass   = 'failure-preflight'
  isDiff        = $false
  gateOutcome   = 'fail'
  failureClass  = 'preflight'
  message       = $null
}

$finalExitCode = 0
$stdoutContent = ''
$stderrContent = ''
$capturePath = $null
$stdoutPath = $null
$stderrPath = $null
$containerNameForCleanup = ''
$containerReportPathForExport = ''
$reportDirectoryForExport = ''
$additionalExportPaths = @()
$previousCompareLabVIEWPath = $null
$restoreCompareLabVIEWPath = $false

try {
  Assert-Tool -Name 'docker'

  $runtimeGuardPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Assert-DockerRuntimeDeterminism.ps1'
  if (-not (Test-Path -LiteralPath $runtimeGuardPath -PathType Leaf)) {
    throw ("Runtime guard script not found: {0}" -f $runtimeGuardPath)
  }
  $runtimeSnapshot = if ([string]::IsNullOrWhiteSpace($RuntimeSnapshotPath)) {
    $defaultRoot = Join-Path (Resolve-Path '.').Path 'tests/results/ni-windows-container'
    Join-Path $defaultRoot 'runtime-determinism.json'
  } else {
    if ([System.IO.Path]::IsPathRooted($RuntimeSnapshotPath)) {
      [System.IO.Path]::GetFullPath($RuntimeSnapshotPath)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path '.').Path $RuntimeSnapshotPath))
    }
  }

  & pwsh -NoLogo -NoProfile -File $runtimeGuardPath `
    -ExpectedOsType windows `
    -ExpectedContext 'desktop-windows' `
    -AutoRepair:$AutoRepairRuntime `
    -ManageDockerEngine:$ManageDockerEngine `
    -AllowHostEngineMutation:$AllowHostEngineMutation `
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
  if (-not (Test-DockerImageExists -Tag $Image)) {
    throw ("Docker image '{0}' not found locally. Pull it first: docker pull {0}" -f $Image)
  }

  if ($Probe) {
    $capture.status = 'probe-ok'
    $capture.classification = 'probe-ok'
    $capture.exitCode = 0
    $capture.message = ("Docker is in windows mode and image '{0}' is available." -f $Image)
    Write-Host ("[ni-container-probe] {0}" -f $capture.message) -ForegroundColor Green
  } else {
    $baseViPath = Resolve-ExistingFilePath -InputPath $BaseVi -ParameterName 'BaseVi'
    $headViPath = Resolve-ExistingFilePath -InputPath $HeadVi -ParameterName 'HeadVi'
    $reportInfo = Resolve-ReportTypeInfo -Type $ReportType
    $resolvedReportPath = Resolve-OutputReportPath -PathValue $ReportPath -Extension $reportInfo.Extension
    $reportDirectory = Split-Path -Parent $resolvedReportPath
    if (-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $resolvedReportPath -PathType Leaf) {
      Remove-Item -LiteralPath $resolvedReportPath -Force -ErrorAction SilentlyContinue
    }

    $capturePath = Join-Path $reportDirectory 'ni-windows-container-capture.json'
    $stdoutPath = Join-Path $reportDirectory 'ni-windows-container-stdout.txt'
    $stderrPath = Join-Path $reportDirectory 'ni-windows-container-stderr.txt'

    $resolvedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      if ([string]::IsNullOrWhiteSpace($env:NI_WINDOWS_LABVIEW_PATH)) { '' } else { $env:NI_WINDOWS_LABVIEW_PATH.Trim() }
    } else {
      $LabVIEWPath.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($resolvedLabVIEWPath)) {
      throw '-LabVIEWPath is required for NI Windows container compare to guarantee in-container LabVIEW resolution.'
    }

    $capture.baseVi = $baseViPath
    $capture.headVi = $headViPath
    $capture.reportPath = $resolvedReportPath
    $capture.labviewPath = $resolvedLabVIEWPath
    $capture.stdoutPath = $stdoutPath
    $capture.stderrPath = $stderrPath

    $flagsPayload = Get-EffectiveCompareFlags -InputFlags $Flags
    $capture.flags = @($flagsPayload)
    $flagsJson = $flagsPayload | ConvertTo-Json -Compress
    if ([string]::IsNullOrWhiteSpace($flagsJson)) {
      $flagsJson = '[]'
    }
    $flagsB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($flagsJson))

    $mounts = @{}
    $mountIndex = 0
    $mountRef = [ref]$mountIndex
    $containerBaseVi = Convert-HostFileToContainerPath -HostFilePath $baseViPath -MountMap $mounts -MountIndex $mountRef
    $containerHeadVi = Convert-HostFileToContainerPath -HostFilePath $headViPath -MountMap $mounts -MountIndex $mountRef
    $containerReportPath = Convert-HostFileToContainerPath -HostFilePath $resolvedReportPath -MountMap $mounts -MountIndex $mountRef

    $containerName = 'ni-compare-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $containerNameForCleanup = $containerName
    $containerReportPathForExport = $containerReportPath
    $reportDirectoryForExport = $reportDirectory
    $containerCommand = New-ContainerCommand
    $encodedContainerCommand = Convert-ToEncodedCommand -CommandText $containerCommand

    $dockerArgs = @(
      'run',
      '--name', $containerName,
      '--workdir', 'C:\compare'
    )
    foreach ($entry in ($mounts.GetEnumerator() | Sort-Object Name)) {
      $volumeSpec = '{0}:{1}' -f $entry.Name, $entry.Value
      $dockerArgs += @('-v', $volumeSpec)
    }
    $dockerArgs += @('--env', ("COMPARE_BASE_VI={0}" -f $containerBaseVi))
    $dockerArgs += @('--env', ("COMPARE_HEAD_VI={0}" -f $containerHeadVi))
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
    foreach ($stubVar in @('DOCKER_STUB_RUN_EXIT_CODE', 'DOCKER_STUB_RUN_SLEEP_SECONDS', 'DOCKER_STUB_RUN_STDOUT', 'DOCKER_STUB_RUN_STDERR', 'DOCKER_STUB_CP_REPORT_HTML', 'DOCKER_STUB_CP_FAIL')) {
      $stubValue = [Environment]::GetEnvironmentVariable($stubVar, 'Process')
      if (-not [string]::IsNullOrWhiteSpace($stubValue)) {
        $dockerArgs += @('--env', ("{0}={1}" -f $stubVar, $stubValue))
      }
    }
    # Avoid passing space-heavy path values inline to docker wrappers (.cmd/.ps1).
    # Export in process env and forward by key only.
    $previousCompareLabVIEWPath = [Environment]::GetEnvironmentVariable('COMPARE_LABVIEW_PATH', 'Process')
    [Environment]::SetEnvironmentVariable('COMPARE_LABVIEW_PATH', $resolvedLabVIEWPath, 'Process')
    $restoreCompareLabVIEWPath = $true
    $dockerArgs += @('--env', 'COMPARE_LABVIEW_PATH')
    $dockerArgs += @(
      $Image,
      'powershell',
      '-NoLogo',
      '-NoProfile',
      '-EncodedCommand',
      $encodedContainerCommand
    )

    $capture.command = ('docker run --name {0} ... {1} powershell -NoLogo -NoProfile -EncodedCommand <base64-compare-script>' -f $containerName, $Image)
    Write-Host ("[ni-container-compare] image={0} report={1}" -f $Image, $resolvedReportPath) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout `
      -DockerArgs $dockerArgs `
      -Seconds $TimeoutSeconds `
      -ContainerName $containerName `
      -HeartbeatSeconds $HeartbeatSeconds
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

    $meta = Parse-ContainerMeta -StdOut $stdoutContent
    $capture.startupMitigation.retryAttempts = $meta.retryAttempts
    $capture.startupMitigation.retryTriggered = [bool]$meta.retryTriggered
    $capture.startupMitigation.prelaunchAttempted = [bool]$meta.prelaunchAttempted
    $capture.startupMitigation.iniPath = $meta.iniPath
    $capture.startupMitigation.openAppReferenceTimeoutInSecond = $meta.openTimeout
    $capture.startupMitigation.afterLaunchOpenAppReferenceTimeoutInSecond = $meta.afterLaunchTimeout
    $additionalExportPaths = @()

    if ($runResult.TimedOut) {
      $capture.status = 'timeout'
      $capture.classification = 'timeout'
      $capture.timedOut = $true
      $capture.exitCode = $script:TimeoutExitCode
      $capture.message = ("Container compare timed out after {0} second(s)." -f $TimeoutSeconds)
      $finalExitCode = $script:TimeoutExitCode
    } else {
      $exitCode = [int]$runResult.ExitCode
      $capture.exitCode = $exitCode
      switch ($exitCode) {
        0 {
          $capture.status = 'ok'
          $capture.classification = 'ok'
        }
        1 {
          if (Test-LabVIEWCliFailure -StdErr $stderrContent -StdOut $stdoutContent) {
            $failure = Resolve-RunFailureClassification -Image $Image -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
            $capture.status = $failure.status
            $capture.classification = $failure.classification
            $capture.message = $failure.message
            $capture.labviewCliErrorCode = $failure.labviewCliErrorCode
            $capture.recommendation = $failure.recommendation
          } elseif (Test-ReportOverwriteFailure -StdErr $stderrContent -StdOut $stdoutContent) {
            $capture.status = 'error'
            $capture.classification = 'run-error'
            $capture.message = Resolve-RunFailureMessage -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
          } else {
            $capture.status = 'diff'
            $capture.classification = 'diff'
          }
        }
        default {
          $failure = Resolve-RunFailureClassification -Image $Image -StdErr $stderrContent -StdOut $stdoutContent -ExitCode $exitCode
          $capture.status = $failure.status
          $capture.classification = $failure.classification
          $capture.message = $failure.message
          $capture.labviewCliErrorCode = $failure.labviewCliErrorCode
          $capture.recommendation = $failure.recommendation
        }
      }
      $finalExitCode = $exitCode
    }
  }
} catch {
  $capture.status = 'preflight-error'
  $capture.classification = 'preflight-error'
  $capture.exitCode = $script:PreflightExitCode
  $capture.message = $_.Exception.Message
  $finalExitCode = $script:PreflightExitCode
} finally {
  if (-not $Probe -and -not [string]::IsNullOrWhiteSpace($containerNameForCleanup) -and -not [string]::IsNullOrWhiteSpace($reportDirectoryForExport)) {
    $exportResult = Export-ContainerArtifacts `
      -ContainerName $containerNameForCleanup `
      -ContainerReportPath $containerReportPathForExport `
      -ReportDirectory $reportDirectoryForExport `
      -AdditionalContainerPaths $additionalExportPaths
    $capture.containerArtifacts = [ordered]@{
      exportDir = [string]$exportResult.exportDir
      copiedPaths = @($exportResult.copiedPaths)
      copyStatus = [string]$exportResult.copyStatus
    }
    $capture.reportAnalysis = Get-ReportAnalysis -ExtractedReportPath ([string]$exportResult.reportPathExtracted)
  }

  if (-not [string]::IsNullOrWhiteSpace($containerNameForCleanup)) {
    try { & docker rm -f $containerNameForCleanup *> $null } catch {}
  }

  if ($restoreCompareLabVIEWPath) {
    [Environment]::SetEnvironmentVariable('COMPARE_LABVIEW_PATH', $previousCompareLabVIEWPath, 'Process')
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
  if ($null -ne $capture.reportAnalysis) {
    if ($capture.reportAnalysis -is [System.Collections.IDictionary] -and $capture.reportAnalysis.Contains('hasDiffEvidence')) {
      $hasHtmlDiffEvidence = [bool]$capture.reportAnalysis['hasDiffEvidence']
    } elseif ($capture.reportAnalysis.PSObject.Properties['hasDiffEvidence']) {
      $hasHtmlDiffEvidence = [bool]$capture.reportAnalysis.hasDiffEvidence
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
      Write-Host ("[ni-container-compare] capture={0} status={1} exit={2}" -f $capturePath, $capture.status, $capture.exitCode) -ForegroundColor DarkGray
    }
  }
}

if ($PassThru) {
  [pscustomobject]$capture
}

if ($finalExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($capture.message)) {
  Write-Host ("[ni-container-compare] {0}" -f $capture.message) -ForegroundColor Red
}

exit $finalExitCode
