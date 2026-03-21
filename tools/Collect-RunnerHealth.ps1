[CmdletBinding()]
param(
  [string]$Enterprise = '',
  [string]$Repo,
  [string]$ServiceName = 'actions.runner.enterprises-labview-community-ci-cd.research',
  [string]$ResultsDir = 'tests/results',
  [switch]$AppendSummary,
  [switch]$EmitJson,
  [switch]$IncludeGhApi
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Try-GetCommand {
  param([string]$Name)
  try { return (Get-Command -Name $Name -ErrorAction Stop) } catch { return $null }
}

function Split-OutputLines {
  param([AllowNull()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  return @($Text -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Invoke-ToolCapture {
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  try {
    $raw = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($raw | ForEach-Object { [string]$_ })
    return [ordered]@{
      exitCode = [int]$exitCode
      lines = $lines
      text = ($lines -join "`n")
    }
  } catch {
    return [ordered]@{
      exitCode = $null
      lines = @([string]$_.Exception.Message)
      text = [string]$_.Exception.Message
    }
  }
}

function Get-RepoSlug {
  if ($Repo) { return $Repo }
  try {
    $url = (& git remote get-url origin 2>$null).Trim()
    if ($url -match 'github.com[:/](.+?)(\.git)?$') { return $Matches[1] }
  } catch {}
  return $null
}

function Get-DockerHealthSnapshot {
  $dockerCommand = Try-GetCommand docker
  $services = @()
  $processes = @()
  $currentContext = $null
  $contexts = @()
  $infoProbe = [ordered]@{
    exitCode = $null
    osType = $null
    sample = @()
  }

  if ($IsWindows) {
    foreach ($serviceName in @('docker', 'com.docker.service')) {
      $svcObj = $null
      $svcCim = $null
      try { $svcObj = Get-Service -Name $serviceName -ErrorAction Stop } catch {}
      try { $svcCim = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop } catch {}
      if ($svcObj -or $svcCim) {
        $services += [pscustomobject]@{
          name = $serviceName
          found = $true
          status = if ($svcObj) { [string]$svcObj.Status } else { $null }
          startType = if ($svcCim) { [string]$svcCim.StartMode } else { $null }
        }
      } else {
        $services += [pscustomobject]@{
          name = $serviceName
          found = $false
          status = $null
          startType = $null
        }
      }
    }

    $processes = @(
      Get-Process -Name 'dockerd','com.docker.backend','com.docker.proxy','Docker Desktop' -ErrorAction SilentlyContinue |
        Select-Object Name, Id, StartTime
    )
  }

  if (-not $dockerCommand) {
    return [ordered]@{
      commandAvailable = $false
      dockerHost = if ([string]::IsNullOrWhiteSpace($env:DOCKER_HOST)) { $null } else { [string]$env:DOCKER_HOST }
      currentContext = $null
      contexts = @()
      infoProbe = $infoProbe
      services = $services
      processes = $processes
    }
  }

  $contextShow = Invoke-ToolCapture -FilePath $dockerCommand.Source -Arguments @('context', 'show')
  if ($contextShow.lines.Count -gt 0) {
    $currentContext = [string]($contextShow.lines | Select-Object -First 1)
  }

  $contextList = Invoke-ToolCapture -FilePath $dockerCommand.Source -Arguments @('context', 'ls', '--format', '{{json .}}')
  foreach ($line in @($contextList.lines)) {
    try {
      $contexts += ($line | ConvertFrom-Json -ErrorAction Stop)
    } catch {}
  }

  $infoProbeResult = Invoke-ToolCapture -FilePath $dockerCommand.Source -Arguments @('info', '--format', '{{.OSType}}')
  $osType = $null
  foreach ($line in @($infoProbeResult.lines)) {
    $candidate = [string]$line
    if ($candidate -match '^(windows|linux)$') {
      $osType = $candidate.ToLowerInvariant()
      break
    }
  }
  $infoProbe = [ordered]@{
    exitCode = $infoProbeResult.exitCode
    osType = $osType
    sample = @($infoProbeResult.lines | Select-Object -First 6)
  }

  return [ordered]@{
    commandAvailable = $true
    dockerHost = if ([string]::IsNullOrWhiteSpace($env:DOCKER_HOST)) { $null } else { [string]$env:DOCKER_HOST }
    currentContext = $currentContext
    contexts = @($contexts)
    infoProbe = $infoProbe
    services = @($services)
    processes = @($processes)
  }
}

$now = Get-Date
$osInfo = $PSVersionTable.OS
$psv = $PSVersionTable.PSVersion.ToString()
$repoSlug = Get-RepoSlug
$workRoot = (Resolve-Path .).Path
$drive = $null
try { $drive = Get-PSDrive -Name ($workRoot.Substring(0,1)) -ErrorAction SilentlyContinue } catch {}

# Service probe (Windows and Linux)
$service = $null
if ($IsWindows) {
  $svcObj = $null; $svcCim = $null
  try { $svcObj = Get-Service -Name $ServiceName -ErrorAction Stop } catch {}
  try { $svcCim = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction Stop } catch {}
  if ($svcObj -or $svcCim) {
    $service = [ordered]@{
      name      = $ServiceName
      found     = $true
      status    = $svcObj.Status.ToString()
      startType = $svcCim.StartMode
      account   = $svcCim.StartName
      path      = $svcCim.PathName
    }
  } else {
    $service = @{ name = $ServiceName; found = $false }
  }
} else {
  # Linux systemd best-effort
  $systemctl = Try-GetCommand systemctl
  if ($systemctl) {
    try {
      $status = & $systemctl.Source show -p Id -p ActiveState -p FragmentPath "$ServiceName" 2>$null
      if ($LASTEXITCODE -eq 0 -and $status) {
        $kv = @{}
        foreach ($line in ($status -split "`n")) { if ($line -match '^(\w+?)=(.*)$') { $kv[$Matches[1]] = $Matches[2] } }
        $service = @{ name = $ServiceName; found = $true; active = $kv['ActiveState']; path = $kv['FragmentPath'] }
      } else { $service = @{ name = $ServiceName; found = $false } }
    } catch { $service = @{ name = $ServiceName; found = $false } }
  } else { $service = @{ name = $ServiceName; found = $false } }
}

# Queue snapshot via gh (optional)
$queue = @{}
if ($IncludeGhApi) {
  $gh = Try-GetCommand gh
  if ($gh -and $repoSlug) {
    try {
      $wfRunsRaw = & $gh.Source api "repos/$repoSlug/actions/workflows/ci-orchestrated.yml/runs?per_page=15" 2>$null
      $wfRuns = $wfRunsRaw | ConvertFrom-Json
      $queue.repo = [ordered]@{
        total   = $wfRuns.total_count
        queued  = ($wfRuns.workflow_runs | Where-Object { $_.status -eq 'queued' }).Count
        running = ($wfRuns.workflow_runs | Where-Object { $_.status -eq 'in_progress' }).Count
      }
    } catch { $queue.repo_error = $_.Exception.Message }
    if ($Enterprise) {
      try {
        $runnersRaw = & $gh.Source api "enterprises/$Enterprise/actions/runners?per_page=100" 2>$null
        $runners = $runnersRaw | ConvertFrom-Json
        $queue.enterprise = [ordered]@{
          online = ($runners.runners | Where-Object { $_.status -eq 'online' }).Count
          busy   = ($runners.runners | Where-Object { $_.busy }).Count
        }
      } catch { $queue.enterprise_error = $_.Exception.Message }
    }
  } else { $queue.repo_error = 'gh unavailable or repo slug missing' }
}

# Processes snapshot (best effort)
$procs = Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -in 'pwsh','LVCompare','LabVIEW' } |
  Select-Object Name,Id,StartTime,CPU,MainWindowTitle
$docker = Get-DockerHealthSnapshot

$health = [ordered]@{
  schema      = 'runner-health/v1'
  generatedAt = $now.ToString('o')
  env         = @{ os = $osInfo; ps = $psv; repo = $repoSlug; workspace = $workRoot }
  workspace   = @{ diskFreeGB = if ($drive) { [math]::Round($drive.Free/1GB,2) } else { $null } }
  service     = $service
  docker      = $docker
  queue       = $queue
  processes   = $procs
}

if ($EmitJson) {
  $outDir = Join-Path $ResultsDir '_agent'
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  ($health | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $outDir 'runner-health.json') -Encoding utf8
}

if ($AppendSummary -and $env:GITHUB_STEP_SUMMARY) {
  $lines = @(
    '### Runner Health'
    "- Service: $($health.service.name) (found=$($health.service.found))"
  )

  $serviceStatusProp = $null
  if ($health.service) {
    $serviceStatusProp = $health.service.PSObject.Properties['status']
  }
  if ($serviceStatusProp) {
    $serviceStatus = $serviceStatusProp.Value
    if ($serviceStatus) {
      $lines += "- Service Status: $serviceStatus"
    }
  }

  $lines += @(
    "- OS/PS: $($osInfo) / PS $($psv)"
    "- Disk free: $($health.workspace.diskFreeGB) GB"
  )

  $dockerInfo = $health.docker
  if ($dockerInfo) {
    $lines += ("- Docker command available: {0}" -f $dockerInfo.commandAvailable)
    $lines += ("- Docker context: {0}" -f ($(if ($dockerInfo.currentContext) { $dockerInfo.currentContext } else { '<none>' })))
    $lines += ("- Docker OSType probe: {0}" -f ($(if ($dockerInfo.infoProbe.osType) { $dockerInfo.infoProbe.osType } else { '<unavailable>' })))
    if ($IsWindows -and $dockerInfo.services) {
      foreach ($dockerSvc in @($dockerInfo.services)) {
        $statusText = if ($dockerSvc.found) { ($dockerSvc.status ?? '<unknown>') } else { 'missing' }
        $lines += ("- Docker service `{0}`: {1}" -f $dockerSvc.name, $statusText)
      }
    }
  }

  $queueRepoProp = $null
  if ($health.queue) {
    $queueRepoProp = $health.queue.PSObject.Properties['repo']
  }
  if ($queueRepoProp -and $queueRepoProp.Value) {
    $repoQueue = $queueRepoProp.Value
    $queuedProp = $repoQueue.PSObject.Properties['queued']
    $runningProp = $repoQueue.PSObject.Properties['running']
    $queuedVal = if ($queuedProp) { $queuedProp.Value } else { 'n/a' }
    $runningVal = if ($runningProp) { $runningProp.Value } else { 'n/a' }
    $lines += "- Orchestrated queued: $queuedVal; running: $runningVal"
  }

  $lines += "- Processes (pwsh/LVCompare/LabVIEW): $($procs.Count)"

  ($lines -join "`n") | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

exit 0
