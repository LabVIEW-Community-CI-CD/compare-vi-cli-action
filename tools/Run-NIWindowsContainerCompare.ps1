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
  Optional explicit in-container LabVIEW.exe path forwarded as -LabVIEWPath.

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
  [string[]]$Flags,
  [string]$LabVIEWPath,
  [switch]$Probe,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PreflightExitCode = 2
$script:TimeoutExitCode = 124

function Assert-Tool {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
    throw ("Required tool not found on PATH: {0}" -f $Name)
  }
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
        CliReportType = 'HTMLSingleFile'
        Extension     = 'html'
      }
    }
    'xml' {
      return [pscustomobject]@{
        InputType     = 'xml'
        CliReportType = 'XML'
        Extension     = 'xml'
      }
    }
    'text' {
      return [pscustomobject]@{
        InputType     = 'text'
        CliReportType = 'Text'
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
$args = @(
  "-OperationName", "CreateComparisonReport",
  "-VI1", $env:COMPARE_BASE_VI,
  "-VI2", $env:COMPARE_HEAD_VI,
  "-ReportPath", $env:COMPARE_REPORT_PATH,
  "-ReportType", $env:COMPARE_REPORT_TYPE
)
if (-not [string]::IsNullOrWhiteSpace($env:COMPARE_LABVIEW_PATH)) {
  $args += @("-LabVIEWPath", $env:COMPARE_LABVIEW_PATH)
}
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
& $cliPath @args
exit $LASTEXITCODE
'@
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
    [Parameter(Mandatory)][string]$ContainerName
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-windows-container-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-windows-container-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $dockerArgsFile = Join-Path $env:TEMP ("ni-windows-container-docker-args-{0}.json" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $pwshPath = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($pwshPath)) {
      throw 'pwsh was not found; unable to launch docker command.'
    }

    $DockerArgs | ConvertTo-Json -Compress | Set-Content -LiteralPath $dockerArgsFile -Encoding utf8
    $dockerArgsFileEscaped = $dockerArgsFile.Replace("'", "''")
    $invokeDockerScript = @"
`$raw = Get-Content -LiteralPath '$dockerArgsFileEscaped' -Raw
if ([string]::IsNullOrWhiteSpace(`$raw)) {
  `$args = @()
} else {
  `$parsed = `$raw | ConvertFrom-Json
  if (`$parsed -is [System.Collections.IEnumerable] -and -not (`$parsed -is [string])) {
    `$args = @(`$parsed | ForEach-Object { [string]`$_ })
  } elseif (`$null -eq `$parsed) {
    `$args = @()
  } else {
    `$args = @([string]`$parsed)
  }
}
& docker @args
exit `$LASTEXITCODE
"@
    $encodedInvokeDockerScript = Convert-ToEncodedCommand -CommandText $invokeDockerScript

    $process = Start-Process -FilePath $pwshPath `
      -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encodedInvokeDockerScript) `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -PassThru

    $waitMs = [Math]::Max(1, $Seconds) * 1000
    if (-not $process.WaitForExit($waitMs)) {
      try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
      try { & docker rm -f $ContainerName *> $null } catch {}
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
    Remove-Item -LiteralPath $dockerArgsFile -ErrorAction SilentlyContinue
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
  exitCode      = $null
  timedOut      = $false
  dockerServerOs= $null
  baseVi        = $null
  headVi        = $null
  reportPath    = $null
  command       = $null
  stdoutPath    = $null
  stderrPath    = $null
  message       = $null
}

$finalExitCode = 0
$stdoutContent = ''
$stderrContent = ''
$capturePath = $null
$stdoutPath = $null
$stderrPath = $null

try {
  Assert-Tool -Name 'docker'

  $dockerOsType = Get-DockerServerOsType
  $capture.dockerServerOs = $dockerOsType
  if ($dockerOsType -ne 'windows') {
    throw ("Docker daemon is running in '{0}' mode. Switch Docker Desktop to Windows containers and retry." -f $dockerOsType)
  }
  if (-not (Test-DockerImageExists -Tag $Image)) {
    throw ("Docker image '{0}' not found locally. Pull it first: docker pull {0}" -f $Image)
  }

  if ($Probe) {
    $capture.status = 'probe-ok'
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

    $capturePath = Join-Path $reportDirectory 'ni-windows-container-capture.json'
    $stdoutPath = Join-Path $reportDirectory 'ni-windows-container-stdout.txt'
    $stderrPath = Join-Path $reportDirectory 'ni-windows-container-stderr.txt'

    $capture.baseVi = $baseViPath
    $capture.headVi = $headViPath
    $capture.reportPath = $resolvedReportPath
    $capture.stdoutPath = $stdoutPath
    $capture.stderrPath = $stderrPath

    $flagsPayload = if ($Flags) { @($Flags) } else { @() }
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
    $containerCommand = New-ContainerCommand
    $encodedContainerCommand = Convert-ToEncodedCommand -CommandText $containerCommand

    $dockerArgs = @(
      'run',
      '--rm',
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
    if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      $dockerArgs += @('--env', ("COMPARE_LABVIEW_PATH={0}" -f $LabVIEWPath))
    }
    $dockerArgs += @(
      $Image,
      'powershell',
      '-NoLogo',
      '-NoProfile',
      '-EncodedCommand',
      $encodedContainerCommand
    )

    $capture.command = ('docker run --rm --name {0} ... {1} powershell -NoLogo -NoProfile -EncodedCommand <base64-compare-script>' -f $containerName, $Image)
    Write-Host ("[ni-container-compare] image={0} report={1}" -f $Image, $resolvedReportPath) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout -DockerArgs $dockerArgs -Seconds $TimeoutSeconds -ContainerName $containerName
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

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
  if (-not $Probe) {
    if ($stdoutPath) { Write-TextArtifact -Path $stdoutPath -Content $stdoutContent }
    if ($stderrPath) { Write-TextArtifact -Path $stderrPath -Content $stderrContent }
    if ($capturePath) {
      $capture.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
      $capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8
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
