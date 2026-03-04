#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('all', 'linux', 'windows', 'host')]
  [string]$LaneScope = 'all',
  [string]$BaseVi = 'VI1.vi',
  [string]$HeadVi = 'VI2.vi',
  [string]$HistoryViPath = 'VI1.vi',
  [string]$HistoryStartRef = 'HEAD~10',
  [string]$HistoryEndRef,
  [int]$HistoryMaxPairs = 6,
  [Alias('LabVIEWPath')]
  [string]$HostLabVIEWPath,
  [string]$ContainerLabVIEWPath,
  [string]$ResultsRoot = 'tests/results/_agent/validation-matrix',
  [switch]$ContinueOnLaneFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  try {
    $root = (& git rev-parse --show-toplevel 2>$null).Trim()
    if ($root) { return $root }
  } catch {}
  return (Get-Location).Path
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-PathFromRepo {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$Value
  )

  if ([System.IO.Path]::IsPathRooted($Value)) {
    return [System.IO.Path]::GetFullPath($Value)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Value))
}

function Assert-NoLabVIEW2025Path {
  param(
    [string]$PathValue,
    [string]$ParameterName
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return
  }

  if ($PathValue -match '(?i)labview\s*2025') {
    throw ("{0} points to LabVIEW 2025, which is not allowed: {1}" -f $ParameterName, $PathValue)
  }
}

function Resolve-ContainerLabVIEWPathForOs {
  param(
    [string]$PathValue,
    [Parameter(Mandatory = $true)][ValidateSet('linux', 'windows')][string]$TargetOs
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $trimmed = $PathValue.Trim()
  $looksWindowsStyle = ($trimmed -match '^[A-Za-z]:\\') -or ($trimmed.Contains('\\'))
  $looksUnixStyle = $trimmed.StartsWith('/')

  if ($TargetOs -eq 'linux' -and $looksWindowsStyle) {
    return $null
  }

  if ($TargetOs -eq 'windows' -and $looksUnixStyle) {
    return $null
  }

  return $trimmed
}

function Get-RepoRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $PathValue
  }

  $fullPath = Resolve-PathFromRepo -RepoRoot $RepoRoot -Value $PathValue
  $repoRootNormalized = [System.IO.Path]::GetFullPath($RepoRoot)
  if ($fullPath.StartsWith($repoRootNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ($fullPath.Substring($repoRootNormalized.Length).TrimStart('\','/') -replace '\\','/')
  }

  return $PathValue
}

function New-VIHistoryBundle {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$RunDir,
    [Parameter(Mandatory = $true)][string]$LaneName,
    [Parameter(Mandatory = $true)][string]$HistoryViPath,
    [Parameter(Mandatory = $true)][string]$HistoryStartRef,
    [string]$HistoryEndRef,
    [int]$HistoryMaxPairs
  )

  $repoRelativePath = Get-RepoRelativePath -RepoRoot $RepoRoot -PathValue $HistoryViPath
  $rangeCandidates = if (-not [string]::IsNullOrWhiteSpace($HistoryEndRef)) {
    @(
      ("{0}..{1}" -f $HistoryStartRef, $HistoryEndRef),
      ("{0}..{1}" -f $HistoryEndRef, $HistoryStartRef)
    )
  } else {
    @($HistoryStartRef)
  }

  $selectedRangeSpec = $null
  $commits = @()
  foreach ($rangeSpec in $rangeCandidates) {
    $commitOutput = & git --no-pager log --format='%H' $rangeSpec -- $repoRelativePath 2>$null
    if ($LASTEXITCODE -ne 0) {
      continue
    }

    $candidateCommits = @($commitOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($candidateCommits.Count -gt $commits.Count) {
      $commits = $candidateCommits
      $selectedRangeSpec = $rangeSpec
    }
  }

  if ($null -eq $selectedRangeSpec) {
    throw ("Failed to resolve commit history for refs '{0}' and '{1}' and path '{2}'." -f $HistoryStartRef, $HistoryEndRef, $repoRelativePath)
  }

  $commitSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($commit in @($commits)) {
    [void]$commitSet.Add([string]$commit)
  }

  foreach ($endpointRef in @($HistoryStartRef, $HistoryEndRef)) {
    if ([string]::IsNullOrWhiteSpace($endpointRef)) {
      continue
    }
    if ($commitSet.Contains([string]$endpointRef)) {
      continue
    }

    $endpointFiles = & git --no-pager show --pretty='' --name-only $endpointRef -- $repoRelativePath 2>$null
    if ($LASTEXITCODE -ne 0) {
      continue
    }

    $touchesPath = @($endpointFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($touchesPath) {
      $commits += [string]$endpointRef
      [void]$commitSet.Add([string]$endpointRef)
    }
  }

  if ($HistoryMaxPairs -gt 0 -and $commits.Count -gt $HistoryMaxPairs) {
    $commits = @($commits | Select-Object -First $HistoryMaxPairs)
  }

  $bundle = [ordered]@{
    schema = 'comparevi/vi-history-bundle@v1'
    historyViPath = $repoRelativePath
    startRef = $HistoryStartRef
    endRef = $HistoryEndRef
    rangeSpecUsed = $selectedRangeSpec
    commitCount = $commits.Count
    commits = $commits
  }

  $bundlePath = Join-Path $RunDir ("vi-history-bundle-{0}.json" -f $LaneName)
  $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bundlePath -Encoding utf8

  return [pscustomobject]@{
    path = $bundlePath
    bundle = $bundle
  }
}

function Test-VIHistoryBundlesEquivalent {
  param(
    [Parameter(Mandatory = $true)]$FirstBundle,
    [Parameter(Mandatory = $true)]$SecondBundle
  )

  if ($null -eq $FirstBundle -or $null -eq $SecondBundle) {
    return $false
  }

  $first = $FirstBundle.bundle
  $second = $SecondBundle.bundle

  if ($first.commitCount -ne $second.commitCount) { return $false }
  if ([string]$first.historyViPath -ne [string]$second.historyViPath) { return $false }
  if ([string]$first.startRef -ne [string]$second.startRef) { return $false }
  if ([string]$first.endRef -ne [string]$second.endRef) { return $false }

  $firstCommits = @($first.commits)
  $secondCommits = @($second.commits)
  if ($firstCommits.Count -ne $secondCommits.Count) { return $false }
  for ($i = 0; $i -lt $firstCommits.Count; $i++) {
    if ([string]$firstCommits[$i] -ne [string]$secondCommits[$i]) {
      return $false
    }
  }

  return $true
}

function Ensure-DockerOsType {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('linux', 'windows')][string]$TargetOsType,
    [int]$TimeoutSeconds = 180
  )

  $currentOsType = $null
  try {
    $currentOsType = (& docker info --format '{{.OSType}}' 2>$null).Trim()
  } catch {
    throw 'docker info is unavailable. Ensure Docker Desktop is running and reachable.'
  }

  if (-not $currentOsType) {
    throw 'unable to determine Docker OSType from docker info.'
  }

  if ($currentOsType -eq $TargetOsType) {
    return @{
      osType = $currentOsType
      switched = $false
      fromOsType = $currentOsType
      targetOsType = $TargetOsType
    }
  }

  $fromOsType = $currentOsType

  $dockerCli = Join-Path $env:ProgramFiles 'Docker\Docker\DockerCli.exe'
  if (-not (Test-Path -LiteralPath $dockerCli -PathType Leaf)) {
    throw ("DockerCli.exe not found at expected path: {0}" -f $dockerCli)
  }

  if ($TargetOsType -eq 'linux') {
    & $dockerCli -SwitchLinuxEngine
  } else {
    & $dockerCli -SwitchWindowsEngine
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 3
    try {
      $currentOsType = (& docker info --format '{{.OSType}}' 2>$null).Trim()
    } catch {
      $currentOsType = $null
    }
  } while (($currentOsType -ne $TargetOsType) -and (Get-Date) -lt $deadline)

  if ($currentOsType -ne $TargetOsType) {
    throw ("timed out waiting for Docker OSType '{0}'. Last detected OSType was '{1}'." -f $TargetOsType, $currentOsType)
  }

  return @{
    osType = $currentOsType
    switched = $true
    fromOsType = $fromOsType
    targetOsType = $TargetOsType
  }
}

function Invoke-Lane {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Description,
    [Parameter(Mandatory = $true)][scriptblock]$Command,
    [switch]$Selected
  )

  if (-not $Selected.IsPresent) {
    return [pscustomobject]@{
      name = $Name
      description = $Description
      selected = $false
      status = 'skipped'
      startedAtUtc = $null
      completedAtUtc = $null
      durationSeconds = 0
      exitCode = 0
      notes = @('lane not selected by LaneScope')
      artifacts = @{}
    }
  }

  $started = (Get-Date).ToUniversalTime()
  $status = 'pass'
  $exitCode = 0
  $notes = New-Object System.Collections.Generic.List[string]
  $artifacts = @{}

  Write-Host ("[matrix] lane={0} start" -f $Name) -ForegroundColor Cyan
  try {
    $result = & $Command
    $resultDictionary = $null
    if ($result -is [System.Collections.IDictionary]) {
      $resultDictionary = $result
    } elseif ($null -ne $result -and $result -is [System.Collections.IEnumerable] -and -not ($result -is [string])) {
      foreach ($candidate in @($result)) {
        if ($candidate -is [System.Collections.IDictionary]) {
          $resultDictionary = $candidate
        }
      }
    }

    if ($null -ne $resultDictionary) {
      foreach ($key in $resultDictionary.Keys) {
        if ($key -eq 'notes') {
          foreach ($entry in @($resultDictionary[$key])) {
            if ($entry) { $notes.Add([string]$entry) | Out-Null }
          }
        } elseif ($key -eq 'artifacts') {
          $artifacts = $resultDictionary[$key]
        }
      }
    }

    $exitCode = if ($LASTEXITCODE -is [int]) { $LASTEXITCODE } else { 0 }
    if ($exitCode -ne 0) {
      $status = 'fail'
      $notes.Add(("lane command exited with code {0}" -f $exitCode)) | Out-Null
    }
  } catch {
    $status = 'fail'
    $exitCode = if ($LASTEXITCODE -is [int] -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 1 }
    $notes.Add($_.Exception.Message) | Out-Null
  }

  $completed = (Get-Date).ToUniversalTime()
  $duration = [math]::Round((New-TimeSpan -Start $started -End $completed).TotalSeconds, 2)

  Write-Host ("[matrix] lane={0} status={1} exit={2} duration={3}s" -f $Name, $status, $exitCode, $duration) -ForegroundColor $(if ($status -eq 'pass') { 'Green' } else { 'Yellow' })

  return [pscustomobject]@{
    name = $Name
    description = $Description
    selected = $true
    status = $status
    startedAtUtc = $started.ToString('o')
    completedAtUtc = $completed.ToString('o')
    durationSeconds = $duration
    exitCode = $exitCode
    notes = @($notes)
    artifacts = $artifacts
  }
}

$repoRoot = Resolve-RepoRoot
$resultsRootResolved = Resolve-PathFromRepo -RepoRoot $repoRoot -Value $ResultsRoot
Ensure-Directory -Path $resultsRootResolved

$timestamp = (Get-Date -Format 'yyyyMMddTHHmmss')
$runDir = Join-Path $resultsRootResolved $timestamp
Ensure-Directory -Path $runDir

$linuxSelected = $LaneScope -in @('all', 'linux')
$windowsSelected = $LaneScope -in @('all', 'windows')
$hostSelected = $LaneScope -in @('all', 'host')

Assert-NoLabVIEW2025Path -PathValue $HostLabVIEWPath -ParameterName 'HostLabVIEWPath'
Assert-NoLabVIEW2025Path -PathValue $ContainerLabVIEWPath -ParameterName 'ContainerLabVIEWPath'

$baseViResolved = Resolve-PathFromRepo -RepoRoot $repoRoot -Value $BaseVi
$headViResolved = Resolve-PathFromRepo -RepoRoot $repoRoot -Value $HeadVi

$lanes = New-Object System.Collections.Generic.List[object]

$linuxLane = Invoke-Lane -Name 'linux-tools-image' -Description 'Docker Desktop linux lane: non-LV checks and tooling parity.' -Selected:$linuxSelected -Command {
  $dockerState = Ensure-DockerOsType -TargetOsType 'linux'

  $linuxScript = Join-Path $repoRoot 'tools' 'Run-NILinuxContainerCompare.ps1'
  $linuxArgs = @(
    '-NoLogo','-NoProfile','-File', $linuxScript,
    '-BaseVi', $baseViResolved,
    '-HeadVi', $headViResolved,
    '-ReportType', 'html'
  )
  $linuxContainerLvPathRequested = if (-not [string]::IsNullOrWhiteSpace($ContainerLabVIEWPath)) { $ContainerLabVIEWPath } else { $null }
  $linuxContainerLvPath = Resolve-ContainerLabVIEWPathForOs -PathValue $linuxContainerLvPathRequested -TargetOs 'linux'
  if (-not [string]::IsNullOrWhiteSpace($linuxContainerLvPath)) {
    $linuxArgs += '-LabVIEWPath'
    $linuxArgs += $linuxContainerLvPath
  }
  & pwsh @linuxArgs

  $capturePath = Join-Path $repoRoot 'tests' 'results/ni-linux-container/ni-linux-container-capture.json'
  $reportPath = Join-Path $repoRoot 'tests' 'results/ni-linux-container/compare-report.html'
  $artifacts = @{}
  $captureGateOutcome = $null
  if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
    try {
      $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
      $captureGateOutcome = [string]$capture.gateOutcome
      if ($LASTEXITCODE -ne 0 -and $captureGateOutcome -eq 'pass') {
        $global:LASTEXITCODE = 0
      }
    } catch {}
  }
  if (Test-Path -LiteralPath $capturePath -PathType Leaf) { $artifacts['capture'] = $capturePath }
  if (Test-Path -LiteralPath $reportPath -PathType Leaf) { $artifacts['reportHtml'] = $reportPath }

  return @{
    notes = @(
      ("dockerOsType={0}" -f $dockerState.osType),
      ("dockerEngineAutoSwitched={0}" -f $dockerState.switched.ToString().ToLowerInvariant()),
      ("dockerEngineFrom={0}" -f $dockerState.fromOsType),
      ("dockerEngineTarget={0}" -f $dockerState.targetOsType),
      ("containerLabVIEWPathRequested={0}" -f $linuxContainerLvPathRequested),
      ("containerLabVIEWPathEffective={0}" -f $linuxContainerLvPath),
      ("captureGateOutcome={0}" -f $captureGateOutcome),
      ("baseVi={0}" -f $baseViResolved),
      ("headVi={0}" -f $headViResolved)
    )
    artifacts = $artifacts
  }
}
$lanes.Add($linuxLane) | Out-Null

$windowsLane = Invoke-Lane -Name 'windows-ni-container' -Description 'Docker Desktop windows NI lane: single compare + report capture.' -Selected:$windowsSelected -Command {
  $dockerState = Ensure-DockerOsType -TargetOsType 'windows'

  $windowsScript = Join-Path $repoRoot 'tools' 'Run-NIWindowsContainerCompare.ps1'
  $windowsArgs = @(
    '-NoLogo','-NoProfile','-File', $windowsScript,
    '-BaseVi', $baseViResolved,
    '-HeadVi', $headViResolved,
    '-ReportType', 'html'
  )
  $containerLvPathRequested = if (-not [string]::IsNullOrWhiteSpace($ContainerLabVIEWPath)) { $ContainerLabVIEWPath } else { $null }
  $containerLvPath = Resolve-ContainerLabVIEWPathForOs -PathValue $containerLvPathRequested -TargetOs 'windows'
  if (-not [string]::IsNullOrWhiteSpace($containerLvPath)) {
    $windowsArgs += '-LabVIEWPath'
    $windowsArgs += $containerLvPath
  }
  & pwsh @windowsArgs

  $capturePath = Join-Path $repoRoot 'tests' 'results/ni-windows-container/ni-windows-container-capture.json'
  $reportPath = Join-Path $repoRoot 'tests' 'results/ni-windows-container/compare-report.html'
  $artifacts = @{}
  $captureGateOutcome = $null
  if (Test-Path -LiteralPath $capturePath -PathType Leaf) {
    try {
      $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
      $captureGateOutcome = [string]$capture.gateOutcome
      if ($LASTEXITCODE -ne 0 -and $captureGateOutcome -eq 'pass') {
        $global:LASTEXITCODE = 0
      }
    } catch {}
  }
  if (Test-Path -LiteralPath $capturePath -PathType Leaf) { $artifacts['capture'] = $capturePath }
  if (Test-Path -LiteralPath $reportPath -PathType Leaf) { $artifacts['reportHtml'] = $reportPath }

  return @{
    notes = @(
      ("dockerOsType={0}" -f $dockerState.osType),
      ("dockerEngineAutoSwitched={0}" -f $dockerState.switched.ToString().ToLowerInvariant()),
      ("dockerEngineFrom={0}" -f $dockerState.fromOsType),
      ("dockerEngineTarget={0}" -f $dockerState.targetOsType),
      ("containerLabVIEWPathRequested={0}" -f $containerLvPathRequested),
      ("containerLabVIEWPathEffective={0}" -f $containerLvPath),
      ("captureGateOutcome={0}" -f $captureGateOutcome),
      ("baseVi={0}" -f $baseViResolved),
      ("headVi={0}" -f $headViResolved)
    )
    artifacts = $artifacts
  }
}
$lanes.Add($windowsLane) | Out-Null

$linuxHistoryBundle = $null
if ($linuxSelected -and $linuxLane.status -eq 'pass') {
  $linuxHistoryBundle = New-VIHistoryBundle -RepoRoot $repoRoot -RunDir $runDir -LaneName 'linux' -HistoryViPath $HistoryViPath -HistoryStartRef $HistoryStartRef -HistoryEndRef $HistoryEndRef -HistoryMaxPairs $HistoryMaxPairs
  if (-not ($linuxLane.artifacts -is [System.Collections.IDictionary])) {
    $linuxLane.artifacts = @{}
  }
  $linuxLane.artifacts['viHistoryBundle'] = $linuxHistoryBundle.path
  $linuxLane.notes = @($linuxLane.notes + ("viHistoryBundle={0}" -f $linuxHistoryBundle.path) + ("viHistoryBundleCommitCount={0}" -f $linuxHistoryBundle.bundle.commitCount))
}

$windowsHistoryBundle = $null
if ($windowsSelected -and $windowsLane.status -eq 'pass') {
  $windowsHistoryBundle = New-VIHistoryBundle -RepoRoot $repoRoot -RunDir $runDir -LaneName 'windows' -HistoryViPath $HistoryViPath -HistoryStartRef $HistoryStartRef -HistoryEndRef $HistoryEndRef -HistoryMaxPairs $HistoryMaxPairs
  if (-not ($windowsLane.artifacts -is [System.Collections.IDictionary])) {
    $windowsLane.artifacts = @{}
  }
  $windowsLane.artifacts['viHistoryBundle'] = $windowsHistoryBundle.path
  $windowsLane.notes = @($windowsLane.notes + ("viHistoryBundle={0}" -f $windowsHistoryBundle.path) + ("viHistoryBundleCommitCount={0}" -f $windowsHistoryBundle.bundle.commitCount))
}

$hostPreconditionsOk = $true
$hostPreconditionNotes = New-Object System.Collections.Generic.List[string]
if ($hostSelected) {
  if (-not $linuxSelected -or -not $windowsSelected) {
    $hostPreconditionsOk = $false
    $hostPreconditionNotes.Add('Host lane requires both linux and windows container lanes selected first.') | Out-Null
  }
  if ($linuxLane.status -ne 'pass' -or $windowsLane.status -ne 'pass') {
    $hostPreconditionsOk = $false
    $hostPreconditionNotes.Add('Host lane requires both container lanes to pass before host execution.') | Out-Null
  }
  if ($null -eq $linuxHistoryBundle -or $null -eq $windowsHistoryBundle) {
    $hostPreconditionsOk = $false
    $hostPreconditionNotes.Add('Host lane requires both container history bundles to be generated.') | Out-Null
  } else {
    if (-not (Test-VIHistoryBundlesEquivalent -FirstBundle $linuxHistoryBundle -SecondBundle $windowsHistoryBundle)) {
      $hostPreconditionsOk = $false
      $hostPreconditionNotes.Add('Container VI-history bundles are not identical.') | Out-Null
    }
    if ([int]$linuxHistoryBundle.bundle.commitCount -lt 2 -or [int]$windowsHistoryBundle.bundle.commitCount -lt 2) {
      $hostPreconditionsOk = $false
      $hostPreconditionNotes.Add('Container VI-history bundles must include at least 2 commits in the selected range.') | Out-Null
    }
  }
}

$hostLane = Invoke-Lane -Name 'host-history-report' -Description 'Host lane: commit-range compare and consolidated history report.' -Selected:$hostSelected -Command {
  if (-not $hostPreconditionsOk) {
    throw ("Host lane blocked until container preconditions are satisfied: {0}" -f ([string]::Join('; ', @($hostPreconditionNotes))))
  }

  $historyScript = Join-Path $repoRoot 'scripts' 'Run-VIHistory.ps1'
  $historyArgs = @(
    '-NoLogo','-NoProfile','-File', $historyScript,
    '-ViPath', $HistoryViPath,
    '-StartRef', $HistoryStartRef,
    '-MaxPairs', [string]$HistoryMaxPairs,
    '-HtmlReport'
  )
  if (-not [string]::IsNullOrWhiteSpace($HistoryEndRef)) {
    $historyArgs += '-EndRef'
    $historyArgs += $HistoryEndRef
  }
  if (-not [string]::IsNullOrWhiteSpace($HostLabVIEWPath)) {
    $historyArgs += '-LabVIEWPath'
    $historyArgs += $HostLabVIEWPath
  }
  & pwsh @historyArgs

  $historyRoot = Join-Path $repoRoot 'tests' 'results/ref-compare/history'
  $contextPath = Join-Path $historyRoot 'history-context.json'
  $reportPath = Join-Path $historyRoot 'history-report.md'
  $reportHtmlPath = Join-Path $historyRoot 'history-report.html'
  $manifestPath = Join-Path $historyRoot 'manifest.json'

  $artifacts = @{}
  if (Test-Path -LiteralPath $contextPath -PathType Leaf) { $artifacts['historyContext'] = $contextPath }
  if (Test-Path -LiteralPath $manifestPath -PathType Leaf) { $artifacts['manifest'] = $manifestPath }
  if (Test-Path -LiteralPath $reportPath -PathType Leaf) { $artifacts['reportMarkdown'] = $reportPath }
  if (Test-Path -LiteralPath $reportHtmlPath -PathType Leaf) { $artifacts['reportHtml'] = $reportHtmlPath }

  return @{
    notes = @(
      ("containerPreconditions=passed"),
      ("viPath={0}" -f $HistoryViPath),
      ("startRef={0}" -f $HistoryStartRef),
      ("endRef={0}" -f $HistoryEndRef),
      ("hostLabVIEWPath={0}" -f $HostLabVIEWPath),
      ("maxPairs={0}" -f $HistoryMaxPairs)
    )
    artifacts = $artifacts
  }
}
$lanes.Add($hostLane) | Out-Null

$selectedLanes = @($lanes | Where-Object { $_.selected })
$failedLanes = @($selectedLanes | Where-Object { $_.status -eq 'fail' })
$overallStatus = if ($failedLanes.Count -eq 0) { 'pass' } else { 'fail' }

$summary = [ordered]@{
  schema = 'comparevi/validation-matrix@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  laneScope = $LaneScope
  inputs = [ordered]@{
    baseVi = $BaseVi
    headVi = $HeadVi
    historyViPath = $HistoryViPath
    historyStartRef = $HistoryStartRef
    historyEndRef = $HistoryEndRef
    historyMaxPairs = $HistoryMaxPairs
    hostLabVIEWPath = $HostLabVIEWPath
    containerLabVIEWPath = $ContainerLabVIEWPath
  }
  outcome = [ordered]@{
    status = $overallStatus
    selectedLaneCount = $selectedLanes.Count
    failedLaneCount = $failedLanes.Count
  }
  lanes = $lanes.ToArray()
}

$jsonPath = Join-Path $runDir 'validation-matrix-summary.json'
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$mdPath = Join-Path $runDir 'validation-matrix-summary.md'
$mdLines = New-Object System.Collections.Generic.List[string]
$mdLines.Add('# Validation Matrix Summary') | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add(("- Generated (UTC): {0}" -f $summary.generatedAtUtc)) | Out-Null
$mdLines.Add(("- Lane scope: {0}" -f $LaneScope)) | Out-Null
$mdLines.Add(("- Outcome: **{0}**" -f $summary.outcome.status)) | Out-Null
$mdLines.Add(("- Selected lanes: {0}" -f $summary.outcome.selectedLaneCount)) | Out-Null
$mdLines.Add(("- Failed lanes: {0}" -f $summary.outcome.failedLaneCount)) | Out-Null
$mdLines.Add('') | Out-Null
$mdLines.Add('## Lanes') | Out-Null
$mdLines.Add('') | Out-Null
foreach ($lane in $lanes) {
  $mdLines.Add(("### {0}" -f $lane.name)) | Out-Null
  $mdLines.Add(("- Description: {0}" -f $lane.description)) | Out-Null
  $mdLines.Add(("- Selected: {0}" -f $lane.selected)) | Out-Null
  $mdLines.Add(("- Status: **{0}**" -f $lane.status)) | Out-Null
  $mdLines.Add(("- Exit code: {0}" -f $lane.exitCode)) | Out-Null
  if ($lane.durationSeconds -ne $null) {
    $mdLines.Add(("- Duration (s): {0}" -f $lane.durationSeconds)) | Out-Null
  }
  if ($lane.notes -and $lane.notes.Count -gt 0) {
    $mdLines.Add('- Notes:') | Out-Null
    foreach ($note in $lane.notes) {
      $mdLines.Add(("  - {0}" -f $note)) | Out-Null
    }
  }
  if ($lane.artifacts) {
    $artifactKeys = @()
    $isDictionary = $lane.artifacts -is [System.Collections.IDictionary]
    if ($isDictionary) {
      $artifactKeys = @($lane.artifacts.Keys)
    } else {
      $artifactKeys = @($lane.artifacts.PSObject.Properties.Name)
    }
    if ($artifactKeys.Count -gt 0) {
      $mdLines.Add('- Artifacts:') | Out-Null
      foreach ($key in $artifactKeys) {
        $value = if ($isDictionary) { $lane.artifacts[$key] } else { $lane.artifacts.$key }
        $mdLines.Add(("  - {0}: {1}" -f $key, $value)) | Out-Null
      }
    }
  }
  $mdLines.Add('') | Out-Null
}

$mdLines | Set-Content -LiteralPath $mdPath -Encoding utf8

$latestDir = Join-Path $resultsRootResolved 'latest'
if (Test-Path -LiteralPath $latestDir -PathType Container) {
  Remove-Item -LiteralPath $latestDir -Recurse -Force -ErrorAction SilentlyContinue
}
Copy-Item -LiteralPath $runDir -Destination $latestDir -Recurse -Force

Write-Host ("[matrix] summary json: {0}" -f $jsonPath) -ForegroundColor Cyan
Write-Host ("[matrix] summary md: {0}" -f $mdPath) -ForegroundColor Cyan

if ($summary.outcome.status -ne 'pass' -and -not $ContinueOnLaneFailure.IsPresent) {
  Write-Error '[matrix] validation matrix failed.'
  exit 1
}

if ($summary.outcome.status -ne 'pass') {
  Write-Warning '[matrix] validation matrix completed with lane failures (allowed by -ContinueOnLaneFailure).'
}
