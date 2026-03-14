Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
  param(
    [Parameter(Mandatory)][AllowNull()]$InputObject,
    [Parameter(Mandatory)][string]$Name,
    $Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) {
      return $InputObject[$Name]
    }
    return $Default
  }

  if ($InputObject.PSObject -and $InputObject.PSObject.Properties[$Name]) {
    return $InputObject.PSObject.Properties[$Name].Value
  }

  return $Default
}

function Convert-ToTrimmedString {
  param([AllowNull()]$Value)
  if ($null -eq $Value) {
    return ''
  }
  return ([string]$Value).Trim()
}

function Convert-ToBoolean {
  param([AllowNull()]$Value)
  if ($null -eq $Value) {
    return $false
  }
  if ($Value -is [bool]) {
    return $Value
  }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $false
  }
  try {
    return [System.Convert]::ToBoolean($text, [System.Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return $false
  }
}

function Convert-ToInt {
  param([AllowNull()]$Value)
  if ($null -eq $Value) {
    return 0
  }
  try {
    return [int]$Value
  } catch {
    return 0
  }
}

function Convert-ToSecondsString {
  param([double]$Milliseconds)
  return ([math]::Round(($Milliseconds / 1000.0), 3)).ToString('0.###')
}

function Resolve-DisplayPath {
  param(
    [string]$Path,
    [string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return '-'
  }

  try {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
  } catch {
    return $Path
  }

  if ([string]::IsNullOrWhiteSpace($BasePath)) {
    return $fullPath
  }

  try {
    $fullBase = [System.IO.Path]::GetFullPath($BasePath)
    $relative = [System.IO.Path]::GetRelativePath($fullBase, $fullPath)
    if (-not [string]::IsNullOrWhiteSpace($relative) -and -not $relative.StartsWith('..')) {
      return $relative
    }
  } catch {
    return $fullPath
  }

  return $fullPath
}

function Resolve-HistoryStepDescriptor {
  param(
    [AllowNull()]$Step,
    [Parameter(Mandatory)][string]$StepName
  )

  $explicitLane = Convert-ToTrimmedString (Get-PropertyValue -InputObject $Step -Name 'historyLane')
  $explicitMode = Convert-ToTrimmedString (Get-PropertyValue -InputObject $Step -Name 'historyMode')
  $explicitSequence = Convert-ToTrimmedString (Get-PropertyValue -InputObject $Step -Name 'historySequence')
  if (-not [string]::IsNullOrWhiteSpace($explicitMode)) {
    if ([string]::IsNullOrWhiteSpace($explicitLane)) {
      if ($StepName -like 'windows-*') {
        $explicitLane = 'windows'
      } elseif ($StepName -like 'linux-*') {
        $explicitLane = 'linux'
      }
    }
    if ([string]::IsNullOrWhiteSpace($explicitSequence)) {
      $explicitSequence = 'direct'
    }
    return [pscustomobject][ordered]@{
      lane = $explicitLane
      sequence = $explicitSequence
      mode = $explicitMode
    }
  }

  $match = [regex]::Match($StepName, '^(?<lane>windows|linux)-history-(?<tail>.+)$')
  if (-not $match.Success) {
    return $null
  }

  $lane = $match.Groups['lane'].Value
  $tail = $match.Groups['tail'].Value
  $sequence = 'direct'
  $mode = $tail
  if ($tail -match '^sequential-(?<mode>.+)$') {
    $sequence = 'sequential'
    $mode = $Matches['mode']
  }

  return [pscustomobject][ordered]@{
    lane = $lane
    sequence = $sequence
    mode = $mode
  }
}

function Resolve-ResultsRoot {
  param(
    [AllowNull()]$Readiness,
    [string]$ResultsRoot
  )

  if (-not [string]::IsNullOrWhiteSpace($ResultsRoot)) {
    try {
      return [System.IO.Path]::GetFullPath($ResultsRoot)
    } catch {
      return $ResultsRoot
    }
  }

  $source = Get-PropertyValue -InputObject $Readiness -Name 'source'
  $fromReadiness = Convert-ToTrimmedString (Get-PropertyValue -InputObject $source -Name 'resultsRoot')
  if (-not [string]::IsNullOrWhiteSpace($fromReadiness)) {
    try {
      return [System.IO.Path]::GetFullPath($fromReadiness)
    } catch {
      return $fromReadiness
    }
  }

  return ''
}

function Resolve-DockerFastLoopLabelFromLaneNames {
  param([AllowEmptyCollection()][string[]]$LaneNames = @())

  $normalized = @(
    @($LaneNames) |
      ForEach-Object { Convert-ToTrimmedString $_ } |
      ForEach-Object { $_.Trim().ToLowerInvariant() } |
      Where-Object { $_ -in @('windows', 'linux') } |
      Sort-Object -Unique
  )

  if ($normalized.Count -eq 1) {
    switch ($normalized[0]) {
      'windows' { return 'windows-docker-fast-loop' }
      'linux' { return 'linux-docker-fast-loop' }
    }
  }

  if ($normalized.Count -gt 1) {
    return 'dual-docker-fast-loop'
  }

  return ''
}

function Get-ObservedDockerFastLoopLanes {
  param([AllowNull()]$ContextObject)

  $steps = @(Get-PropertyValue -InputObject $ContextObject -Name 'steps' -Default @())
  if ($steps.Count -eq 0) {
    return @()
  }

  $laneNames = New-Object System.Collections.Generic.HashSet[string]
  foreach ($step in $steps) {
    $explicitLane = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'historyLane')
    if ([string]::IsNullOrWhiteSpace($explicitLane)) {
      $stepName = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'name')
      $match = [regex]::Match($stepName, '^(?<lane>windows|linux)-')
      if ($match.Success) {
        $explicitLane = $match.Groups['lane'].Value
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($explicitLane)) {
      $laneNames.Add($explicitLane.Trim().ToLowerInvariant()) | Out-Null
    }
  }

  return [string[]]($laneNames | ForEach-Object { $_ })
}

function Get-DockerFastLoopLabel {
  [CmdletBinding()]
  param(
    [AllowNull()]$ContextObject,
    [AllowEmptyCollection()][object[]]$Diagnostics = @()
  )

  $explicitLabel = Convert-ToTrimmedString (Get-PropertyValue -InputObject $ContextObject -Name 'loopLabel')
  if (-not [string]::IsNullOrWhiteSpace($explicitLabel)) {
    return $explicitLabel
  }

  $runObject = Get-PropertyValue -InputObject $ContextObject -Name 'run'
  $runLabel = Convert-ToTrimmedString (Get-PropertyValue -InputObject $runObject -Name 'loopLabel')
  if (-not [string]::IsNullOrWhiteSpace($runLabel)) {
    return $runLabel
  }

  $observedStepLabel = Resolve-DockerFastLoopLabelFromLaneNames -LaneNames (Get-ObservedDockerFastLoopLanes -ContextObject $ContextObject)
  if (-not [string]::IsNullOrWhiteSpace($observedStepLabel)) {
    return $observedStepLabel
  }

  if (@($Diagnostics).Count -gt 0) {
    $diagnosticLabel = Resolve-DockerFastLoopLabelFromLaneNames -LaneNames @($Diagnostics | ForEach-Object { Convert-ToTrimmedString $_.lane })
    if (-not [string]::IsNullOrWhiteSpace($diagnosticLabel)) {
      return $diagnosticLabel
    }
  }

  $lanes = Get-PropertyValue -InputObject $ContextObject -Name 'lanes'
  if ($lanes) {
    $laneNames = New-Object System.Collections.Generic.List[string]
    $windowsLane = Get-PropertyValue -InputObject $lanes -Name 'windows'
    $linuxLane = Get-PropertyValue -InputObject $lanes -Name 'linux'
    $windowsStatus = Convert-ToTrimmedString (Get-PropertyValue -InputObject $windowsLane -Name 'status')
    $linuxStatus = Convert-ToTrimmedString (Get-PropertyValue -InputObject $linuxLane -Name 'status')
    if ($windowsStatus -and $windowsStatus -ne 'skipped') {
      $laneNames.Add('windows') | Out-Null
    }
    if ($linuxStatus -and $linuxStatus -ne 'skipped') {
      $laneNames.Add('linux') | Out-Null
    }
    $laneLabel = Resolve-DockerFastLoopLabelFromLaneNames -LaneNames ([string[]]($laneNames | ForEach-Object { $_ }))
    if (-not [string]::IsNullOrWhiteSpace($laneLabel)) {
      return $laneLabel
    }
  }

  $laneScope = Convert-ToTrimmedString (Get-PropertyValue -InputObject $ContextObject -Name 'laneScope')
  switch ($laneScope) {
    'windows' { return 'windows-docker-fast-loop' }
    'linux' { return 'linux-docker-fast-loop' }
    'both' { return 'dual-docker-fast-loop' }
  }

  return 'docker-fast-loop'
}

function Get-DockerFastLoopLogPrefix {
  [CmdletBinding()]
  param(
    [AllowNull()]$ContextObject,
    [AllowEmptyCollection()][object[]]$Diagnostics = @()
  )

  return ('[{0}]' -f (Get-DockerFastLoopLabel -ContextObject $ContextObject -Diagnostics $Diagnostics))
}

function Get-DockerDesktopPlaneId {
  param([Parameter(Mandatory)][string]$Lane)

  switch ($Lane.Trim().ToLowerInvariant()) {
    'windows' { return 'docker-desktop/windows-container-2026' }
    'linux' { return 'docker-desktop/linux-container-2026' }
    default { return '' }
  }
}

function Get-DockerFastLoopDockerDesktopPlaneProjection {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$ContextObject,
    [AllowNull()]$HostExecutionPolicy = $null
  )

  $explicit = Get-PropertyValue -InputObject $ContextObject -Name 'dockerDesktopPlanes'
  if ($explicit) {
    return $explicit
  }

  $runtimeManager = Get-PropertyValue -InputObject $ContextObject -Name 'runtimeManager'
  if (-not $runtimeManager) {
    return $null
  }

  $laneScope = Convert-ToTrimmedString (Get-PropertyValue -InputObject $ContextObject -Name 'laneScope')
  if ([string]::IsNullOrWhiteSpace($laneScope)) {
    $runObject = Get-PropertyValue -InputObject $ContextObject -Name 'run'
    $laneScope = Convert-ToTrimmedString (Get-PropertyValue -InputObject $runObject -Name 'laneScope')
  }
  if ([string]::IsNullOrWhiteSpace($laneScope)) {
    $laneScope = 'both'
  }

  $runtimeProbes = Get-PropertyValue -InputObject $runtimeManager -Name 'probes'
  $requestedPlanes = New-Object System.Collections.Generic.List[string]
  $planeRecords = [ordered]@{}
  foreach ($laneName in @('windows', 'linux')) {
    $planeId = Get-DockerDesktopPlaneId -Lane $laneName
    $expectedOsType = if ($laneName -eq 'windows') { 'windows' } else { 'linux' }
    $probe = Get-PropertyValue -InputObject $runtimeProbes -Name $laneName
    $enabled = Convert-ToBoolean (Get-PropertyValue -InputObject $probe -Name 'enabled')
    if (-not $enabled) {
      switch ($laneScope) {
        'windows' { $enabled = ($laneName -eq 'windows') }
        'linux' { $enabled = ($laneName -eq 'linux') }
        'both' { $enabled = $true }
      }
    }

    $status = Convert-ToTrimmedString (Get-PropertyValue -InputObject $probe -Name 'status')
    if ([string]::IsNullOrWhiteSpace($status)) {
      $status = if ($enabled) { 'pending' } else { 'skipped' }
    }
    $contextName = Convert-ToTrimmedString (Get-PropertyValue -InputObject $probe -Name 'context')
    $observedOsType = Convert-ToTrimmedString (Get-PropertyValue -InputObject $probe -Name 'osType')
    $osTypeMatches = [string]::Equals($observedOsType, $expectedOsType, [System.StringComparison]::OrdinalIgnoreCase)
    $engineReady = ($status -eq 'success') -and $osTypeMatches

    if ($enabled) {
      $requestedPlanes.Add($planeId) | Out-Null
    }

    $planeRecords[$laneName] = [ordered]@{
      plane = $planeId
      lane = $laneName
      enabled = [bool]$enabled
      status = $status
      context = $contextName
      expectedOsType = $expectedOsType
      observedOsType = $observedOsType
      osTypeMatches = [bool]$osTypeMatches
      engineReady = [bool]$engineReady
    }
  }

  $exclusivePairs = @(
    @(Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $HostExecutionPolicy -Name 'mutuallyExclusivePairs') -Name 'pairs' -Default @()) |
      ForEach-Object {
        [ordered]@{
          left = Convert-ToTrimmedString (Get-PropertyValue -InputObject $_ -Name 'left')
          right = Convert-ToTrimmedString (Get-PropertyValue -InputObject $_ -Name 'right')
        }
      }
  )
  $exclusiveRequired = ($requestedPlanes.Count -gt 1)
  $exclusiveSatisfied = $false
  if (-not $exclusiveRequired) {
    $requestedRecord = @($planeRecords.GetEnumerator() | ForEach-Object { $_.Value } | Where-Object { [bool]$_.enabled } | Select-Object -First 1)
    if ($requestedRecord.Count -eq 0) {
      $exclusiveSatisfied = $true
    } else {
      $exclusiveSatisfied = [bool]$requestedRecord[0].engineReady
    }
  } else {
    $windowsRecord = $planeRecords.windows
    $linuxRecord = $planeRecords.linux
    $contextsDistinct = -not [string]::Equals([string]$windowsRecord.context, [string]$linuxRecord.context, [System.StringComparison]::OrdinalIgnoreCase)
    $exclusiveSatisfied = [bool](
      $windowsRecord.enabled -and
      $linuxRecord.enabled -and
      $windowsRecord.engineReady -and
      $linuxRecord.engineReady -and
      $contextsDistinct
    )
  }

  return [pscustomobject][ordered]@{
    schema = 'docker-fast-loop/docker-desktop-planes@v1'
    laneScope = $laneScope
    loopLabel = Get-DockerFastLoopLabel -ContextObject $ContextObject
    requestedPlanes = @($requestedPlanes.ToArray())
    exclusiveRequired = [bool]$exclusiveRequired
    exclusiveSatisfied = [bool]$exclusiveSatisfied
    mutuallyExclusivePairCount = [int]@($exclusivePairs).Count
    mutuallyExclusivePairs = [ordered]@{
      pairs = @($exclusivePairs)
    }
    planes = [ordered]@{
      windows = $planeRecords.windows
      linux = $planeRecords.linux
    }
  }
}

function Write-DockerFastLoopDockerDesktopPlaneDiagnostics {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$ContextObject
  )

  $hostExecutionPolicy = Get-PropertyValue -InputObject $ContextObject -Name 'hostExecutionPolicy'
  $dockerDesktopPlanes = Get-DockerFastLoopDockerDesktopPlaneProjection -ContextObject $ContextObject -HostExecutionPolicy $hostExecutionPolicy
  if ($null -eq $dockerDesktopPlanes) {
    return $null
  }

  $prefix = Get-DockerFastLoopLogPrefix -ContextObject $ContextObject
  $requestedPlanes = @($dockerDesktopPlanes.requestedPlanes | ForEach-Object { [string]$_ }) -join ','
  if ([string]::IsNullOrWhiteSpace($requestedPlanes)) {
    $requestedPlanes = '-'
  }

  Write-Host (
    "{0}[docker-plane] requested={1} exclusiveRequired={2} exclusiveSatisfied={3} pairCount={4}" -f
    $prefix,
    $requestedPlanes,
    [bool]$dockerDesktopPlanes.exclusiveRequired,
    [bool]$dockerDesktopPlanes.exclusiveSatisfied,
    [int]$dockerDesktopPlanes.mutuallyExclusivePairCount
  ) -ForegroundColor DarkCyan

  foreach ($laneName in @('windows', 'linux')) {
    $planeRecord = Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $dockerDesktopPlanes -Name 'planes') -Name $laneName
    if ($null -eq $planeRecord) {
      continue
    }

    Write-Host (
      "{0}[docker-plane] lane={1} plane={2} enabled={3} status={4} context={5} expectedOs={6} observedOs={7}" -f
      $prefix,
      $laneName,
      [string]$planeRecord.plane,
      [bool]$planeRecord.enabled,
      [string]$planeRecord.status,
      $(if ([string]::IsNullOrWhiteSpace([string]$planeRecord.context)) { '-' } else { [string]$planeRecord.context }),
      [string]$planeRecord.expectedOsType,
      $(if ([string]::IsNullOrWhiteSpace([string]$planeRecord.observedOsType)) { '-' } else { [string]$planeRecord.observedOsType })
    ) -ForegroundColor DarkGray
  }

  return $dockerDesktopPlanes
}

function Get-DockerFastLoopDifferentiatedDiagnostics {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$Readiness,
    [string]$ResultsRoot = ''
  )

  $resolvedResultsRoot = Resolve-ResultsRoot -Readiness $Readiness -ResultsRoot $ResultsRoot
  $steps = @(Get-PropertyValue -InputObject $Readiness -Name 'steps' -Default @())
  $diagnostics = New-Object System.Collections.Generic.List[object]

  foreach ($step in @($steps)) {
    if (-not (Convert-ToBoolean (Get-PropertyValue -InputObject $step -Name 'isDiff'))) {
      continue
    }

    $stepName = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'name')
    $descriptor = Resolve-HistoryStepDescriptor -Step $step -StepName $stepName
    if ($null -eq $descriptor) {
      continue
    }

    $diagnostics.Add([pscustomobject][ordered]@{
        stepName = $stepName
        lane = $descriptor.lane
        sequence = $descriptor.sequence
        mode = $descriptor.mode
        diffImageCount = Convert-ToInt (Get-PropertyValue -InputObject $step -Name 'diffImageCount')
        diffEvidenceSource = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'diffEvidenceSource')
        durationMs = [double](Get-PropertyValue -InputObject $step -Name 'durationMs' -Default 0)
        durationSeconds = [math]::Round(([double](Get-PropertyValue -InputObject $step -Name 'durationMs' -Default 0) / 1000.0), 3)
        resultClass = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'resultClass')
        gateOutcome = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'gateOutcome')
        containerExportStatus = Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'containerExportStatus')
        reportPath = Resolve-DisplayPath -Path (Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'extractedReportPath')) -BasePath $resolvedResultsRoot
        capturePath = Resolve-DisplayPath -Path (Convert-ToTrimmedString (Get-PropertyValue -InputObject $step -Name 'capturePath')) -BasePath $resolvedResultsRoot
      }) | Out-Null
  }

  return $diagnostics.ToArray()
}

function Write-DockerFastLoopDifferentiatedDiagnostics {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowNull()]$Readiness,
    [string]$ResultsRoot = ''
  )

  $diagnostics = @(Get-DockerFastLoopDifferentiatedDiagnostics -Readiness $Readiness -ResultsRoot $ResultsRoot)
  $prefix = Get-DockerFastLoopLogPrefix -ContextObject $Readiness -Diagnostics $diagnostics
  if ($diagnostics.Count -eq 0) {
    Write-Host ("{0}[diagnostics] no differentiated history diagnostics detected" -f $prefix) -ForegroundColor DarkYellow
    return $diagnostics
  }

  $run = Get-PropertyValue -InputObject $Readiness -Name 'run'
  $scenarioSet = Convert-ToTrimmedString (Get-PropertyValue -InputObject $run -Name 'historyScenarioSet')
  if ([string]::IsNullOrWhiteSpace($scenarioSet)) {
    $scenarioSet = Convert-ToTrimmedString (Get-PropertyValue -InputObject $Readiness -Name 'historyScenarioSet')
  }
  if ([string]::IsNullOrWhiteSpace($scenarioSet)) {
    $scenarioSet = 'unknown'
  }

  $diffEvidenceSteps = Convert-ToInt (Get-PropertyValue -InputObject $Readiness -Name 'diffEvidenceSteps')
  $extractedReportCount = Convert-ToInt (Get-PropertyValue -InputObject $Readiness -Name 'extractedReportCount')

  Write-Host (
    "{0}[diagnostics] scenarioSet={1} differentiatedSteps={2} evidenceSteps={3} reports={4}" -f
    $prefix,
    $scenarioSet,
    $diagnostics.Count,
    $diffEvidenceSteps,
    $extractedReportCount
  ) -ForegroundColor Cyan

  foreach ($entry in $diagnostics) {
    $exportStatus = if ([string]::IsNullOrWhiteSpace($entry.containerExportStatus)) { '-' } else { $entry.containerExportStatus }
    Write-Host (
      "{0}[diagnostics] lane={1} sequence={2} mode={3} images={4} duration={5}s export={6} report={7} capture={8}" -f
      $prefix,
      $entry.lane,
      $entry.sequence,
      $entry.mode,
      $entry.diffImageCount,
      (Convert-ToSecondsString -Milliseconds $entry.durationMs),
      $exportStatus,
      $entry.reportPath,
      $entry.capturePath
    ) -ForegroundColor Magenta
  }

  return $diagnostics
}

Export-ModuleMember -Function Get-DockerFastLoopDifferentiatedDiagnostics, Get-DockerFastLoopDockerDesktopPlaneProjection, Get-DockerFastLoopLabel, Get-DockerFastLoopLogPrefix, Write-DockerFastLoopDifferentiatedDiagnostics, Write-DockerFastLoopDockerDesktopPlaneDiagnostics
