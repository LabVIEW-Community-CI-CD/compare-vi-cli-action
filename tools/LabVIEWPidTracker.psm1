Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-LabVIEWPidTracker {
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
      $existingState = Get-Content -LiteralPath $TrackerPath -Raw | ConvertFrom-Json -Depth 6
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

  if ($existingState -and $existingState.PSObject.Properties['pid']) {
    $candidatePid = $null
    try { $candidatePid = [int]$existingState.pid } catch { $candidatePid = $null }
    if ($candidatePid -and $candidatePid -gt 0) {
      try {
        $proc = Get-Process -Id $candidatePid -ErrorAction Stop
        if ($proc -and $proc.ProcessName -and $proc.ProcessName -eq 'LabVIEW') {
          $trackedPid = [int]$proc.Id
          $reused = $true
        }
      } catch {}
    }
  }

  if (-not $trackedPid -and $candidateProcesses.Count -gt 0) {
    $selected = $null
    try {
      $selected = $candidateProcesses | Sort-Object StartTime | Select-Object -First 1
    } catch {
      if ($candidateProcesses.Count -gt 0) { $selected = $candidateProcesses[0] }
    }
    if ($selected) {
      try { $trackedPid = [int]$selected.Id } catch { $trackedPid = $null }
    }
  }

  $running = $false
  if ($trackedPid -and $trackedPid -gt 0) {
    try {
      $procCheck = Get-Process -Id $trackedPid -ErrorAction Stop
      if ($procCheck -and $procCheck.ProcessName) { $running = $true }
    } catch { $running = $false }
  }

  $candidateIds = @()
  foreach ($proc in $candidateProcesses) {
    try { $candidateIds += [int]$proc.Id } catch {}
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

  $record | ConvertTo-Json -Depth 6 | Out-File -FilePath $TrackerPath -Encoding utf8

  return [pscustomobject]@{
    Path        = $TrackerPath
    Pid         = $record.pid
    Running     = $running
    Reused      = $reused
    Candidates  = $candidateIds
    Observation = $observation
  }
}

function Finalize-LabVIEWPidTracker {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TrackerPath,
    [Nullable[int]]$Pid,
    [string]$Source = 'dispatcher'
  )

  $now = (Get-Date).ToUniversalTime()
  $state = $null
  $existingObservations = @()

  if (Test-Path -LiteralPath $TrackerPath -PathType Leaf) {
    try {
      $state = Get-Content -LiteralPath $TrackerPath -Raw | ConvertFrom-Json -Depth 6
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
  if ($trackedPid -and $trackedPid -gt 0) {
    try {
      $procCheck = Get-Process -Id $trackedPid -ErrorAction Stop
      if ($procCheck -and $procCheck.ProcessName) { $running = $true }
    } catch { $running = $false }
  }

  $note = if ($trackedPid) {
    if ($running) { 'still-running' } else { 'not-running' }
  } else {
    'no-tracked-pid'
  }

  $observation = [ordered]@{
    at      = $now.ToString('o')
    action  = 'finalize'
    pid     = if ($trackedPid) { [int]$trackedPid } else { $null }
    running = $running
    source  = $Source
    note    = $note
  }

  $obsList = @()
  if ($existingObservations -is [System.Collections.IEnumerable]) {
    $obsList = @($existingObservations | Where-Object { $_ -ne $null })
  }
  $obsList += [pscustomobject]$observation
  $obsList = @($obsList | Select-Object -Last 25)

  $reused = $false
  if ($state -and $state.PSObject.Properties['reused']) {
    try { $reused = [bool]$state.reused } catch { $reused = $false }
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

  $dir = Split-Path -Parent $TrackerPath
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $record | ConvertTo-Json -Depth 6 | Out-File -FilePath $TrackerPath -Encoding utf8

  return [pscustomobject]@{
    Path        = $TrackerPath
    Pid         = $record.pid
    Running     = $running
    Observation = $observation
  }
}

Export-ModuleMember -Function Initialize-LabVIEWPidTracker,Finalize-LabVIEWPidTracker
