#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a LabVIEW CLI custom operation inside the pinned NI Linux container.

.DESCRIPTION
  Preflights Docker Desktop against `nationalinstruments/labview:2026q1-linux`
  and then executes a LabVIEW CLI custom operation inside that container using a
  mounted operation workspace, mounted capture directory, and optional extra
  mounts for scenario inputs such as pinned sample repositories.

  The Linux LabVIEW image uses `bash` inside the container. This helper must
  not assume `pwsh` exists in that plane.
#>
[CmdletBinding()]
param(
  [string]$OperationName = 'PrintToSingleFileHtml',
  [string]$AdditionalOperationDirectory,
  [string]$Image = 'nationalinstruments/labview:2026q1-linux',
  [string]$ResultsRoot = 'tests/results/ni-linux-custom-operation',
  [object[]]$Arguments,
  [string]$ArgumentsJson = '',
  [string[]]$AdditionalMount,
  [string]$ExpectedOutputPath = '',
  [switch]$Help,
  [switch]$Headless,
  [switch]$LogToConsole,
  [string]$LabVIEWPath,
  [int]$TimeoutSeconds = 180,
  [int]$HeartbeatSeconds = 15,
  [int]$PrelaunchWaitSeconds = 8,
  [switch]$Probe,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PreflightExitCode = 2
$script:TimeoutExitCode = 124
$script:ContainerOperationRoot = '/custom-operation'
$script:ContainerCaptureRoot = '/capture'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-ScriptPath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [AllowEmptyString()][string]$PathValue,
    [Parameter(Mandatory)][string]$DefaultRelativePath
  )

  $effective = if ([string]::IsNullOrWhiteSpace($PathValue)) { $DefaultRelativePath } else { $PathValue }
  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $effective
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Script path was not found: '$resolved'."
  }
  return $resolved
}

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
  foreach ($command in $commands) {
    if ([string]::IsNullOrWhiteSpace([string]$command.Source)) { continue }
    $source = [string]$command.Source
    if (Test-Path -LiteralPath $source -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($source)
    }
  }

  throw 'Unable to resolve docker command source path.'
}

function Get-DockerProcessLaunchSpec {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs
  )

  $dockerCommandSource = Resolve-DockerCommandSource
  $startFilePath = $dockerCommandSource
  $startArgs = @($DockerArgs)
  $dockerSourceExt = [System.IO.Path]::GetExtension($dockerCommandSource)
  if ([System.StringComparer]::OrdinalIgnoreCase.Equals($dockerSourceExt, '.ps1')) {
    $pwshExe = (Get-Command -Name 'pwsh' -ErrorAction Stop).Source
    $escapedScriptPath = $dockerCommandSource.Replace("'", "''")
    $startFilePath = $pwshExe
    $startArgs = @(
      '-NoLogo',
      '-NoProfile',
      '-Command',
      ("& '{0}' @args" -f $escapedScriptPath),
      '--'
    ) + @($DockerArgs)
  }

  return [pscustomobject]@{
    FilePath = $startFilePath
    Arguments = @($startArgs)
  }
}

function Invoke-DockerCommandAndCapture {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-linux-custom-op-docker-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-linux-custom-op-docker-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $launchSpec = Get-DockerProcessLaunchSpec -DockerArgs $DockerArgs
    $process = Start-Process -FilePath $launchSpec.FilePath `
      -ArgumentList $launchSpec.Arguments `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = [int]$process.ExitCode
      StdOut = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
      StdErr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
    }
  } finally {
    if ($process) {
      try { $process.Dispose() } catch {}
    }
    Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue
  }
}

function Invoke-DockerRunWithTimeout {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs,
    [Parameter(Mandatory)][int]$Seconds,
    [Parameter(Mandatory)][string]$Image,
    [int]$HeartbeatSeconds = 15
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-linux-custom-op-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-linux-custom-op-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $process = $null
  try {
    $launchSpec = Get-DockerProcessLaunchSpec -DockerArgs $DockerArgs
    $process = Start-Process -FilePath $launchSpec.FilePath `
      -ArgumentList $launchSpec.Arguments `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $Seconds))
    $lastHeartbeat = Get-Date
    while (-not $process.HasExited) {
      if ((Get-Date) -ge $deadline) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
        return [pscustomobject]@{
          TimedOut = $true
          ExitCode = $script:TimeoutExitCode
          StdOut = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
          StdErr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
        }
      }

      if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge [Math]::Max(5, $HeartbeatSeconds)) {
        Write-Host ("[ni-linux-custom-op] running image={0} elapsed={1:n1}s timeout={2}s" -f $Image, ((Get-Date) - $process.StartTime).TotalSeconds, $Seconds) -ForegroundColor DarkGray
        $lastHeartbeat = Get-Date
      }
      Start-Sleep -Milliseconds 500
    }

    return [pscustomobject]@{
      TimedOut = $false
      ExitCode = [int]$process.ExitCode
      StdOut = if (Test-Path -LiteralPath $stdoutFile -PathType Leaf) { Get-Content -LiteralPath $stdoutFile -Raw } else { '' }
      StdErr = if (Test-Path -LiteralPath $stderrFile -PathType Leaf) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
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
  if ($parent) {
    Ensure-Directory -Path $parent | Out-Null
  }
  if ($null -eq $Content) {
    $Content = ''
  }
  Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

function Write-UnixTextArtifact {
  param(
    [Parameter(Mandatory)][string]$Path,
    [AllowNull()][string]$Content
  )

  $parent = Split-Path -Parent $Path
  if ($parent) {
    Ensure-Directory -Path $parent | Out-Null
  }
  if ($null -eq $Content) {
    $Content = ''
  }
  $normalized = $Content -replace "`r`n", "`n"
  $encoding = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
}

function Quote-CommandArgument {
  param([AllowNull()][string]$Text)

  if ($null -eq $Text) {
    return '""'
  }

  if ($Text -match '[\s"]') {
    return '"' + ($Text -replace '"', '\"') + '"'
  }

  return $Text
}

function Convert-ToCliBoolToken {
  param([bool]$Value)
  if ($Value) { return 'true' }
  return 'false'
}

function Build-CustomOperationArgs {
  param(
    [Parameter(Mandatory)][string]$OperationName,
    [Parameter(Mandatory)][string]$ContainerOperationDirectory,
    [AllowNull()][object[]]$Arguments,
    [bool]$Help,
    [bool]$Headless,
    [bool]$LogToConsole,
    [AllowEmptyString()][string]$LabVIEWPath
  )

  $args = New-Object System.Collections.Generic.List[string]
  $args.Add('-OperationName') | Out-Null
  $args.Add($OperationName) | Out-Null
  $args.Add('-AdditionalOperationDirectory') | Out-Null
  $args.Add($ContainerOperationDirectory) | Out-Null

  if ($Help) {
    $args.Add('-Help') | Out-Null
  }

  foreach ($arg in @($Arguments)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
      $args.Add([string]$arg) | Out-Null
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $args.Add('-LabVIEWPath') | Out-Null
    $args.Add($LabVIEWPath) | Out-Null
  }

  $args.Add('-LogToConsole') | Out-Null
  $args.Add((Convert-ToCliBoolToken -Value $LogToConsole)) | Out-Null
  $args.Add('-Headless') | Out-Null
  $args.Add((Convert-ToCliBoolToken -Value $Headless)) | Out-Null

  return @($args)
}

function New-InContainerPreview {
  param(
    [Parameter(Mandatory)][string]$OperationName,
    [Parameter(Mandatory)][string]$ContainerOperationDirectory,
    [AllowNull()][object[]]$Arguments,
    [bool]$Help,
    [bool]$Headless,
    [bool]$LogToConsole,
    [AllowEmptyString()][string]$LabVIEWPath
  )

  $args = Build-CustomOperationArgs `
    -OperationName $OperationName `
    -ContainerOperationDirectory $ContainerOperationDirectory `
    -Arguments $Arguments `
    -Help $Help `
    -Headless $Headless `
    -LogToConsole $LogToConsole `
    -LabVIEWPath $LabVIEWPath
  $commandText = 'LabVIEWCLI {0}' -f ((@($args | ForEach-Object { Quote-CommandArgument -Text $_ })) -join ' ')

  return [ordered]@{
    operation = 'RunCustomOperation'
    provider = 'labviewcli'
    cliPath = 'in-container'
    args = @($args)
    command = $commandText
  }
}

function Resolve-AdditionalMounts {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [AllowNull()][string[]]$Entries
  )

  $resolved = New-Object System.Collections.Generic.List[object]
  foreach ($entry in @($Entries)) {
    if ([string]::IsNullOrWhiteSpace([string]$entry)) {
      continue
    }

    $separatorIndex = $entry.IndexOf('::')
    if ($separatorIndex -lt 1) {
      throw "Additional mount entry must use 'hostPath::/container/path' format: '$entry'."
    }

    $hostPath = [string]$entry.Substring(0, $separatorIndex)
    $containerPath = [string]$entry.Substring($separatorIndex + 2)
    $resolvedHostPath = Resolve-AbsolutePath -BasePath $BasePath -PathValue $hostPath
    if (-not (Test-Path -LiteralPath $resolvedHostPath)) {
      throw "Additional mount host path was not found: '$resolvedHostPath'."
    }

    $normalizedContainerPath = $containerPath.Trim().Replace('\', '/')
    if (-not $normalizedContainerPath.StartsWith('/')) {
      throw "Additional mount container path must be absolute: '$containerPath'."
    }
    foreach ($reserved in @($script:ContainerOperationRoot, $script:ContainerCaptureRoot)) {
      if (
        [string]::Equals($normalizedContainerPath, $reserved, [System.StringComparison]::Ordinal) -or
        $normalizedContainerPath.StartsWith($reserved.TrimEnd('/') + '/', [System.StringComparison]::Ordinal)
      ) {
        throw "Additional mount container path '$normalizedContainerPath' collides with reserved path '$reserved'."
      }
    }

    $resolved.Add([pscustomobject]@{
        hostPath = $resolvedHostPath
        containerPath = $normalizedContainerPath
      }) | Out-Null
  }

  return @($resolved.ToArray())
}

function Get-DockerContextName {
  $result = Invoke-DockerCommandAndCapture -DockerArgs @('context', 'show')
  if ($result.ExitCode -ne 0) {
    $message = if ([string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdOut } else { $result.StdErr }
    throw "Failed to query docker context: $message"
  }
  return ($result.StdOut.Trim())
}

function Get-DockerInfoRecord {
  $result = Invoke-DockerCommandAndCapture -DockerArgs @('info', '--format', '{{.OSType}}')
  if ($result.ExitCode -ne 0) {
    $message = if ([string]::IsNullOrWhiteSpace($result.StdErr)) { $result.StdOut } else { $result.StdErr }
    throw "Failed to query docker info: $message"
  }

  $text = $result.StdOut.Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw 'Docker info returned empty output.'
  }
  return [pscustomobject]@{ OSType = $text }
}

function Test-DockerImageExists {
  param([Parameter(Mandatory)][string]$Tag)

  $result = Invoke-DockerCommandAndCapture -DockerArgs @('image', 'inspect', $Tag)
  return ($result.ExitCode -eq 0)
}

function New-ContainerCommand {
  return @'
set -u
set -o pipefail

ensure_dir() {
  mkdir -p "$1"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

json_bool() {
  if [ "$1" = "1" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

json_string_or_null() {
  if [ -n "$1" ]; then
    printf '"%s"' "$(json_escape "$1")"
  else
    printf 'null'
  fi
}

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
  if [ -n "${CUSTOM_OP_REQUESTED_LABVIEW_PATH:-}" ] && [ -x "${CUSTOM_OP_REQUESTED_LABVIEW_PATH}" ]; then
    echo "${CUSTOM_OP_REQUESTED_LABVIEW_PATH}"
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

capture_root="${CUSTOM_OP_CAPTURE_ROOT:-/capture}"
args_file="${CUSTOM_OP_ARGS_FILE:-}"
stdout_path="${capture_root}/labview-cli-stdout.txt"
stderr_path="${capture_root}/labview-cli-stderr.txt"
result_path="${capture_root}/scenario-result.json"
expected_output_path="${CUSTOM_OP_EXPECT_OUTPUT_PATH:-}"
requested_labview_path="${CUSTOM_OP_REQUESTED_LABVIEW_PATH:-}"

ensure_dir "${capture_root}"

if [ -z "${args_file}" ] || [ ! -f "${args_file}" ]; then
  echo "CUSTOM_OP_ARGS_FILE is required and must exist." 1>&2
  exit 2
fi

if ! cli_path="$(find_cli)"; then
  echo "LabVIEWCLI not found in container. Ensure NI image includes the LabVIEW CLI component." 1>&2
  exit 2
fi

if ! command -v xvfb-run >/dev/null 2>&1; then
  echo "xvfb-run not found. Linux headless custom operations require Xvfb." 1>&2
  exit 2
fi

ini_path=""
if ini_path="$(find_cli_ini)"; then
  set_ini_timeout_token "$ini_path" "OpenAppReferenceTimeoutInSecond" "${CUSTOM_OP_OPEN_APP_TIMEOUT:-180}"
  set_ini_timeout_token "$ini_path" "AfterLaunchOpenAppReferenceTimeoutInSecond" "${CUSTOM_OP_AFTER_LAUNCH_TIMEOUT:-180}"
fi

prelaunch_attempted=0
if [ "${CUSTOM_OP_PRELAUNCH_ENABLED:-1}" = "1" ]; then
  if lv_path="$(find_labview)"; then
    prelaunch_attempted=1
    "${lv_path}" --headless >/tmp/custom-op-prelaunch.log 2>&1 &
    sleep "${CUSTOM_OP_PRELAUNCH_WAIT_SECONDS:-8}"
  fi
fi

declare -a cli_args
while IFS= read -r arg || [ -n "$arg" ]; do
  cli_args+=("$arg")
done < "${args_file}"

timed_out=0
exit_code=0
xvfb-run -a "${cli_path}" "${cli_args[@]}" </dev/null >"${stdout_path}" 2>"${stderr_path}" &
cli_pid=$!
deadline=$(( $(date +%s) + ${CUSTOM_OP_TIMEOUT_SECONDS:-180} ))
while kill -0 "${cli_pid}" 2>/dev/null; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    timed_out=1
    kill -9 "${cli_pid}" 2>/dev/null || true
    wait "${cli_pid}" 2>/dev/null || true
    break
  fi
  sleep 1
done

if [ "${timed_out}" = "1" ]; then
  exit_code=124
else
  wait "${cli_pid}"
  exit_code=$?
fi

output_exists=0
if [ -n "${expected_output_path}" ] && [ -f "${expected_output_path}" ]; then
  output_exists=1
fi
if [ "${exit_code}" = "0" ] && [ -n "${expected_output_path}" ] && [ "${output_exists}" = "0" ]; then
  exit_code=1
fi

finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
status="failed"
if [ "${timed_out}" = "1" ]; then
  status="timed-out"
elif [ "${exit_code}" = "0" ]; then
  status="succeeded"
fi

cat > "${result_path}" <<EOF
{
  "schema": "ni-linux-container-custom-operation-scenario@v1",
  "status": "${status}",
  "timedOut": $(json_bool "${timed_out}"),
  "exitCode": ${exit_code},
  "cliPath": $(json_string_or_null "${cli_path}"),
  "requestedLabVIEWPath": $(json_string_or_null "${requested_labview_path}"),
  "stdoutPath": $(json_string_or_null "${stdout_path}"),
  "stderrPath": $(json_string_or_null "${stderr_path}"),
  "prelaunchAttempted": $(json_bool "${prelaunch_attempted}"),
  "iniPath": $(json_string_or_null "${ini_path}"),
  "expectedOutputPath": $(json_string_or_null "${expected_output_path}"),
  "outputExists": $(json_bool "${output_exists}"),
  "finishedAt": $(json_string_or_null "${finished_at}")
}
EOF

exit "${exit_code}"
'@
}

$repoRoot = Resolve-RepoRoot
$shellContractScriptResolved = Resolve-ScriptPath -RepoRoot $repoRoot -PathValue '' -DefaultRelativePath 'tools/Get-LabVIEWContainerShellContract.ps1'
$shellContract = & $shellContractScriptResolved -Plane linux
if ([string]::IsNullOrWhiteSpace([string]$shellContract.executable)) {
  throw 'Linux shell contract did not declare an executable.'
}

$effectiveArguments = @()
if (-not [string]::IsNullOrWhiteSpace($ArgumentsJson)) {
  $parsedArguments = $ArgumentsJson | ConvertFrom-Json -ErrorAction Stop
  if ($parsedArguments -is [System.Collections.IEnumerable] -and -not ($parsedArguments -is [string])) {
    $effectiveArguments = @($parsedArguments | ForEach-Object { [string]$_ })
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$parsedArguments)) {
    $effectiveArguments = @([string]$parsedArguments)
  }
} elseif ($Arguments) {
  $effectiveArguments = @($Arguments | ForEach-Object { [string]$_ })
}

$resultsRootResolved = Ensure-Directory -Path (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot)
$capturePath = Join-Path $resultsRootResolved 'ni-linux-custom-operation-capture.json'
$stdoutPath = Join-Path $resultsRootResolved 'ni-linux-custom-operation-run-stdout.txt'
$stderrPath = Join-Path $resultsRootResolved 'ni-linux-custom-operation-run-stderr.txt'
$scenarioResultPath = Join-Path $resultsRootResolved 'scenario-result.json'
$containerArgsPath = Join-Path $resultsRootResolved 'custom-operation-args.txt'
$containerScriptHostPath = Join-Path $resultsRootResolved 'custom-operation-runner.sh'
$containerScriptContainerPath = '{0}/custom-operation-runner.sh' -f $script:ContainerCaptureRoot
$containerArgsContainerPath = '{0}/custom-operation-args.txt' -f $script:ContainerCaptureRoot

$capture = [ordered]@{
  schema = 'ni-linux-container-custom-operation/v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = 'init'
  classification = 'init'
  image = $Image
  operationName = $OperationName
  resultsRoot = $resultsRootResolved
  additionalOperationDirectory = $null
  additionalMounts = @()
  requestedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) { $null } else { $LabVIEWPath }
  timeoutSeconds = [int]$TimeoutSeconds
  probe = [bool]$Probe
  dockerServerOs = $null
  dockerContext = $null
  shellContract = $shellContract
  preview = $null
  expectedOutputPath = if ([string]::IsNullOrWhiteSpace($ExpectedOutputPath)) { $null } else { $ExpectedOutputPath }
  scenarioResultPath = $scenarioResultPath
  stdoutPath = $stdoutPath
  stderrPath = $stderrPath
  containerCommand = $null
  exitCode = $null
  timedOut = $false
  message = $null
  scenarioResult = $null
}

$finalExitCode = 0
$stdoutContent = ''
$stderrContent = ''

try {
  Assert-Tool -Name 'docker'

  $dockerContext = Get-DockerContextName
  $dockerInfo = Get-DockerInfoRecord
  $dockerServerOs = [string]$dockerInfo.OSType
  $capture.dockerContext = $dockerContext
  $capture.dockerServerOs = $dockerServerOs
  if (-not [string]::Equals($dockerServerOs, 'linux', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("Docker server OS must be linux for the NI Linux custom-operation plane; observed '{0}'." -f $dockerServerOs)
  }

  if (-not (Test-DockerImageExists -Tag $Image)) {
    throw ("Docker image '{0}' not found locally. Pull it first: docker pull {0}" -f $Image)
  }

  if ($Probe) {
    $capture.status = 'probe-ok'
    $capture.classification = 'probe-ok'
    $capture.exitCode = 0
    $capture.message = ("Docker is in linux mode and image '{0}' is available." -f $Image)
  } else {
    if ([string]::IsNullOrWhiteSpace($AdditionalOperationDirectory)) {
      throw '-AdditionalOperationDirectory is required unless -Probe is set.'
    }

    $operationDirectoryResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $AdditionalOperationDirectory
    if (-not (Test-Path -LiteralPath $operationDirectoryResolved -PathType Container)) {
      throw "Custom operation directory was not found at '$operationDirectoryResolved'."
    }
    $capture.additionalOperationDirectory = $operationDirectoryResolved

    $resolvedAdditionalMounts = Resolve-AdditionalMounts -BasePath $repoRoot -Entries $AdditionalMount
    $capture.additionalMounts = @(
      $resolvedAdditionalMounts | ForEach-Object {
        [ordered]@{
          hostPath = [string]$_.hostPath
          containerPath = [string]$_.containerPath
        }
      }
    )

    $preview = New-InContainerPreview `
      -OperationName $OperationName `
      -ContainerOperationDirectory $script:ContainerOperationRoot `
      -Arguments $effectiveArguments `
      -Help:$Help.IsPresent `
      -Headless:$Headless.IsPresent `
      -LogToConsole:$LogToConsole.IsPresent `
      -LabVIEWPath $LabVIEWPath
    $capture.preview = $preview

    Write-UnixTextArtifact -Path $containerArgsPath -Content ((@($preview.args) -join "`n") + "`n")
    Write-UnixTextArtifact -Path $containerScriptHostPath -Content (New-ContainerCommand)

    $dockerArgs = @(
      'run',
      '--rm',
      '--workdir', $script:ContainerOperationRoot,
      '-v', ('{0}:{1}' -f $operationDirectoryResolved, $script:ContainerOperationRoot),
      '-v', ('{0}:{1}' -f $resultsRootResolved, $script:ContainerCaptureRoot)
    )
    foreach ($mount in @($resolvedAdditionalMounts)) {
      $dockerArgs += @('-v', ('{0}:{1}' -f $mount.hostPath, $mount.containerPath))
    }
    $dockerArgs += @(
      '--env', ('CUSTOM_OP_CAPTURE_ROOT={0}' -f $script:ContainerCaptureRoot),
      '--env', ('CUSTOM_OP_ARGS_FILE={0}' -f $containerArgsContainerPath),
      '--env', ('CUSTOM_OP_TIMEOUT_SECONDS={0}' -f [Math]::Max(1, $TimeoutSeconds)),
      '--env', ('CUSTOM_OP_PRELAUNCH_ENABLED={0}' -f 1),
      '--env', ('CUSTOM_OP_PRELAUNCH_WAIT_SECONDS={0}' -f [Math]::Max(0, $PrelaunchWaitSeconds)),
      '--env', 'CUSTOM_OP_OPEN_APP_TIMEOUT=180',
      '--env', 'CUSTOM_OP_AFTER_LAUNCH_TIMEOUT=180'
    )
    if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      $dockerArgs += @('--env', ('CUSTOM_OP_REQUESTED_LABVIEW_PATH={0}' -f $LabVIEWPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOutputPath)) {
      $dockerArgs += @('--env', ('CUSTOM_OP_EXPECT_OUTPUT_PATH={0}' -f $ExpectedOutputPath))
    }
    $dockerArgs += @(
      $Image,
      [string]$shellContract.executable,
      $containerScriptContainerPath
    )

    $capture.containerCommand = ('docker run --rm --workdir {0} ... {1} {2} {3}' -f $script:ContainerOperationRoot, $Image, [string]$shellContract.executable, $containerScriptContainerPath)
    Write-Host ("[ni-linux-custom-op] dockerContext={0} dockerServerOs={1} image={2} operation={3}" -f (($dockerContext ?? '<null>')), (($dockerServerOs ?? '<null>')), $Image, $OperationName) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout `
      -DockerArgs $dockerArgs `
      -Seconds ([Math]::Max($TimeoutSeconds + 15, $TimeoutSeconds)) `
      -HeartbeatSeconds $HeartbeatSeconds `
      -Image $Image
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

    if ($runResult.TimedOut) {
      $capture.status = 'timeout'
      $capture.classification = 'timeout'
      $capture.timedOut = $true
      $capture.exitCode = $script:TimeoutExitCode
      $capture.message = ("Linux container custom operation timed out after {0} second(s)." -f $TimeoutSeconds)
      $finalExitCode = $script:TimeoutExitCode
    } else {
      $capture.exitCode = [int]$runResult.ExitCode
      $finalExitCode = [int]$runResult.ExitCode
      if (Test-Path -LiteralPath $scenarioResultPath -PathType Leaf) {
        $scenarioResult = Get-Content -LiteralPath $scenarioResultPath -Raw | ConvertFrom-Json -Depth 12
        $capture.scenarioResult = $scenarioResult
        switch ([string]$scenarioResult.status) {
          'succeeded' {
            $capture.status = 'ok'
            $capture.classification = 'ok'
          }
          'timed-out' {
            $capture.status = 'timeout'
            $capture.classification = 'timeout'
            $capture.timedOut = $true
            if (-not $capture.message) {
              $capture.message = ("Linux container custom operation timed out after {0} second(s)." -f $TimeoutSeconds)
            }
          }
          default {
            $capture.status = 'error'
            $capture.classification = 'run-error'
            $capture.message = 'Linux container custom operation did not complete successfully.'
          }
        }
      } else {
        $capture.status = 'error'
        $capture.classification = 'missing-result'
        $capture.message = "Container run completed without emitting '$scenarioResultPath'."
        if ($finalExitCode -eq 0) {
          $finalExitCode = 1
        }
      }
    }
  }
} catch {
  $capture.status = 'preflight-error'
  $capture.classification = 'preflight-error'
  $capture.exitCode = $script:PreflightExitCode
  $capture.message = $_.Exception.Message
  $finalExitCode = $script:PreflightExitCode
} finally {
  if (-not $Probe) {
    Write-TextArtifact -Path $stdoutPath -Content $stdoutContent
    Write-TextArtifact -Path $stderrPath -Content $stderrContent
  }
  $capture.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  $capture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capturePath -Encoding utf8
  Write-Host ("[ni-linux-custom-op] capture={0} status={1} exit={2}" -f $capturePath, $capture.status, $capture.exitCode) -ForegroundColor DarkGray
}

if ($PassThru) {
  [pscustomobject]$capture
}

exit $finalExitCode
