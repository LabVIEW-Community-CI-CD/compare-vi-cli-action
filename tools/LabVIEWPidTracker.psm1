Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LabVIEWPidContext {
  param([object]$Input)

  if (-not $PSBoundParameters.ContainsKey('Input')) { return $null }
  if ($null -eq $Input) { return $null }

  $normalizeDictionary = $null
  $normalizeValue = $null

  $normalizeDictionary = {
    param([object]$Value)

    $pairs = @()
    if ($Value -is [System.Collections.IDictionary]) {
      foreach ($key in $Value.Keys) {
        if ($null -eq $key) { continue }
        $pairs += [pscustomobject]@{ Name = [string]$key; Value = $Value[$key] }
      }
    } else {
      try {
        $pairs = @($Value.PSObject.Properties | ForEach-Object {
            if ($null -ne $_) {
              [pscustomobject]@{ Name = $_.Name; Value = $_.Value }
            }
          })
      } catch {
        $pairs = @()
      }
    }

    if (-not $pairs -or $pairs.Count -eq 0) { return $null }

    $ordered = [ordered]@{}
    $orderedPairs = $pairs |
      Where-Object { $_ -and $_.Name } |
      Sort-Object -Property Name -CaseSensitive

    foreach ($pair in $orderedPairs) {
      if ($ordered.Contains($pair.Name)) { continue }
      $ordered[$pair.Name] = & $normalizeValue $pair.Value
    }

    if ($ordered.Count -eq 0) { return $null }
    return [pscustomobject]$ordered
  }

  $normalizeValue = {
    param([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return & $normalizeDictionary $Value }
    if ($Value -is [pscustomobject]) { return & $normalizeDictionary $Value }

    $isEnumerable = $false
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
      if (-not ($Value -is [System.Collections.IDictionary])) { $isEnumerable = $true }
    }

    if ($isEnumerable) {
      $items = @()
      foreach ($item in $Value) {
        $items += ,(& $normalizeValue $item)
      }
      return @($items)
    }

    return $Value
  }

  return & $normalizeValue $Input
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

function Stop-LabVIEWPidTracker {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TrackerPath,
    [Nullable[int]]$Pid,
    [string]$Source = 'dispatcher',
    [object]$Context,
    [string]$ContextSourceDetail
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

  $reused = $false
  if ($state -and $state.PSObject.Properties['reused']) {
    try { $reused = [bool]$state.reused } catch { $reused = $false }
  }

  $contextBlock = $null
  $contextSourceValue = $null
  $contextSourceDetailValue = $null
  if ($PSBoundParameters.ContainsKey('Context')) {
    $contextBlock = Resolve-LabVIEWPidContext -Input $Context
    if ($contextBlock) {
      $contextSourceValue = $Source
      if ($PSBoundParameters.ContainsKey('ContextSourceDetail') -and $ContextSourceDetail) {
        $contextSourceDetailValue = [string]$ContextSourceDetail
      } elseif ($contextSourceValue) {
        $contextSourceDetailValue = [string]$contextSourceValue
      }
    }
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
    if ($contextSourceDetailValue) { $observation['contextSourceDetail'] = $contextSourceDetailValue }
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
    if ($contextSourceDetailValue) { $record['contextSourceDetail'] = $contextSourceDetailValue }
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
    Reused      = $reused
    Observation  = $observation
    Context      = $contextBlock
    ContextSource = $contextSourceValue
    ContextSourceDetail = $contextSourceDetailValue
  }
}

Export-ModuleMember -Function Resolve-LabVIEWPidContext,Start-LabVIEWPidTracker,Stop-LabVIEWPidTracker
