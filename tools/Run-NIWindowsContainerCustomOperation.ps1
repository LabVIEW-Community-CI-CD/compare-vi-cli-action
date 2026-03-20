#Requires -Version 7.0
<#
.SYNOPSIS
  Runs a LabVIEW CLI custom operation inside the pinned NI Windows container.

.DESCRIPTION
  Preflights Docker Desktop against `nationalinstruments/labview:2026q1-windows`
  and then executes a LabVIEW CLI custom operation inside that container using a
  mounted operation workspace and mounted capture directory on the host.

  The Windows LabVIEW image uses native `powershell` inside the container.
  This helper must not assume `pwsh` exists in that plane.

  The helper is intentionally scenario-oriented:
  - it accepts the same LabVIEW CLI custom-operation knobs exposed by
    `Invoke-LVCustomOperation`
  - it emits a deterministic capture JSON adjacent to the scenario artifacts
  - it keeps Windows-container execution separate from host-plane execution so
    `Test-LabVIEWCLICustomOperationProof.ps1` can compare both surfaces cleanly
#>
[CmdletBinding()]
param(
  [string]$OperationName = 'AddTwoNumbers',
  [string]$AdditionalOperationDirectory,
  [string]$Image = 'nationalinstruments/labview:2026q1-windows',
  [string]$ResultsRoot = 'tests/results/ni-windows-custom-operation',
  [object[]]$Arguments,
  [string]$ArgumentsJson = '',
  [switch]$Help,
  [switch]$Headless,
  [switch]$LogToConsole,
  [string]$LabVIEWPath,
  [int]$TimeoutSeconds = 120,
  [int]$HeartbeatSeconds = 15,
  [int]$PrelaunchWaitSeconds = 8,
  [switch]$Probe,
  [switch]$PassThru,
  [string]$PreflightScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PreflightExitCode = 2
$script:TimeoutExitCode = 124
$script:ContainerOperationRoot = 'C:\custom-operation'
$script:ContainerCaptureRoot = 'C:\capture'

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

  return [pscustomobject]@{
    FilePath = $startFilePath
    Arguments = @($startArgs)
  }
}

function Invoke-DockerCommandAndCapture {
  param(
    [Parameter(Mandatory)][string[]]$DockerArgs
  )

  $stdoutFile = Join-Path $env:TEMP ("ni-windows-custom-op-docker-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-windows-custom-op-docker-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
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

  $stdoutFile = Join-Path $env:TEMP ("ni-windows-custom-op-stdout-{0}.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrFile = Join-Path $env:TEMP ("ni-windows-custom-op-stderr-{0}.log" -f ([guid]::NewGuid().ToString('N')))
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
        Write-Host ("[ni-custom-op-container] running image={0} elapsed={1:n1}s timeout={2}s" -f $Image, ((Get-Date) - $process.StartTime).TotalSeconds, $Seconds) -ForegroundColor DarkGray
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

function Convert-ToEncodedCommand {
  param(
    [Parameter(Mandatory)][string]$CommandText
  )

  return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
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

  $previewArgs = @{
    CustomOperationName = $OperationName
    AdditionalOperationDirectory = $ContainerOperationDirectory
    Provider = 'labviewcli'
    Preview = $true
  }
  if ($Help) { $previewArgs.Help = $true }
  if ($Headless) { $previewArgs.Headless = $true }
  if ($LogToConsole) { $previewArgs.LogToConsole = $true }
  if ($Arguments) { $previewArgs.Arguments = @($Arguments) }
  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) { $previewArgs.LabVIEWPath = $LabVIEWPath }

  $preview = Invoke-LVCustomOperation @previewArgs
  $args = @($preview.args | ForEach-Object { [string]$_ })
  $commandText = 'LabVIEWCLI.exe {0}' -f ((@($args | ForEach-Object { Quote-CommandArgument -Text $_ })) -join ' ')
  return [ordered]@{
    operation = 'RunCustomOperation'
    provider = 'labviewcli'
    cliPath = 'in-container'
    args = $args
    command = $commandText
  }
}

function New-ContainerCommand {
  return @'
$ErrorActionPreference = "Stop"

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
  return (Resolve-Path -LiteralPath $Path).Path
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

function Copy-RelevantLogFiles {
  param(
    [Parameter(Mandatory)][string]$CaptureRoot,
    [Parameter(Mandatory)][datetime]$StartedAtUtc,
    [Parameter(Mandatory)][datetime]$FinishedAtUtc
  )

  $logRoot = Ensure-Directory -Path (Join-Path $CaptureRoot 'logs')
  $roots = @()
  foreach ($rootCandidate in @([System.IO.Path]::GetTempPath(), $env:TEMP, $env:TMP, (Join-Path $env:LOCALAPPDATA 'Temp'))) {
    if ([string]::IsNullOrWhiteSpace($rootCandidate)) { continue }
    try {
      $resolved = [System.IO.Path]::GetFullPath($rootCandidate)
      if (Test-Path -LiteralPath $resolved -PathType Container) {
        $roots += $resolved
      }
    } catch {}
  }
  $roots = @($roots | Select-Object -Unique)

  $lowerBound = $StartedAtUtc.AddSeconds(-5)
  $upperBound = $FinishedAtUtc.AddSeconds(5)
  $captured = New-Object System.Collections.Generic.List[object]
  foreach ($root in $roots) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue)) {
      if ($file.Name -notmatch '^(lvtemporary_.*\.log|LabVIEWCLI.*(?:\.log|\.txt)?)$') { continue }
      $lastWriteUtc = $file.LastWriteTimeUtc
      if ($lastWriteUtc -lt $lowerBound -or $lastWriteUtc -gt $upperBound) { continue }
      $destinationPath = Join-Path $logRoot $file.Name
      Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
      $captured.Add([ordered]@{
          name = $file.Name
          sourcePath = $file.FullName
          destinationPath = $destinationPath
          lastWriteTimeUtc = $lastWriteUtc.ToString('o')
          length = [int64]$file.Length
        }) | Out-Null
    }
  }

  return @($captured.ToArray())
}

$captureRoot = Ensure-Directory -Path $env:CUSTOM_OP_CAPTURE_ROOT
$stdoutPath = Join-Path $captureRoot 'labview-cli-stdout.txt'
$stderrPath = Join-Path $captureRoot 'labview-cli-stderr.txt'
$resultPath = Join-Path $captureRoot 'scenario-result.json'
$requestedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($env:CUSTOM_OP_REQUESTED_LABVIEW_PATH)) { $null } else { $env:CUSTOM_OP_REQUESTED_LABVIEW_PATH }

$cliCandidates = @(
  "C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe",
  "C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe"
)
$cliPath = $cliCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $cliPath) {
  throw "LabVIEWCLI.exe not found in container. Ensure the NI image includes the LabVIEW CLI component."
}

$openTimeout = 180
if (-not [string]::IsNullOrWhiteSpace($env:CUSTOM_OP_OPEN_APP_TIMEOUT)) {
  [void][int]::TryParse($env:CUSTOM_OP_OPEN_APP_TIMEOUT, [ref]$openTimeout)
}
$afterLaunchTimeout = 180
if (-not [string]::IsNullOrWhiteSpace($env:CUSTOM_OP_AFTER_LAUNCH_TIMEOUT)) {
  [void][int]::TryParse($env:CUSTOM_OP_AFTER_LAUNCH_TIMEOUT, [ref]$afterLaunchTimeout)
}

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
}

$cliArgsJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:CUSTOM_OP_ARGS_B64))
$cliArgs = @()
if (-not [string]::IsNullOrWhiteSpace($cliArgsJson)) {
  $parsedArgs = $cliArgsJson | ConvertFrom-Json -ErrorAction Stop
  if ($parsedArgs -is [System.Collections.IEnumerable] -and -not ($parsedArgs -is [string])) {
    $cliArgs = @($parsedArgs | ForEach-Object { [string]$_ })
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$parsedArgs)) {
    $cliArgs = @([string]$parsedArgs)
  }
}

$prelaunchAttempted = $false
$prelaunchEnabled = -not [string]::Equals($env:CUSTOM_OP_PRELAUNCH_ENABLED, '0', [System.StringComparison]::OrdinalIgnoreCase)
if ($prelaunchEnabled) {
  $lvCandidates = @(
    $requestedLabVIEWPath,
    "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe",
    "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe"
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
  $lvPath = $lvCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($lvPath) {
    $prelaunchAttempted = $true
    Start-Process -FilePath $lvPath -ArgumentList '--headless' -WindowStyle Hidden | Out-Null
    $prelaunchWait = 8
    if (-not [string]::IsNullOrWhiteSpace($env:CUSTOM_OP_PRELAUNCH_WAIT_SECONDS)) {
      [void][int]::TryParse($env:CUSTOM_OP_PRELAUNCH_WAIT_SECONDS, [ref]$prelaunchWait)
    }
    if ($prelaunchWait -gt 0) {
      Start-Sleep -Seconds $prelaunchWait
    }
  }
}

$startedAtUtc = (Get-Date).ToUniversalTime()
$process = Start-Process -FilePath $cliPath -ArgumentList $cliArgs -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -NoNewWindow -PassThru
$timedOut = $false
$deadline = (Get-Date).AddSeconds([Math]::Max(1, [int]$env:CUSTOM_OP_TIMEOUT_SECONDS))
while (-not $process.HasExited) {
  if ((Get-Date) -ge $deadline) {
    $timedOut = $true
    try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    break
  }
  Start-Sleep -Milliseconds 500
}

$exitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
try {
  Get-Process -Name 'LabVIEW', 'LabVIEWCLI' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
} catch {}
$finishedAtUtc = (Get-Date).ToUniversalTime()
$logFiles = Copy-RelevantLogFiles -CaptureRoot $captureRoot -StartedAtUtc $startedAtUtc -FinishedAtUtc $finishedAtUtc

$result = [ordered]@{
  schema = 'ni-windows-container-custom-operation-scenario@v1'
  status = if ($timedOut) { 'timed-out' } elseif ($exitCode -eq 0) { 'succeeded' } else { 'failed' }
  timedOut = [bool]$timedOut
  exitCode = [int]$exitCode
  cliPath = $cliPath
  requestedLabVIEWPath = $requestedLabVIEWPath
  stdoutPath = $stdoutPath
  stderrPath = $stderrPath
  logFiles = @($logFiles)
  prelaunchAttempted = [bool]$prelaunchAttempted
  iniPath = $cliIni
  openTimeout = [int]$openTimeout
  afterLaunchTimeout = [int]$afterLaunchTimeout
  finishedAt = $finishedAtUtc.ToString('o')
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
exit $exitCode
'@
}

$repoRoot = Resolve-RepoRoot
Import-Module (Join-Path $repoRoot 'tools' 'LabVIEWCli.psm1') -Force | Out-Null

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
$capturePath = Join-Path $resultsRootResolved 'ni-windows-custom-operation-capture.json'
$stdoutPath = Join-Path $resultsRootResolved 'ni-windows-custom-operation-run-stdout.txt'
$stderrPath = Join-Path $resultsRootResolved 'ni-windows-custom-operation-run-stderr.txt'
$scenarioResultPath = Join-Path $resultsRootResolved 'scenario-result.json'
$preflightResultsRoot = Ensure-Directory -Path (Join-Path $resultsRootResolved 'preflight')
$preflightScriptResolved = Resolve-ScriptPath -RepoRoot $repoRoot -PathValue $PreflightScriptPath -DefaultRelativePath 'tools/Test-WindowsNI2026q1HostPreflight.ps1'

$capture = [ordered]@{
  schema = 'ni-windows-container-custom-operation/v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = 'init'
  classification = 'init'
  image = $Image
  operationName = $OperationName
  resultsRoot = $resultsRootResolved
  additionalOperationDirectory = $null
  requestedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) { $null } else { $LabVIEWPath }
  timeoutSeconds = [int]$TimeoutSeconds
  probe = [bool]$Probe
  dockerServerOs = $null
  dockerContext = $null
  preflightPath = $null
  preview = $null
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
$previousRequestedLabVIEWPath = $null
$restoreRequestedLabVIEWPath = $false

try {
  Assert-Tool -Name 'docker'

  $preflightOutput = @(& $preflightScriptResolved -Image $Image -ResultsDir $preflightResultsRoot)
  $preflightPath = @($preflightOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
  if ($preflightPath.Count -eq 0) {
    throw "Windows container preflight did not return a report path. Output: $(@($preflightOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)"
  }
  $preflightPathResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $preflightPath[0]
  $capture.preflightPath = $preflightPathResolved
  if (-not (Test-Path -LiteralPath $preflightPathResolved -PathType Leaf)) {
    throw "Windows container preflight did not produce a report at '$preflightPathResolved'."
  }
  $preflight = Get-Content -LiteralPath $preflightPathResolved -Raw | ConvertFrom-Json -Depth 12
  $capture.dockerServerOs = $preflight.contexts.finalOsType
  $capture.dockerContext = $preflight.contexts.final

  if ($Probe) {
    $capture.status = 'probe-ok'
    $capture.classification = 'probe-ok'
    $capture.exitCode = 0
    $capture.message = ("Windows container preflight succeeded for image '{0}'." -f $Image)
  } else {
    if ([string]::IsNullOrWhiteSpace($AdditionalOperationDirectory)) {
      throw '-AdditionalOperationDirectory is required unless -Probe is set.'
    }

    $operationDirectoryResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $AdditionalOperationDirectory
    if (-not (Test-Path -LiteralPath $operationDirectoryResolved -PathType Container)) {
      throw "Custom operation directory was not found at '$operationDirectoryResolved'."
    }
    $capture.additionalOperationDirectory = $operationDirectoryResolved

    $preview = New-InContainerPreview `
      -OperationName $OperationName `
      -ContainerOperationDirectory $script:ContainerOperationRoot `
      -Arguments $effectiveArguments `
      -Help:$Help.IsPresent `
      -Headless:$Headless.IsPresent `
      -LogToConsole:$LogToConsole.IsPresent `
      -LabVIEWPath $LabVIEWPath
    $capture.preview = $preview

    $cliArgsJson = (@($preview.args) | ConvertTo-Json -Compress)
    if ([string]::IsNullOrWhiteSpace($cliArgsJson)) {
      $cliArgsJson = '[]'
    }
    $cliArgsB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cliArgsJson))
    $containerCommand = New-ContainerCommand
    $encodedCommand = Convert-ToEncodedCommand -CommandText $containerCommand

    $dockerArgs = @(
      'run',
      '--rm',
      '--workdir', $script:ContainerOperationRoot,
      '-v', ('{0}:{1}' -f $operationDirectoryResolved, $script:ContainerOperationRoot),
      '-v', ('{0}:{1}' -f $resultsRootResolved, $script:ContainerCaptureRoot),
      '--env', ('CUSTOM_OP_CAPTURE_ROOT={0}' -f $script:ContainerCaptureRoot),
      '--env', ('CUSTOM_OP_ARGS_B64={0}' -f $cliArgsB64),
      '--env', ('CUSTOM_OP_TIMEOUT_SECONDS={0}' -f [Math]::Max(1, $TimeoutSeconds)),
      '--env', ('CUSTOM_OP_PRELAUNCH_ENABLED={0}' -f 1),
      '--env', ('CUSTOM_OP_PRELAUNCH_WAIT_SECONDS={0}' -f [Math]::Max(0, $PrelaunchWaitSeconds)),
      '--env', 'CUSTOM_OP_OPEN_APP_TIMEOUT=180',
      '--env', 'CUSTOM_OP_AFTER_LAUNCH_TIMEOUT=180'
    )
    if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
      $previousRequestedLabVIEWPath = [Environment]::GetEnvironmentVariable('CUSTOM_OP_REQUESTED_LABVIEW_PATH', 'Process')
      [Environment]::SetEnvironmentVariable('CUSTOM_OP_REQUESTED_LABVIEW_PATH', $LabVIEWPath, 'Process')
      $restoreRequestedLabVIEWPath = $true
      $dockerArgs += @('--env', 'CUSTOM_OP_REQUESTED_LABVIEW_PATH')
    }
    $dockerArgs += @(
      $Image,
      'powershell',
      '-NoLogo',
      '-NoProfile',
      '-EncodedCommand',
      $encodedCommand
    )

    $capture.containerCommand = ('docker run --rm --workdir {0} ... {1} powershell -NoLogo -NoProfile -EncodedCommand <base64-custom-operation-script>' -f $script:ContainerOperationRoot, $Image)
    Write-Host ("[ni-custom-op-container] image={0} operation={1}" -f $Image, $OperationName) -ForegroundColor Cyan

    $runResult = Invoke-DockerRunWithTimeout `
      -DockerArgs $dockerArgs `
      -Seconds ([Math]::Max($TimeoutSeconds + 30, $TimeoutSeconds)) `
      -HeartbeatSeconds $HeartbeatSeconds `
      -Image $Image
    $stdoutContent = $runResult.StdOut
    $stderrContent = $runResult.StdErr

    if ($runResult.TimedOut) {
      $capture.status = 'timeout'
      $capture.classification = 'timeout'
      $capture.timedOut = $true
      $capture.exitCode = $script:TimeoutExitCode
      $capture.message = ("Windows container custom operation timed out after {0} second(s)." -f $TimeoutSeconds)
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
              $capture.message = ("Windows container custom operation timed out after {0} second(s)." -f $TimeoutSeconds)
            }
          }
          default {
            $capture.status = 'error'
            $capture.classification = 'run-error'
            $capture.message = 'Windows container custom operation did not complete successfully.'
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
  if ($restoreRequestedLabVIEWPath) {
    [Environment]::SetEnvironmentVariable('CUSTOM_OP_REQUESTED_LABVIEW_PATH', $previousRequestedLabVIEWPath, 'Process')
  }
  $capture.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  $capture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $capturePath -Encoding utf8
  Write-Host ("[ni-custom-op-container] capture={0} status={1} exit={2}" -f $capturePath, $capture.status, $capture.exitCode) -ForegroundColor DarkGray
}

if ($PassThru) {
  [pscustomobject]$capture
}

exit $finalExitCode
