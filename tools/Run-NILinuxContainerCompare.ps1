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
  [switch]$Probe,
  [bool]$AutoRepairRuntime = $true,
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$RuntimeSnapshotPath,
  [int]$StartupRetryCount = 1,
  [int]$PrelaunchWaitSeconds = 8,
  [int]$RetryDelaySeconds = 8,
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
    @('docker.cmd', 'docker.ps1', 'docker.exe', 'docker.bat', 'docker')
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

function New-ContainerCommand {
  return @'
set -u
set -o pipefail

find_cli() {
  if command -v LabVIEWCLI >/dev/null 2>&1; then
    command -v LabVIEWCLI
    return 0
  fi
  if command -v labviewcli >/dev/null 2>&1; then
    command -v labviewcli
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

if ! CLI_PATH="$(find_cli)"; then
  echo "LabVIEWCLI not found in container. Ensure NI image includes LabVIEW CLI component." 1>&2
  exit 2
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found. Linux headless container compares require Xvfb." 1>&2
  exit 2
fi

declare -a CLI_ARGS

if [ -n "${COMPARE_LABVIEW_PATH:-}" ]; then
  CLI_ARGS+=("-LabVIEWPath" "${COMPARE_LABVIEW_PATH}")
else
  if LV_PATH="$(find_labview)"; then
    CLI_ARGS+=("-LabVIEWPath" "${LV_PATH}")
  fi
fi

CLI_ARGS+=("-OperationName" "CreateComparisonReport")
CLI_ARGS+=("-VI1" "${COMPARE_BASE_VI}")
CLI_ARGS+=("-VI2" "${COMPARE_HEAD_VI}")
CLI_ARGS+=("-ReportPath" "${COMPARE_REPORT_PATH}")
CLI_ARGS+=("-ReportType" "${COMPARE_REPORT_TYPE}")
CLI_ARGS+=("-Headless")

if [ -n "${COMPARE_FLAGS_B64:-}" ]; then
  while IFS= read -r flag; do
    if [ -n "$flag" ]; then
      CLI_ARGS+=("$flag")
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
ATTEMPT=0
RETRY_TRIGGERED=0
EXIT_CODE=1
OUTPUT_TEXT=""

while true; do
  ATTEMPT=$((ATTEMPT + 1))
  OUTPUT_TEXT="$(xvfb-run -a "${CLI_PATH}" "${CLI_ARGS[@]}" 2>&1)"
  EXIT_CODE=$?
  printf "%s\n" "${OUTPUT_TEXT}"

  if [ "${EXIT_CODE}" = "0" ]; then
    break
  fi

  if [ "${EXIT_CODE}" = "1" ] && ! printf "%s" "${OUTPUT_TEXT}" | grep -Eq "Error code|An error occurred while running the LabVIEW CLI|-350000"; then
    break
  fi

  if printf "%s" "${OUTPUT_TEXT}" | grep -q -- "-350000" && [ "${ATTEMPT}" -le "${MAX_RETRIES}" ]; then
    RETRY_TRIGGERED=1
    sleep "${RETRY_DELAY}"
    continue
  fi

  break
done

printf "%s\n" "[ni-linux-meta]retryAttempts=${ATTEMPT};retryTriggered=${RETRY_TRIGGERED};prelaunchAttempted=${PRELAUNCH_ATTEMPTED};iniPath=${INI_PATH};openTimeout=${COMPARE_OPEN_APP_TIMEOUT:-180};afterLaunchTimeout=${COMPARE_AFTER_LAUNCH_TIMEOUT:-180}"
exit "${EXIT_CODE}"
'@
}

function Resolve-TempDirectoryPath {
  [string[]]$candidates = @(
    $env:TEMP,
    $env:TMP,
    $env:TMPDIR,
    [System.IO.Path]::GetTempPath()
  )
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $fullPath = [System.IO.Path]::GetFullPath($candidate)
      if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
      }
      return $fullPath
    } catch {
      continue
    }
  }
  throw 'Unable to resolve temp directory path for docker compare logs.'
}

function Invoke-DockerRunWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$ContainerName,
    [int]$HeartbeatSeconds = 15
  )

  $tempDirectory = Resolve-TempDirectoryPath
  $stdoutFile = Join-Path $tempDirectory ("ni-linux-container-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $tempDirectory ("ni-linux-container-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $dockerCommandSource = Resolve-DockerCommandSource
    $startFilePath = $dockerCommandSource
    $startArgs = @($DockerArgs)
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals([System.IO.Path]::GetExtension($dockerCommandSource), '.ps1')) {
      $pwshExe = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
      $startFilePath = $pwshExe
      $startArgs = @('-NoLogo', '-NoProfile', '-File', $dockerCommandSource) + @($DockerArgs)
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
        return [pscustomobject]@{
          TimedOut = $true
          ExitCode = $script:TimeoutExitCode
          StdOut   = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
          StdErr   = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
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
      return [pscustomobject]@{
        TimedOut = $true
        ExitCode = $script:TimeoutExitCode
        StdOut   = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
        StdErr   = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
      }
    }

    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut   = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
      StdErr   = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
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
      $reportLeaf = 'linux-compare-report.html'
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
  command        = $null
  stdoutPath     = $null
  stderrPath     = $null
  runtimeDeterminism = $null
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
    copyStatus = 'not-attempted'
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
$containerNameForCleanup = ''
$containerReportPathForExport = ''
$reportDirectoryForExport = ''
$additionalExportPaths = @()

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

  & pwsh -NoLogo -NoProfile -File $runtimeGuardPath `
    -ExpectedOsType linux `
    -ExpectedContext 'desktop-linux' `
    -AutoRepair:$AutoRepairRuntime `
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
    $capture.exitCode = 0
    $capture.message = ("Docker is in linux mode and image '{0}' is available." -f $Image)
    Write-Host ("[ni-linux-container-probe] {0}" -f $capture.message) -ForegroundColor Green
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

    $capturePath = Join-Path $reportDirectory 'ni-linux-container-capture.json'
    $stdoutPath = Join-Path $reportDirectory 'ni-linux-container-stdout.txt'
    $stderrPath = Join-Path $reportDirectory 'ni-linux-container-stderr.txt'

    $capture.baseVi = $baseViPath
    $capture.headVi = $headViPath
    $capture.reportPath = $resolvedReportPath
    $capture.stdoutPath = $stdoutPath
    $capture.stderrPath = $stderrPath
    if (-not $capture.runtimeDeterminism) {
      $capture.runtimeDeterminism = [ordered]@{
        status = 'unknown'
        snapshotPath = $runtimeSnapshot
      }
    } else {
      $capture.runtimeDeterminism.snapshotPath = $runtimeSnapshot
    }

    [string[]]$flagsPayload = @()
    if ($Flags) {
      $flagsPayload = @($Flags | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }
    $flagsJoined = ''
    if ($null -ne $flagsPayload -and $flagsPayload.Length -gt 0) {
      $flagsJoined = [string]::Join("`n", [string[]]$flagsPayload)
    }
    $flagsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($flagsJoined))

    $mounts = @{}
    $mountIndex = 0
    $mountRef = [ref]$mountIndex
    $containerBaseVi = Convert-HostFileToContainerPath -HostFilePath $baseViPath -MountMap $mounts -MountIndex $mountRef
    $containerHeadVi = Convert-HostFileToContainerPath -HostFilePath $headViPath -MountMap $mounts -MountIndex $mountRef
    $containerReportPath = Convert-HostFileToContainerPath -HostFilePath $resolvedReportPath -MountMap $mounts -MountIndex $mountRef

    $containerName = 'ni-lnx-compare-{0}' -f ([guid]::NewGuid().ToString('N').Substring(0, 12))
    $containerNameForCleanup = $containerName
    $containerReportPathForExport = $containerReportPath
    $reportDirectoryForExport = $reportDirectory
    $containerCommand = New-ContainerCommand
    $containerScriptHostPath = Join-Path $reportDirectory ('linux-compare-entrypoint-{0}.sh' -f $containerName)
    Write-UnixScriptArtifact -Path $containerScriptHostPath -Content $containerCommand
    $containerScriptPath = Convert-HostFileToContainerPath -HostFilePath $containerScriptHostPath -MountMap $mounts -MountIndex $mountRef

    $dockerArgs = @(
      'run',
      '--name', $containerName,
      '--workdir', '/compare'
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
    if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      $dockerArgs += @('--env', ("COMPARE_LABVIEW_PATH={0}" -f $LabVIEWPath))
    }
    $dockerArgs += @(
      $Image,
      'bash',
      $containerScriptPath
    )

    $capture.command = ('docker run --name {0} ... {1} bash -lc <linux-compare-script>' -f $containerName, $Image)
    Write-Host ("[ni-linux-container-compare] image={0} report={1}" -f $Image, $resolvedReportPath) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout `
      -DockerArgs $dockerArgs `
      -Seconds $TimeoutSeconds `
      -ContainerName $containerName `
      -HeartbeatSeconds $HeartbeatSeconds
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
