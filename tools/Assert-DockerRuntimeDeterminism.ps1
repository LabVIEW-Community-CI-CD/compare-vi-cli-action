#Requires -Version 7.0
<#
.SYNOPSIS
  Validates and repairs Docker runtime invariants for deterministic automation.

.DESCRIPTION
  Checks host/runner expectations, Docker daemon OSType, and active Docker
  context. Optionally attempts deterministic repair actions and records an
  execution snapshot JSON for diagnostics. `vmmem*` multiplicity is telemetry
  only and never a standalone failure condition.

.PARAMETER ExpectedOsType
  Required expected Docker daemon OSType: windows or linux.

.PARAMETER ExpectedContext
  Required expected Docker context (for example desktop-windows or
  desktop-linux). No implicit default is applied.

.PARAMETER AutoRepair
  When true, mismatch remediation is attempted before failing.

.PARAMETER ManageDockerEngine
  When true on Windows hosts, attempts Docker Desktop engine switch to the
  expected lane OS before re-checking invariants.

.PARAMETER AllowHostEngineMutation
  When true, permits host-level Docker engine mutation actions (service
  restart/shutdown, engine switch, WSL shutdown) during auto-repair. Defaults
  to false so shared self-hosted runners are protected from destructive flips.

.PARAMETER EngineReadyTimeoutSeconds
  Maximum wait time after repair actions before failing readiness.

.PARAMETER EngineReadyPollSeconds
  Poll interval while waiting for Docker daemon readiness.

.PARAMETER CommandTimeoutSeconds
  Timeout in seconds applied to docker/wsl command invocations used by this
  guard.

.PARAMETER SnapshotPath
  Path to write the runtime determinism snapshot JSON.

.PARAMETER GitHubOutputPath
  Optional GitHub output file path.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('windows', 'linux')]
  [string]$ExpectedOsType,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ExpectedContext,

  [bool]$AutoRepair = $true,

  [bool]$ManageDockerEngine = $true,

  [bool]$AllowHostEngineMutation = $false,

  [int]$EngineReadyTimeoutSeconds = 120,

  [int]$EngineReadyPollSeconds = 3,

  [ValidateRange(5, 600)]
  [int]$CommandTimeoutSeconds = 45,

  [Parameter(Mandatory = $true)]
  [string]$SnapshotPath,

  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowNull()][AllowEmptyString()][string]$Value,
    [string]$DestPath
  )

  if ([string]::IsNullOrWhiteSpace($DestPath)) { return }
  $dir = Split-Path -Parent $DestPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $DestPath -PathType Leaf)) {
    New-Item -ItemType File -Path $DestPath -Force | Out-Null
  }
  Add-Content -LiteralPath $DestPath -Value ("{0}={1}" -f $Key, $Value) -Encoding utf8
}

function Split-OutputLines {
  param([AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return @() }
  return @($Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-ProcessWithTimeout {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 45
  )

  $safeTimeout = [math]::Max(5, [int]$TimeoutSeconds)
  $resolvedFilePath = $FilePath
  try {
    $resolvedCommand = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($resolvedCommand -and $resolvedCommand.Source) {
      $resolvedFilePath = [string]$resolvedCommand.Source
    } elseif ($resolvedCommand -and $resolvedCommand.Path) {
      $resolvedFilePath = [string]$resolvedCommand.Path
    }
  } catch {}

  $argText = if ($Arguments -and $Arguments.Count -gt 0) { [string]::Join(' ', $Arguments) } else { '' }
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
  foreach ($arg in @($Arguments)) {
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

function Get-DockerOsProbe {
  param(
    [AllowNull()][string]$Context,
    [int]$TimeoutSeconds = 45
  )

  $probe = [ordered]@{
    context = $Context
    command = ''
    exitCode = $null
    osType = $null
    parseReason = ''
    rawLines = @()
  }
  try {
    $args = @('info', '--format', '{{.OSType}}')
    $normalizedContext = if ([string]::IsNullOrWhiteSpace($Context)) { '' } else { $Context.Trim().ToLowerInvariant() }
    # `default` context can be service-account local; probe without explicit
    # --context to avoid false negatives when desktop-* metadata is absent.
    if (-not [string]::IsNullOrWhiteSpace($normalizedContext) -and $normalizedContext -ne 'default') {
      $args = @('--context', $Context) + $args
    }
    $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments $args -TimeoutSeconds $TimeoutSeconds
    $probe.command = [string]$invoke.command
    if ($invoke.timedOut) {
      $probe.parseReason = 'timeout'
      $probe.rawLines = @(("timeout after {0}s" -f [math]::Max(5, [int]$TimeoutSeconds)))
      return [pscustomobject]$probe
    }

    if ($invoke.exception) {
      throw ([System.Exception]::new([string]$invoke.exception))
    }

    $probe.exitCode = if ($null -eq $invoke.exitCode) { $null } else { [int]$invoke.exitCode }
    $lines = @(@($invoke.stdout) + @($invoke.stderr) | ForEach-Object { [string]$_ })
    $probe.rawLines = @($lines | Select-Object -First 12)

    foreach ($line in $lines) {
      $candidate = $line.Trim().ToLowerInvariant()
      if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
        $probe.osType = $candidate
        $probe.parseReason = 'parsed'
        break
      }
    }

    if ([string]::IsNullOrWhiteSpace([string]$probe.osType)) {
      $joined = (($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n")
      if ([string]::IsNullOrWhiteSpace($joined)) {
        $probe.parseReason = 'empty-output'
      } elseif (
        $joined -match 'Docker Desktop is unable to start' -or
        $joined -match 'Error response from daemon' -or
        $joined -match 'DockerDesktop/Wsl/ExecError' -or
        $joined -match 'Cannot connect to the Docker daemon' -or
        $joined -match 'error during connect'
      ) {
        $probe.parseReason = 'daemon-unavailable'
      } elseif ([int]$probe.exitCode -ne 0) {
        $probe.parseReason = 'docker-info-command-failed'
      } else {
        $probe.parseReason = 'unparseable-output'
      }
    }

    if (
      [string]::IsNullOrWhiteSpace([string]$probe.osType) -and
      -not [string]::IsNullOrWhiteSpace($normalizedContext) -and
      $normalizedContext -ne 'default'
    ) {
      $fallbackInvoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments @('info', '--format', '{{.OSType}}') -TimeoutSeconds $TimeoutSeconds
      if (-not $fallbackInvoke.timedOut -and -not $fallbackInvoke.exception) {
        $fallbackExitCode = if ($null -eq $fallbackInvoke.exitCode) { $null } else { [int]$fallbackInvoke.exitCode }
        $fallbackLines = @(@($fallbackInvoke.stdout) + @($fallbackInvoke.stderr) | ForEach-Object { [string]$_ })
        foreach ($line in $fallbackLines) {
          $candidate = $line.Trim().ToLowerInvariant()
          if ($candidate -eq 'windows' -or $candidate -eq 'linux') {
            $probe.osType = $candidate
            $probe.parseReason = 'parsed-fallback-default-context'
            $probe.exitCode = $fallbackExitCode
            $probe.rawLines = @($fallbackLines | Select-Object -First 12)
            break
          }
        }
      }
    }
  } catch {
    $probe.exitCode = [int]$LASTEXITCODE
    if ($probe.exitCode -eq 0) { $probe.exitCode = $null }
    if ($_.Exception.Message) {
      $probe.rawLines = @([string]$_.Exception.Message)
    }
    $probe.parseReason = 'exception'
  }
  return [pscustomobject]$probe
}

function Format-DockerOsProbeHint {
  param([AllowNull()]$Probe)

  if ($null -eq $Probe) { return '' }
  $parseReason = ''
  if ($Probe.PSObject.Properties['parseReason']) {
    $parseReason = [string]$Probe.parseReason
  }
  if ([string]::IsNullOrWhiteSpace($parseReason)) {
    $parseReason = 'unknown'
  }
  $exitCode = ''
  if ($Probe.PSObject.Properties['exitCode'] -and $null -ne $Probe.exitCode) {
    $exitCode = [string]$Probe.exitCode
  } else {
    $exitCode = '<null>'
  }

  $sample = ''
  if ($Probe.PSObject.Properties['rawLines'] -and $Probe.rawLines) {
    $lines = @($Probe.rawLines | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -gt 0) {
      $sample = $lines[0].Trim()
    }
  }
  if (-not [string]::IsNullOrWhiteSpace($sample) -and $sample.Length -gt 220) {
    $sample = $sample.Substring(0, 220) + '...'
  }

  if ([string]::IsNullOrWhiteSpace($sample)) {
    return ("Docker info probe: parseReason={0}, exitCode={1}" -f $parseReason, $exitCode)
  }
  return ("Docker info probe: parseReason={0}, exitCode={1}, sample='{2}'" -f $parseReason, $exitCode, $sample)
}

function Test-IsDaemonUnavailableProbe {
  param([AllowNull()]$Probe)

  if ($null -eq $Probe) { return $false }
  $parseReason = ''
  if ($Probe.PSObject.Properties['parseReason']) {
    $parseReason = [string]$Probe.parseReason
  }
  $parseReasonNormalized = if ([string]::IsNullOrWhiteSpace($parseReason)) {
    ''
  } else {
    $parseReason.Trim().ToLowerInvariant()
  }
  if ($parseReasonNormalized -in @('daemon-unavailable', 'docker-info-command-failed')) {
    return $true
  }

  if ($Probe.PSObject.Properties['rawLines'] -and $Probe.rawLines) {
    foreach ($line in @($Probe.rawLines)) {
      $text = [string]$line
      if ([string]::IsNullOrWhiteSpace($text)) { continue }
      if (
        $text -match 'Docker Desktop is unable to start' -or
        $text -match 'Cannot connect to the Docker daemon' -or
        $text -match 'error during connect' -or
        $text -match 'Error response from daemon'
      ) {
        return $true
      }
    }
  }

  return $false
}

function Get-ProbeParseReasonNormalized {
  param([AllowNull()]$Probe)

  if ($null -eq $Probe) { return '' }
  $parseReason = ''
  if ($Probe.PSObject.Properties['parseReason']) {
    $parseReason = [string]$Probe.parseReason
  }
  if ([string]::IsNullOrWhiteSpace($parseReason)) {
    return ''
  }
  return $parseReason.Trim().ToLowerInvariant()
}

function Resolve-RuntimeFailureClass {
  param(
    [AllowNull()]$Probe,
    [AllowEmptyString()][string]$ObservedOsType,
    [bool]$HostAlignmentFailure = $false,
    [bool]$ContextOrOsMismatch = $false
  )

  if ($HostAlignmentFailure) {
    return 'host-mismatch'
  }

  $parseReason = Get-ProbeParseReasonNormalized -Probe $Probe
  if ($parseReason -in @('daemon-unavailable', 'docker-info-command-failed')) {
    return 'daemon-unavailable'
  }

  if ([string]::IsNullOrWhiteSpace($ObservedOsType)) {
    if ($parseReason -in @('empty-output', 'unparseable-output', 'exception', 'timeout', 'parsed-fallback-default-context')) {
      return 'parse-defect'
    }
    if (-not [string]::IsNullOrWhiteSpace($parseReason)) {
      return 'parse-defect'
    }
  }

  if ($ContextOrOsMismatch) {
    return 'context-os-mismatch'
  }

  return 'runtime-mismatch'
}

function Get-DockerOsType {
  param([AllowNull()][string]$Context)
  $probe = Get-DockerOsProbe -Context $Context -TimeoutSeconds $CommandTimeoutSeconds
  if ($null -eq $probe) {
    return $null
  }
  return [string]$probe.osType
}

function Get-DockerContext {
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments @('context', 'show') -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode -or [int]$invoke.exitCode -ne 0) {
      return $null
    }
    $stdoutLines = @($invoke.stdout | ForEach-Object { [string]$_ })
    $output = if ($stdoutLines.Count -gt 0) { [string]$stdoutLines[0] } else { '' }
    if ([string]::IsNullOrWhiteSpace($output)) {
      return $null
    }
    return $output.Trim()
  } catch {
    return $null
  }
}

function Test-ContextAccepted {
  param(
    [AllowNull()][string]$ObservedContext,
    [Parameter(Mandatory = $true)][string]$ExpectedContext,
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$ExpectedOsType,
    [AllowNull()][string]$ObservedOsType
  )

  if ([string]::IsNullOrWhiteSpace($ObservedContext)) {
    return $false
  }

  $observed = $ObservedContext.Trim().ToLowerInvariant()
  $expected = $ExpectedContext.Trim().ToLowerInvariant()

  if ($observed -eq $expected) {
    return $true
  }

  # Some runners keep the active context as "default" while docker info reports
  # the expected lane OSType. Treat that alias as deterministic-equivalent.
  if ($observed -eq 'default' -and -not [string]::IsNullOrWhiteSpace($ObservedOsType)) {
    return ($ObservedOsType.Trim().ToLowerInvariant() -eq $ExpectedOsType)
  }

  return $false
}

function Get-DockerContexts {
  $rows = New-Object System.Collections.Generic.List[object]
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments @('context', 'ls', '--format', '{{json .}}') -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode -or [int]$invoke.exitCode -ne 0) {
      return @()
    }
    $output = @($invoke.stdout)
    if (-not $output) {
      return @()
    }
    foreach ($line in @($output)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        $rows.Add($obj) | Out-Null
      } catch {}
    }
  } catch {}
  return $rows.ToArray()
}

function Get-WslDistributions {
  if (-not $IsWindows) { return @() }

  $items = New-Object System.Collections.Generic.List[object]
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'wsl' -Arguments @('-l', '-v') -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode -or [int]$invoke.exitCode -ne 0) {
      return @()
    }

    $output = @($invoke.stdout)
    if (-not $output) {
      return @()
    }

    $lines = @($output | ForEach-Object { [string]$_ })
    if ($lines.Count -le 1) { return @() }
    foreach ($line in $lines | Select-Object -Skip 1) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $clean = $line -replace [char]0, ''
      $isDefault = $clean.TrimStart().StartsWith('*')
      $tokenized = $clean.TrimStart('*', ' ') -split '\s{2,}'
      if ($tokenized.Count -lt 1) { continue }
      $name = $tokenized[0].Trim()
      $state = if ($tokenized.Count -ge 2) { $tokenized[1].Trim() } else { '' }
      $version = if ($tokenized.Count -ge 3) { $tokenized[2].Trim() } else { '' }
      $items.Add([ordered]@{
        name      = $name
        state     = $state
        version   = $version
        isDefault = $isDefault
      }) | Out-Null
    }
  } catch {}
  return $items.ToArray()
}

function Get-VmmemProcesses {
  $items = New-Object System.Collections.Generic.List[object]
  try {
    $procs = Get-Process -Name vmmem,vmmemWSL -ErrorAction SilentlyContinue
    foreach ($proc in @($procs)) {
      $items.Add([ordered]@{
        name     = $proc.ProcessName
        id       = $proc.Id
        cpu      = [double]$proc.CPU
        wsMb     = [math]::Round(($proc.WorkingSet64 / 1MB), 2)
        startUtc = if ($proc.StartTime) { $proc.StartTime.ToUniversalTime().ToString('o') } else { $null }
      }) | Out-Null
    }
  } catch {}
  return $items.ToArray()
}

function Get-DockerBackendProcesses {
  $items = New-Object System.Collections.Generic.List[object]
  if (-not $IsWindows) { return @() }

  try {
    $procs = Get-Process -Name 'com.docker.backend','com.docker.proxy','Docker Desktop' -ErrorAction SilentlyContinue
    foreach ($proc in @($procs)) {
      $items.Add([ordered]@{
        name = $proc.ProcessName
        id = $proc.Id
        cpu = [double]$proc.CPU
        wsMb = [math]::Round(($proc.WorkingSet64 / 1MB), 2)
        startUtc = if ($proc.StartTime) { $proc.StartTime.ToUniversalTime().ToString('o') } else { $null }
      }) | Out-Null
    }
  } catch {}

  return $items.ToArray()
}

function Get-RunningContainers {
  $items = New-Object System.Collections.Generic.List[object]
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments @('ps', '--format', '{{json .}}') -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode -or [int]$invoke.exitCode -ne 0) {
      return @()
    }
    $output = @($invoke.stdout)
    if (-not $output) {
      return @()
    }
    foreach ($line in @($output)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
        $items.Add($obj) | Out-Null
      } catch {}
    }
  } catch {}
  return $items.ToArray()
}

function Invoke-DockerContextUse {
  param([Parameter(Mandatory = $true)][string]$Context)
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'docker' -Arguments @('context', 'use', $Context) -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode) {
      return $false
    }
    return ([int]$invoke.exitCode -eq 0)
  } catch {
    return $false
  }
}

function Invoke-WslShutdown {
  if (-not $IsWindows) { return $false }
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath 'wsl' -Arguments @('--shutdown') -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut -or $invoke.exception -or $null -eq $invoke.exitCode) {
      return $false
    }
    return ([int]$invoke.exitCode -eq 0)
  } catch {
    return $false
  }
}

function Resolve-DockerCliPath {
  if (-not $IsWindows) { return $null }
  $candidates = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'),
    (Join-Path $env:ProgramFiles 'Docker\Docker\com.docker.cli.exe'),
    (Join-Path $env:ProgramW6432 'Docker\Docker\DockerCli.exe'),
    (Join-Path $env:ProgramW6432 'Docker\Docker\com.docker.cli.exe')
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  return $null
}

function Invoke-DockerServiceRecovery {
  [CmdletBinding()]
  param()

  $result = [ordered]@{
    attempted = $false
    steps = @()
  }

  if (-not $IsWindows) {
    return [pscustomobject]$result
  }

  $result.attempted = $true
  $steps = New-Object System.Collections.Generic.List[string]

  foreach ($serviceName in @('com.docker.service', 'docker')) {
    try {
      $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
      if ($null -eq $svc) {
        $steps.Add(("service {0}: not-found" -f $serviceName)) | Out-Null
        continue
      }

      if ($svc.Status -ne 'Running') {
        Start-Service -Name $serviceName -ErrorAction Stop
        $steps.Add(("service {0}: started" -f $serviceName)) | Out-Null
      } else {
        Restart-Service -Name $serviceName -Force -ErrorAction Stop
        $steps.Add(("service {0}: restarted" -f $serviceName)) | Out-Null
      }
    } catch {
      $steps.Add(("service {0}: failed ({1})" -f $serviceName, $_.Exception.Message)) | Out-Null
    }
  }

  $dockerCli = Resolve-DockerCliPath
  if ([string]::IsNullOrWhiteSpace($dockerCli)) {
    $steps.Add('docker cli shutdown: docker-cli-not-found') | Out-Null
  } else {
    try {
      $invoke = Invoke-ProcessWithTimeout -FilePath $dockerCli -Arguments @('-Shutdown') -TimeoutSeconds $CommandTimeoutSeconds
      if ($invoke.timedOut) {
        $steps.Add(("docker cli shutdown: timeout after {0}s" -f [int]$CommandTimeoutSeconds)) | Out-Null
      } elseif ($invoke.exception) {
        $steps.Add(("docker cli shutdown: failed ({0})" -f [string]$invoke.exception)) | Out-Null
      } else {
        $exitCode = if ($null -eq $invoke.exitCode) { '<null>' } else { [string][int]$invoke.exitCode }
        $steps.Add(("docker cli shutdown: exit={0}" -f $exitCode)) | Out-Null
      }
    } catch {
      $steps.Add(("docker cli shutdown: failed ({0})" -f $_.Exception.Message)) | Out-Null
    }
  }

  $result.steps = @($steps.ToArray())
  return [pscustomobject]$result
}

function Invoke-DockerEngineSwitch {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$TargetOsType
  )

  $result = [ordered]@{
    attempted = $false
    success = $false
    command = ''
    message = ''
  }
  if (-not $IsWindows) {
    $result.message = 'engine-switch-not-applicable-non-windows-host'
    return $result
  }
  $dockerCli = Resolve-DockerCliPath
  if ([string]::IsNullOrWhiteSpace($dockerCli)) {
    $result.message = 'docker-cli-not-found'
    return $result
  }

  $switchArg = if ($TargetOsType -eq 'windows') { '-SwitchWindowsEngine' } else { '-SwitchLinuxEngine' }
  $result.attempted = $true
  $result.command = "$dockerCli $switchArg"
  try {
    $invoke = Invoke-ProcessWithTimeout -FilePath $dockerCli -Arguments @($switchArg) -TimeoutSeconds $CommandTimeoutSeconds
    if ($invoke.timedOut) {
      $result.success = $false
      $result.message = ("timeout after {0}s" -f [int]$CommandTimeoutSeconds)
    } elseif ($invoke.exception) {
      $result.success = $false
      $result.message = [string]$invoke.exception
    } else {
      $exitCode = if ($null -eq $invoke.exitCode) { -1 } else { [int]$invoke.exitCode }
      $result.success = ($exitCode -eq 0)
      $output = @(@($invoke.stdout) + @($invoke.stderr))
      if ($output) {
        $result.message = (($output | ForEach-Object { [string]$_ }) -join '; ')
      } else {
        $result.message = "exit=$exitCode"
      }
    }
  } catch {
    $result.success = $false
    $result.message = $_.Exception.Message
  }
  return $result
}

function Get-ManualRemediationSteps {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$TargetOsType,
    [Parameter(Mandatory = $true)][string]$ExpectedContext
  )

  $steps = New-Object System.Collections.Generic.List[string]
  $steps.Add(("docker context use {0}" -f $ExpectedContext)) | Out-Null
  if ($IsWindows) {
    $dockerCli = Resolve-DockerCliPath
    if (-not [string]::IsNullOrWhiteSpace($dockerCli)) {
      $switchArg = if ($TargetOsType -eq 'windows') { '-SwitchWindowsEngine' } else { '-SwitchLinuxEngine' }
      $steps.Add(('"{0}" {1}' -f $dockerCli, $switchArg)) | Out-Null
    }
    if ($TargetOsType -eq 'windows') {
      $steps.Add('wsl --shutdown') | Out-Null
    }
  }
  return ,($steps.ToArray())
}

function Wait-DockerEngineReady {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$ExpectedOsType,
    [Parameter(Mandatory = $true)][string]$FallbackContext,
    [int]$TimeoutSeconds = 120,
    [int]$PollSeconds = 3
  )

  $started = Get-Date
  $deadline = $started.AddSeconds([math]::Max(10, $TimeoutSeconds))
  $poll = [math]::Max(1, $PollSeconds)
  $attempts = 0
  while ((Get-Date) -lt $deadline) {
    $attempts++
    $context = Get-DockerContext
    if ([string]::IsNullOrWhiteSpace($context)) {
      $context = $FallbackContext
    }
    $probe = Get-DockerOsProbe -Context $context -TimeoutSeconds $CommandTimeoutSeconds
    $osType = [string]$probe.osType
    if ($osType -eq $ExpectedOsType) {
      return [ordered]@{
        ready = $true
        attempts = $attempts
        context = $context
        osType = $osType
        osProbe = $probe
      }
    }
    Start-Sleep -Seconds $poll
  }
  $finalContext = Get-DockerContext
  if ([string]::IsNullOrWhiteSpace($finalContext)) {
    $finalContext = $FallbackContext
  }
  $finalProbe = Get-DockerOsProbe -Context $finalContext -TimeoutSeconds $CommandTimeoutSeconds
  $finalOsType = [string]$finalProbe.osType
  return [ordered]@{
    ready = $false
    attempts = $attempts
    context = $finalContext
    osType = $finalOsType
    osProbe = $finalProbe
  }
}

$effectiveExpectedContext = $ExpectedContext.Trim()
if ([string]::IsNullOrWhiteSpace($effectiveExpectedContext)) {
  throw 'ExpectedContext must be provided explicitly and cannot be empty.'
}

$snapshotResolved = if ([System.IO.Path]::IsPathRooted($SnapshotPath)) {
  [System.IO.Path]::GetFullPath($SnapshotPath)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $SnapshotPath))
}
$snapshotDir = Split-Path -Parent $snapshotResolved
if ($snapshotDir -and -not (Test-Path -LiteralPath $snapshotDir -PathType Container)) {
  New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
}

$resultStatus = 'ok'
$reason = ''
$resultFailureClass = 'none'
$repairActions = New-Object System.Collections.Generic.List[string]
$initialDockerOsProbe = $null
$fallbackDockerOsProbe = $null
$lastDockerOsProbe = $null

$runnerOsRaw = $env:RUNNER_OS
$runnerOsNormalized = if ([string]::IsNullOrWhiteSpace($runnerOsRaw)) { '' } else { $runnerOsRaw.Trim().ToLowerInvariant() }
$hostIsWindows = [bool]$IsWindows
$hostAlignmentOk = $true
if ($ExpectedOsType -eq 'windows') {
  if (-not $hostIsWindows) {
    $hostAlignmentOk = $false
    $reason = 'Windows container lanes require a Windows host.'
  }
  if (-not [string]::IsNullOrWhiteSpace($runnerOsNormalized) -and $runnerOsNormalized -ne 'windows') {
    $hostAlignmentOk = $false
    $reason = "RUNNER_OS is '$runnerOsRaw', expected Windows."
  }
} elseif (-not [string]::IsNullOrWhiteSpace($runnerOsNormalized) -and $runnerOsNormalized -ne 'linux') {
  $hostAlignmentOk = $false
  $reason = "RUNNER_OS is '$runnerOsRaw', expected Linux for linux lane."
}

$observedContext = Get-DockerContext
$initialDockerOsProbe = Get-DockerOsProbe -Context $observedContext -TimeoutSeconds $CommandTimeoutSeconds
$observedOsType = [string]$initialDockerOsProbe.osType
$lastDockerOsProbe = $initialDockerOsProbe
if ([string]::IsNullOrWhiteSpace($observedOsType)) {
  $fallbackDockerOsProbe = Get-DockerOsProbe -Context $effectiveExpectedContext -TimeoutSeconds $CommandTimeoutSeconds
  $observedOsType = [string]$fallbackDockerOsProbe.osType
  $lastDockerOsProbe = $fallbackDockerOsProbe
}

if (-not $hostAlignmentOk) {
  $resultStatus = 'mismatch-failed'
  $resultFailureClass = Resolve-RuntimeFailureClass -Probe $lastDockerOsProbe -ObservedOsType $observedOsType -HostAlignmentFailure:$true
} else {
  if ([string]::IsNullOrWhiteSpace($observedOsType)) {
    $resultStatus = 'mismatch-failed'
    $resultFailureClass = Resolve-RuntimeFailureClass -Probe $lastDockerOsProbe -ObservedOsType $observedOsType
    $probeHint = Format-DockerOsProbeHint -Probe $lastDockerOsProbe
    $manualSteps = Get-ManualRemediationSteps -TargetOsType $ExpectedOsType -ExpectedContext $effectiveExpectedContext
    $manualText = if ($manualSteps.Count -gt 0) { [string]::Join('; ', $manualSteps) } else { 'n/a' }
    Write-Host ("[runtime-determinism] mismatch detected expectedContext={0} observedContext={1} expectedOs={2} observedOs=<empty>" -f $effectiveExpectedContext, ($observedContext ?? '<null>'), $ExpectedOsType) -ForegroundColor Yellow
    $reason = ("Runtime invariant mismatch. observed Docker OSType is empty for context={0}; expected os={1}, context={2}. Manual remediation: {3}. {4}" -f ($observedContext ?? '<null>'), $ExpectedOsType, $effectiveExpectedContext, $manualText, $probeHint)
  } else {
    $osMismatch = ($observedOsType -ne $ExpectedOsType)
    $contextMismatch = -not (Test-ContextAccepted `
      -ObservedContext $observedContext `
      -ExpectedContext $effectiveExpectedContext `
      -ExpectedOsType $ExpectedOsType `
      -ObservedOsType $observedOsType)

    if ($osMismatch -or $contextMismatch) {
      Write-Host ("[runtime-determinism] mismatch detected expectedContext={0} observedContext={1} expectedOs={2} observedOs={3}" -f $effectiveExpectedContext, ($observedContext ?? '<null>'), $ExpectedOsType, ($observedOsType ?? '<null>')) -ForegroundColor Yellow
      if ($AutoRepair) {
      $daemonUnavailable = (Test-IsDaemonUnavailableProbe -Probe $initialDockerOsProbe) -or (Test-IsDaemonUnavailableProbe -Probe $fallbackDockerOsProbe)
      $hostMutationAllowed = ($ManageDockerEngine -and $hostIsWindows -and $AllowHostEngineMutation)
      if ($ManageDockerEngine -and $hostIsWindows -and $osMismatch -and -not $AllowHostEngineMutation) {
        $repairActions.Add('host engine mutation skipped: AllowHostEngineMutation=false') | Out-Null
      }
      if ($hostMutationAllowed -and $osMismatch -and $daemonUnavailable) {
        Write-Host '[runtime-determinism] attempting docker service recovery' -ForegroundColor DarkGray
        $serviceRecovery = Invoke-DockerServiceRecovery
        if ($serviceRecovery -and $serviceRecovery.PSObject.Properties['steps'] -and $serviceRecovery.steps) {
          foreach ($stepMessage in @($serviceRecovery.steps)) {
            $repairActions.Add(("docker service recovery: {0}" -f [string]$stepMessage)) | Out-Null
          }
        } else {
          $repairActions.Add('docker service recovery: no-actions') | Out-Null
        }
      }
      if ($contextMismatch) {
        Write-Host ("[runtime-determinism] attempting: docker context use {0}" -f $effectiveExpectedContext) -ForegroundColor DarkGray
        $ok = Invoke-DockerContextUse -Context $effectiveExpectedContext
        $ctxResult = if ($ok) { 'ok' } else { 'failed' }
        $repairActions.Add(("docker context use {0}: {1}" -f $effectiveExpectedContext, $ctxResult)) | Out-Null
      }
      if ($hostMutationAllowed -and $osMismatch) {
        Write-Host ("[runtime-determinism] attempting docker engine switch to {0}" -f $ExpectedOsType) -ForegroundColor DarkGray
        $switchResult = Invoke-DockerEngineSwitch -TargetOsType $ExpectedOsType
        $switchStatus = if ([bool]$switchResult.success) { 'ok' } else { 'failed' }
        $switchMessage = if ([string]::IsNullOrWhiteSpace([string]$switchResult.message)) { '' } else { [string]$switchResult.message }
        $repairActions.Add(("docker engine switch to {0}: {1} {2}" -f $ExpectedOsType, $switchStatus, $switchMessage).Trim()) | Out-Null
      }
      if ($hostMutationAllowed -and $ExpectedOsType -eq 'windows' -and $osMismatch) {
        Write-Host '[runtime-determinism] attempting: wsl --shutdown' -ForegroundColor DarkGray
        $wslOk = Invoke-WslShutdown
        $wslResult = if ($wslOk) { 'ok' } else { 'failed-or-not-applicable' }
        $repairActions.Add(("wsl --shutdown: {0}" -f $wslResult)) | Out-Null
      }

      Write-Host ("[runtime-determinism] attempting: docker context use {0} (post-switch)" -f $effectiveExpectedContext) -ForegroundColor DarkGray
      $postSwitchContext = Invoke-DockerContextUse -Context $effectiveExpectedContext
      $postSwitchStatus = if ($postSwitchContext) { 'ok' } else { 'failed' }
      $repairActions.Add(("docker context use {0} (post-switch): {1}" -f $effectiveExpectedContext, $postSwitchStatus)) | Out-Null

      Write-Host ("[runtime-determinism] waiting for docker engine readiness (timeout={0}s poll={1}s)" -f [int]$EngineReadyTimeoutSeconds, [int]$EngineReadyPollSeconds) -ForegroundColor DarkGray
      $waitResult = Wait-DockerEngineReady `
        -ExpectedOsType $ExpectedOsType `
        -FallbackContext $effectiveExpectedContext `
        -TimeoutSeconds $EngineReadyTimeoutSeconds `
        -PollSeconds $EngineReadyPollSeconds
      $waitStatus = if ([bool]$waitResult.ready) { 'ready' } else { 'timeout' }
      $waitProbeHint = Format-DockerOsProbeHint -Probe $waitResult.osProbe
      $repairActions.Add(("docker engine readiness: {0} attempts={1} observed={2}/{3} {4}" -f $waitStatus, [int]$waitResult.attempts, ([string]$waitResult.osType ?? '<null>'), ([string]$waitResult.context ?? '<null>'), $waitProbeHint).Trim()) | Out-Null

      $recheckedContext = [string]$waitResult.context
      $recheckedOsType = [string]$waitResult.osType
      if ($waitResult.osProbe) {
        $lastDockerOsProbe = $waitResult.osProbe
      }
      if ([string]::IsNullOrWhiteSpace($recheckedContext)) {
        $recheckedContext = Get-DockerContext
      }
      if ([string]::IsNullOrWhiteSpace($recheckedOsType)) {
        $recheckedProbe = Get-DockerOsProbe -Context $recheckedContext -TimeoutSeconds $CommandTimeoutSeconds
        $recheckedOsType = [string]$recheckedProbe.osType
        if ($recheckedProbe) {
          $lastDockerOsProbe = $recheckedProbe
        }
      }
      if ([string]::IsNullOrWhiteSpace($recheckedOsType)) {
        $recheckedFallbackProbe = Get-DockerOsProbe -Context $effectiveExpectedContext -TimeoutSeconds $CommandTimeoutSeconds
        $recheckedOsType = [string]$recheckedFallbackProbe.osType
        if ($recheckedFallbackProbe) {
          $lastDockerOsProbe = $recheckedFallbackProbe
        }
      }

      $osMismatchAfter = [string]::IsNullOrWhiteSpace($recheckedOsType) -or ($recheckedOsType -ne $ExpectedOsType)
      $contextMismatchAfter = -not (Test-ContextAccepted `
        -ObservedContext $recheckedContext `
        -ExpectedContext $effectiveExpectedContext `
        -ExpectedOsType $ExpectedOsType `
        -ObservedOsType $recheckedOsType)

      $observedOsType = $recheckedOsType
      $observedContext = $recheckedContext

      if ($osMismatchAfter -or $contextMismatchAfter) {
        $manualSteps = Get-ManualRemediationSteps -TargetOsType $ExpectedOsType -ExpectedContext $effectiveExpectedContext
        $manualText = if ($manualSteps.Count -gt 0) { [string]::Join('; ', $manualSteps) } else { 'n/a' }
        $probeHint = Format-DockerOsProbeHint -Probe $lastDockerOsProbe
        $resultStatus = 'mismatch-failed'
        $resultFailureClass = Resolve-RuntimeFailureClass `
          -Probe $lastDockerOsProbe `
          -ObservedOsType $observedOsType `
          -ContextOrOsMismatch:($osMismatchAfter -or $contextMismatchAfter)
        $reason = ("Runtime invariant mismatch after repair. expected os={0}, context={1}; observed os={2}, context={3}. Manual remediation: {4}. {5}" -f $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>'), $manualText, $probeHint)
        } else {
          $resultStatus = 'mismatch-repaired'
          $resultFailureClass = 'none'
        }
      } else {
        $manualSteps = Get-ManualRemediationSteps -TargetOsType $ExpectedOsType -ExpectedContext $effectiveExpectedContext
        $manualText = if ($manualSteps.Count -gt 0) { [string]::Join('; ', $manualSteps) } else { 'n/a' }
        $probeHint = Format-DockerOsProbeHint -Probe $lastDockerOsProbe
        $resultStatus = 'mismatch-failed'
        $resultFailureClass = Resolve-RuntimeFailureClass `
          -Probe $lastDockerOsProbe `
          -ObservedOsType $observedOsType `
          -ContextOrOsMismatch:$true
        $reason = ("Runtime invariant mismatch. expected os={0}, context={1}; observed os={2}, context={3}. Manual remediation: {4}. {5}" -f $ExpectedOsType, $effectiveExpectedContext, ($observedOsType ?? '<null>'), ($observedContext ?? '<null>'), $manualText, $probeHint)
      }
    }
  }
}

$snapshot = [ordered]@{
  schema = 'docker-runtime-determinism@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  expected = [ordered]@{
    osType = $ExpectedOsType
    context = $effectiveExpectedContext
    autoRepair = [bool]$AutoRepair
    manageDockerEngine = [bool]$ManageDockerEngine
    allowHostEngineMutation = [bool]$AllowHostEngineMutation
    engineReadyTimeoutSeconds = [int]$EngineReadyTimeoutSeconds
    engineReadyPollSeconds = [int]$EngineReadyPollSeconds
    commandTimeoutSeconds = [int]$CommandTimeoutSeconds
  }
  host = [ordered]@{
    isWindows = $hostIsWindows
    runnerOs = $runnerOsRaw
    alignmentOk = $hostAlignmentOk
  }
  observed = [ordered]@{
    osType = $observedOsType
    context = $observedContext
    dockerOsProbe = [ordered]@{
      initial = $initialDockerOsProbe
      fallback = $fallbackDockerOsProbe
      last = $lastDockerOsProbe
    }
    availableContexts = @(Get-DockerContexts)
    runningContainers = @(Get-RunningContainers)
    wslDistributions = @(Get-WslDistributions)
    vmmemProcesses = @(Get-VmmemProcesses)
    dockerBackendProcesses = @(Get-DockerBackendProcesses)
  }
  repairActions = @($repairActions.ToArray())
  result = [ordered]@{
    status = $resultStatus
    reason = $reason
    failureClass = $resultFailureClass
    probeParseReason = (Get-ProbeParseReasonNormalized -Probe $lastDockerOsProbe)
  }
}

$snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $snapshotResolved -Encoding utf8

Write-GitHubOutput -Key 'runtime-status' -Value $resultStatus -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'docker-ostype' -Value ($observedOsType ?? '') -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'docker-context' -Value ($observedContext ?? '') -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'runtime-failure-class' -Value ($resultFailureClass ?? '') -DestPath $GitHubOutputPath
$dockerOsParseReason = ''
if ($lastDockerOsProbe -and $lastDockerOsProbe.PSObject.Properties['parseReason']) {
  $dockerOsParseReason = [string]$lastDockerOsProbe.parseReason
}
Write-GitHubOutput -Key 'docker-ostype-parse-reason' -Value $dockerOsParseReason -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'snapshot-path' -Value $snapshotResolved -DestPath $GitHubOutputPath

Write-Host ("[runtime-determinism] status={0} expectedContext={1} observedContext={2} expectedOs={3} observedOs={4} snapshot={5}" -f $resultStatus, $effectiveExpectedContext, ($observedContext ?? '<null>'), $ExpectedOsType, ($observedOsType ?? '<null>'), $snapshotResolved)

if ($resultStatus -eq 'mismatch-failed') {
  throw ($reason ?? 'Runtime determinism check failed.')
}
