Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LabVIEWPidContext {
  param([object]$Context)

  if (-not $PSBoundParameters.ContainsKey('Context')) { return $null }
  if ($null -eq $Context) { return $null }

  if ($Context -is [System.Collections.IDictionary]) {
    $ordered = [ordered]@{}
    foreach ($key in ($Context.Keys | Where-Object { $_ -ne $null } | Sort-Object -CaseSensitive)) {
      $ordered[[string]$key] = Resolve-LabVIEWPidContext -Context $Context[$key]
    }
    if ($ordered.Count -gt 0) { return [pscustomobject]$ordered }
    return $null
  }

  if ($Context -is [pscustomobject]) {
    $ordered = [ordered]@{}
    foreach ($prop in ($Context.PSObject.Properties | Where-Object { $_ -ne $null } | Sort-Object -Property Name -CaseSensitive)) {
      $ordered[$prop.Name] = Resolve-LabVIEWPidContext -Context $prop.Value
    }
    if ($ordered.Count -gt 0) { return [pscustomobject]$ordered }
    return $null
  }

  if ($Context -is [System.Collections.IEnumerable] -and -not ($Context -is [string])) {
    $list = @()
    foreach ($item in $Context) {
      $list += ,(Resolve-LabVIEWPidContext -Context $item)
    }
    return ,$list
  }

  return $Context
}

function Start-LabVIEWPidTracker {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TrackerPath,
    [string]$Source = 'dispatcher'
  )

  $now = (Get-Date).ToUniversalTime()
  $existingState = $null
  $existingObservations = @()

  if (Test-Path -LiteralPath $TrackerPath -PathType Leaf) {
    try {
      $existingState = Get-Content -LiteralPath $TrackerPath -Raw | ConvertFrom-Json -Depth 12
      if ($existingState -and $existingState.PSObject.Properties['observations']) {
        $existingObservations = @($existingState.observations | Where-Object { $_ -ne $null })
      }
    } catch {
      $existingState = $null
      $existingObservations = @()
    }
  }

  $candidateProcesses = @()
  try {
    $candidateProcesses = @(Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)
  } catch {
    $candidateProcesses = @()
  }

  $trackedPid = $null
  $reused = $false
  $running = $false
  $processCandidates = @()
  $candidateMap = @{}

  $existingPid = $null
  $existingRunning = $false
  if ($existingState -and $existingState.PSObject.Properties['pid']) {
    try { $existingPid = [int]$existingState.pid } catch { $existingPid = $null }
  }
  if ($existingState -and $existingState.PSObject.Properties['running']) {
    try { $existingRunning = [bool]$existingState.running } catch { $existingRunning = $false }
  }

  if ($existingPid -and $existingPid -gt 0 -and $existingRunning) {
    try {
      $existingProcess = Get-Process -Id $existingPid -ErrorAction Stop
      if ($existingProcess -and $existingProcess.ProcessName -eq 'LabVIEW') {
        $processCandidates += ,([pscustomobject]@{
            Process = $existingProcess
            Reused  = $true
          })
        $candidateMap["$existingPid"] = $true
      }
    } catch {
      $existingPid = $null
    }
  }

  $candidateIds = @()
  foreach ($proc in $candidateProcesses) {
    try { $candidateIds += [int]$proc.Id } catch {}

    if ($null -eq $proc) { continue }
    $candidateId = $null
    try { $candidateId = [int]$proc.Id } catch { $candidateId = $null }
    if (-not $candidateId -or $candidateId -le 0) { continue }
    if ($candidateMap.ContainsKey("$candidateId")) { continue }

    $candidateEntry = [pscustomobject]@{
      Process = $proc
      Reused  = $false
    }
    $processCandidates += ,$candidateEntry
    $candidateMap["$candidateId"] = $true
  }

  if ($processCandidates.Count -gt 0) {
    $reusePref = @()
    $freshPref = @()
    foreach ($entry in $processCandidates) {
      if ($entry.Reused) {
        $reusePref += ,$entry
      } else {
        $freshPref += ,$entry
      }
    }

    if ($freshPref.Count -gt 1) {
      try {
        $freshPref = @(
          $freshPref | Sort-Object -Property @{ Expression = { $_.Process.StartTime } }
        )
      } catch {
        $freshPref = @($freshPref)
      }
    }

    $processCandidates = @($reusePref + $freshPref)
  }

  foreach ($candidate in $processCandidates) {
    if (-not $candidate -or -not $candidate.Process) { continue }

    $candidatePid = $null
    try { $candidatePid = [int]$candidate.Process.Id } catch { $candidatePid = $null }
    if (-not $candidatePid -or $candidatePid -le 0) { continue }

    try {
      $procCheck = Get-Process -Id $candidatePid -ErrorAction Stop
      if ($procCheck -and $procCheck.ProcessName -eq 'LabVIEW') {
        $trackedPid = $candidatePid
        $running = $true
        $reused = [bool]$candidate.Reused
        break
      }
    } catch {
      continue
    }
  }

  $note = if ($trackedPid) {
    if ($reused) { 'reused-existing' } else { 'selected-from-scan' }
  } elseif ($candidateIds.Count -gt 0) {
    'candidates-present'
  } else {
    'labview-not-running'
  }

  $observation = [ordered]@{
    at         = $now.ToString('o')
    action     = 'initialize'
    pid        = if ($trackedPid) { [int]$trackedPid } else { $null }
    running    = $running
    reused     = $reused
    source     = $Source
    note       = $note
    candidates = $candidateIds
  }

  $obsList = @()
  if ($existingObservations -is [System.Collections.IEnumerable]) {
    $obsList = @($existingObservations | Where-Object { $_ -ne $null })
  }
  $obsList += [pscustomobject]$observation
  $obsList = @($obsList | Select-Object -Last 25)

  $dir = Split-Path -Parent $TrackerPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $record = [ordered]@{
    schema       = 'labview-pid-tracker/v1'
    updatedAt    = $now.ToString('o')
    pid          = if ($trackedPid) { [int]$trackedPid } else { $null }
    running      = $running
    reused       = $reused
    source       = $Source
    observations = $obsList
  }

  $record | ConvertTo-Json -Depth 12 | Out-File -FilePath $TrackerPath -Encoding utf8

  return [pscustomobject]@{
    Path        = $TrackerPath
    Pid         = $record.pid
    Running     = $running
    Reused      = $reused
    Candidates  = $candidateIds
    Observation = $observation
  }
}

function Stop-LabVIEWPidTracker {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TrackerPath,
    [Nullable[int]]$Pid,
    [string]$Source = 'dispatcher',
    [object]$Context
  )

  $now = (Get-Date).ToUniversalTime()
  $state = $null
  $existingObservations = @()

  if (Test-Path -LiteralPath $TrackerPath -PathType Leaf) {
    try {
      $state = Get-Content -LiteralPath $TrackerPath -Raw | ConvertFrom-Json -Depth 12
      if ($state -and $state.PSObject.Properties['observations']) {
        $existingObservations = @($state.observations | Where-Object { $_ -ne $null })
      }
    } catch {
      $state = $null
      $existingObservations = @()
    }
  }

  $trackedPid = $null
  if ($PSBoundParameters.ContainsKey('Pid') -and $null -ne $Pid) {
    try { $trackedPid = [int]$Pid } catch { $trackedPid = $null }
  }
  if (-not $trackedPid -and $state -and $state.PSObject.Properties['pid']) {
    try { $trackedPid = [int]$state.pid } catch { $trackedPid = $null }
  }

  $running = $false
  $reused = $false
  if ($state -and $state.PSObject.Properties['reused']) {
    try { $reused = [bool]$state.reused } catch { $reused = $false }
  }

  if ($trackedPid -and $trackedPid -gt 0) {
    try {
      $procCheck = Get-Process -Id $trackedPid -ErrorAction Stop
      if ($procCheck -and $procCheck.ProcessName) { $running = $true }
    } catch {
      $running = $false
      if ($reused) {
        $trackedPid = $null
        $reused = $false
      }
    }
  }

  $note = if ($trackedPid) {
    if ($running) { 'still-running' } else { 'not-running' }
  } else {
    'no-tracked-pid'
  }

  $contextBlock = $null
  $contextSourceValue = $null
  if ($PSBoundParameters.ContainsKey('Context')) {
    $contextBlock = Resolve-LabVIEWPidContext -Context $Context
    if ($contextBlock) { $contextSourceValue = $Source }
  }

  $observation = [ordered]@{
    at      = $now.ToString('o')
    action  = 'finalize'
    pid     = if ($trackedPid) { [int]$trackedPid } else { $null }
    running = $running
    reused  = $reused
    source  = $Source
    note    = $note
  }
  if ($contextBlock) {
    $observation['context'] = $contextBlock
    $observation['contextSource'] = $contextSourceValue
  }

  $obsList = @()
  if ($existingObservations -is [System.Collections.IEnumerable]) {
    $obsList = @($existingObservations | Where-Object { $_ -ne $null })
  }
  $obsList += [pscustomobject]$observation
  $obsList = @($obsList | Select-Object -Last 25)

  $record = [ordered]@{
    schema       = 'labview-pid-tracker/v1'
    updatedAt    = $now.ToString('o')
    pid          = if ($trackedPid) { [int]$trackedPid } else { $null }
    running      = $running
    reused       = $reused
    source       = $Source
    observations = $obsList
  }
  if ($contextBlock) {
    $record['context'] = $contextBlock
    $record['contextSource'] = $contextSourceValue
  }

  $dir = Split-Path -Parent $TrackerPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $record | ConvertTo-Json -Depth 12 | Out-File -FilePath $TrackerPath -Encoding utf8

  return [pscustomobject]@{
    Path        = $TrackerPath
    Pid         = $record.pid
    Running     = $running
    Reused      = $reused
    Observation  = $observation
    Context      = $contextBlock
    ContextSource = $contextSourceValue
  }
}

Export-ModuleMember -Function Resolve-LabVIEWPidContext,Start-LabVIEWPidTracker,Stop-LabVIEWPidTracker
