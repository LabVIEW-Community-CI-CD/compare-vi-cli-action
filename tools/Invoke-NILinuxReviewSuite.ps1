#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BaseVi,

  [Parameter(Mandatory = $true)]
  [string]$HeadVi,

  [string]$ResultsRoot = 'results/fixture-drift/ni-linux-container',
  [string]$Image = 'nationalinstruments/labview:2026q1-linux',
  [string]$LabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview',
  [string]$RepoRoot = '',
  [string]$HistoryTargetPath = 'fixtures/vi-attr/Head.vi',
  [string]$HistoryBranchRef = 'HEAD',
  [string]$HistoryBaselineRef = '',
  [ValidateRange(1, 64)]
  [int]$HistoryMaxPairs = 2,
  [ValidateRange(1, 4096)]
  [int]$HistoryMaxCommitCount = 64,
  [string]$HistoryReviewReceiptPath = '',
  [ValidateRange(0, 8)]
  [int]$FlagScenarioParallelism = 0,
  [string]$HostRamBudgetPath = '',
  [ValidateRange(30, 900)]
  [int]$TimeoutSeconds = 240,
  [ValidateRange(5, 120)]
  [int]$HeartbeatSeconds = 15,
  [ValidateRange(30, 600)]
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [ValidateRange(1, 30)]
  [int]$RuntimeEngineReadyPollSeconds = 3,
  [string]$ReuseContainerName = '',
  [string]$ReuseRepoHostPath = '',
  [string]$ReuseRepoContainerPath = '/opt/comparevi/source',
  [string]$ReuseResultsHostPath = '',
  [string]$ReuseResultsContainerPath = '/opt/comparevi/vi-history/results',
  [string[]]$RuntimeInjectionMount = @(),
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$GitHubStepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowEmptyString()][string]$Value,
    [AllowEmptyString()][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $dest = [System.IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  Add-Content -LiteralPath $dest -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Get-RelativeArtifactPath {
  param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return [System.IO.Path]::GetRelativePath($RootPath, $Path).Replace('\', '/')
}

function Write-FlagCombinationCertificationArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$ResultsRoot,
    [Parameter(Mandatory = $true)][string]$Image,
    [AllowNull()][object[]]$ScenarioResults,
    [AllowNull()]$ParallelBudget
  )

  $flagCombinationResults = @(
    @($ScenarioResults) | Where-Object {
      $_ -and
      $_.PSObject.Properties['kind'] -and
      [string]::Equals([string]$_.kind, 'flag-combination', [System.StringComparison]::OrdinalIgnoreCase)
    }
  )
  if ($flagCombinationResults.Count -eq 0) {
    throw 'NI Linux review suite resolved no flag-combination scenarios for certification.'
  }

  $jsonPath = Join-Path $ResultsRoot 'flag-combination-certification.json'
  $markdownPath = Join-Path $ResultsRoot 'flag-combination-certification.md'
  $htmlPath = Join-Path $ResultsRoot 'flag-combination-certification.html'

  $normalizedScenarios = @(
    $flagCombinationResults | ForEach-Object {
      [ordered]@{
        name = [string]$_.name
        requestedFlagsLabel = [string]$_.requestedFlagsLabel
        requestedFlags = @($_.requestedFlags | ForEach-Object { [string]$_ })
        flagsUsed = @($_.flagsUsed | ForEach-Object { [string]$_ })
        executionMode = [string]$_.executionMode
        resultClass = [string]$_.resultClass
        gateOutcome = [string]$_.gateOutcome
        reportPath = Get-RelativeArtifactPath -RootPath $ResultsRoot -Path ([string]$_.reportPath)
        capturePath = Get-RelativeArtifactPath -RootPath $ResultsRoot -Path ([string]$_.capturePath)
        runtimeSnapshotPath = Get-RelativeArtifactPath -RootPath $ResultsRoot -Path ([string]$_.runtimeSnapshotPath)
      }
    }
  )

  $payload = [ordered]@{
    schema = 'ni-linux-flag-combination-certification@v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    image = $Image
    resultsRoot = $ResultsRoot
    laneClass = 'certification'
    blocking = $false
    planeApplicability = @('linux-proof')
    futureParityPlanes = @('windows-mirror-proof', 'host-32bit-shadow')
    summary = [ordered]@{
      totalScenarios = $normalizedScenarios.Count
      passingScenarios = @($normalizedScenarios | Where-Object { [string]::Equals([string]$_.gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase) }).Count
      failingScenarios = @($normalizedScenarios | Where-Object { -not [string]::Equals([string]$_.gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase) }).Count
    }
    parallelBudget = $ParallelBudget
    scenarios = @($normalizedScenarios)
  }
  $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8

  $markdownLines = @(
    '# NI Linux flag-combination certification',
    '',
    '- Lane class: `certification`',
    '- Blocking: `false`',
    ('- Image: `{0}`' -f $Image),
    ('- Plane applicability: `{0}`' -f ([string]::Join(', ', @($payload.planeApplicability)))),
    ('- Future parity planes: `{0}`' -f ([string]::Join(', ', @($payload.futureParityPlanes)))),
    ('- Parallelism: `requested={0}; actual={1}; source={2}`' -f
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['requestedParallelism']) { [string]$ParallelBudget.requestedParallelism } else { '0' }),
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['actualParallelism']) { [string]$ParallelBudget.actualParallelism } else { '1' }),
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['decisionSource']) { [string]$ParallelBudget.decisionSource } else { 'serial-default' })),
    ('- Total scenarios: `{0}`' -f $payload.summary.totalScenarios),
    ('- Passing scenarios: `{0}`' -f $payload.summary.passingScenarios),
    ('- Failing scenarios: `{0}`' -f $payload.summary.failingScenarios),
    '',
    '| Scenario | Requested Flags | Result | Report | Capture | Runtime |',
    '| --- | --- | --- | --- | --- | --- |'
  )
  foreach ($scenario in @($normalizedScenarios)) {
    $requestedFlagsLabel = if ([string]::IsNullOrWhiteSpace([string]$scenario.requestedFlagsLabel)) { '(none)' } else { [string]$scenario.requestedFlagsLabel }
    $markdownLines += ('| {0} | {1} | {2}/{3} | [report](./{4}) | [capture](./{5}) | [runtime](./{6}) |' -f
        $scenario.name,
        $requestedFlagsLabel,
        $scenario.resultClass,
        $scenario.gateOutcome,
        $scenario.reportPath,
        $scenario.capturePath,
        $scenario.runtimeSnapshotPath)
  }
  $markdownLines -join "`n" | Set-Content -LiteralPath $markdownPath -Encoding utf8

  $htmlLines = @(
    '<html><body><h1>NI Linux flag-combination certification</h1>',
    ('<p>Lane class: <code>certification</code><br/>Blocking: <code>false</code><br/>Image: <code>{0}</code><br/>Plane applicability: <code>{1}</code><br/>Future parity planes: <code>{2}</code></p>' -f
      $Image,
      [string]::Join(', ', @($payload.planeApplicability)),
      [string]::Join(', ', @($payload.futureParityPlanes))),
    ('<p>Parallelism: <code>requested={0}; actual={1}; source={2}</code></p>' -f
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['requestedParallelism']) { [string]$ParallelBudget.requestedParallelism } else { '0' }),
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['actualParallelism']) { [string]$ParallelBudget.actualParallelism } else { '1' }),
      $(if ($ParallelBudget -and $ParallelBudget.PSObject.Properties['decisionSource']) { [string]$ParallelBudget.decisionSource } else { 'serial-default' })),
    ('<p>Total scenarios: <code>{0}</code><br/>Passing scenarios: <code>{1}</code><br/>Failing scenarios: <code>{2}</code></p>' -f
      $payload.summary.totalScenarios,
      $payload.summary.passingScenarios,
      $payload.summary.failingScenarios),
    '<table border="1" cellspacing="0" cellpadding="4">',
    '<thead><tr><th>Scenario</th><th>Requested Flags</th><th>Result</th><th>Report</th><th>Capture</th><th>Runtime</th></tr></thead>',
    '<tbody>'
  )
  foreach ($scenario in @($normalizedScenarios)) {
    $requestedFlagsLabel = if ([string]::IsNullOrWhiteSpace([string]$scenario.requestedFlagsLabel)) { '(none)' } else { [string]$scenario.requestedFlagsLabel }
    $htmlLines += ('<tr><td>{0}</td><td>{1}</td><td>{2}/{3}</td><td><a href="./{4}">report</a></td><td><a href="./{5}">capture</a></td><td><a href="./{6}">runtime</a></td></tr>' -f
        $scenario.name,
        $requestedFlagsLabel,
        $scenario.resultClass,
        $scenario.gateOutcome,
        $scenario.reportPath,
        $scenario.capturePath,
        $scenario.runtimeSnapshotPath)
  }
  $htmlLines += '</tbody></table></body></html>'
  $htmlLines -join "`n" | Set-Content -LiteralPath $htmlPath -Encoding utf8

  return [pscustomobject]@{
    schema = 'ni-linux-flag-combination-certification@v1'
    jsonPath = $jsonPath
    markdownPath = $markdownPath
    htmlPath = $htmlPath
  }
}

function Resolve-HistoryRefSelection {
  param(
    [AllowEmptyString()][string]$RequestedBranchRef,
    [AllowEmptyString()][string]$RequestedBaselineRef
  )

  $effectiveBranchRef = $RequestedBranchRef
  $effectiveBaselineRef = $RequestedBaselineRef
  $selectionSource = 'parameters'
  $branchRefNeedsResolution = [string]::IsNullOrWhiteSpace($effectiveBranchRef) -or
    [string]::Equals($effectiveBranchRef, 'HEAD', [System.StringComparison]::OrdinalIgnoreCase)
  $baselineRefNeedsResolution = [string]::IsNullOrWhiteSpace($effectiveBaselineRef)

  if ($branchRefNeedsResolution -or $baselineRefNeedsResolution) {
    $eventPath = $env:GITHUB_EVENT_PATH
    $eventName = $env:GITHUB_EVENT_NAME
    if (
      -not [string]::IsNullOrWhiteSpace($eventPath) -and
      -not [string]::IsNullOrWhiteSpace($eventName) -and
      [string]::Equals($eventName, 'pull_request', [System.StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $eventPath -PathType Leaf)
    ) {
      try {
        $eventPayload = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json -Depth 32
        if ($eventPayload -and $eventPayload.pull_request) {
          if ($branchRefNeedsResolution -and $eventPayload.pull_request.head -and -not [string]::IsNullOrWhiteSpace([string]$eventPayload.pull_request.head.sha)) {
            $effectiveBranchRef = [string]$eventPayload.pull_request.head.sha
            $selectionSource = 'github-pull-request'
          }
          if ($baselineRefNeedsResolution -and $eventPayload.pull_request.base -and -not [string]::IsNullOrWhiteSpace([string]$eventPayload.pull_request.base.sha)) {
            $effectiveBaselineRef = [string]$eventPayload.pull_request.base.sha
            $selectionSource = 'github-pull-request'
          }
        }
      } catch {
        Write-Warning ("Unable to resolve GitHub pull_request refs from GITHUB_EVENT_PATH '{0}': {1}" -f $eventPath, $_.Exception.Message)
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($effectiveBranchRef)) {
    $effectiveBranchRef = 'HEAD'
  }

  return [pscustomobject]@{
    requestedBranchRef = [string]$RequestedBranchRef
    requestedBaselineRef = [string]$RequestedBaselineRef
    effectiveBranchRef = [string]$effectiveBranchRef
    effectiveBaselineRef = [string]$effectiveBaselineRef
    source = [string]$selectionSource
  }
}

function New-FlagScenarioDefinitions {
  $baseFlagOptions = @(
    [ordered]@{ label = 'noattr'; flag = '-noattr' },
    [ordered]@{ label = 'nofppos'; flag = '-nofppos' },
    [ordered]@{ label = 'nobdcosm'; flag = '-nobdcosm' }
  )

  $scenarioBuffer = New-Object System.Collections.Generic.List[object]
  for ($mask = 0; $mask -lt (1 -shl $baseFlagOptions.Count); $mask++) {
    $scenarioFlags = @()
    $scenarioLabels = @()
    $selectedIndices = @()
    for ($i = 0; $i -lt $baseFlagOptions.Count; $i++) {
      if (($mask -band (1 -shl $i)) -ne 0) {
        $scenarioFlags += [string]$baseFlagOptions[$i].flag
        $scenarioLabels += [string]$baseFlagOptions[$i].label
        $selectedIndices += $i
      }
    }

    $scenarioBuffer.Add([pscustomobject]@{
      name = if ($scenarioLabels.Count -eq 0) { 'baseline' } else { [string]::Join('__', $scenarioLabels) }
      flags = @($scenarioFlags)
      requestedFlagsLabel = if ($scenarioFlags.Count -eq 0) { '(none)' } else { [string]::Join(', ', $scenarioFlags) }
      orderKey = if ($selectedIndices.Count -eq 0) { 'none' } else { [string]::Join('-', @($selectedIndices | ForEach-Object { '{0:d2}' -f $_ })) }
    }) | Out-Null
  }

  return @($scenarioBuffer | Sort-Object @{ Expression = { $_.flags.Count } }, @{ Expression = { $_.orderKey } })
}

function Get-DefaultHostRamBudgetPath {
  param([Parameter(Mandatory = $true)][string]$ResultsRoot)

  return (Join-Path $ResultsRoot 'host-ram-budget.json')
}

function Resolve-FlagScenarioParallelBudget {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ResultsRoot,
    [Parameter(Mandatory = $true)][int]$RequestedParallelism,
    [AllowEmptyString()][string]$HostRamBudgetPath,
    [AllowEmptyString()][string]$ReuseContainerName
  )

  $budgetPathResolved = if ([string]::IsNullOrWhiteSpace($HostRamBudgetPath)) {
    Get-DefaultHostRamBudgetPath -ResultsRoot $ResultsRoot
  } else {
    Resolve-AbsolutePath -Path $HostRamBudgetPath -BasePath $RepoRoot
  }

  $threadJobAvailable = $null -ne (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)
  $targetProfile = 'ni-linux-flag-combination'
  $budgetReport = $null
  $recommendedParallelism = 1
  $decisionSource = 'serial-default'
  $reason = 'deterministic-floor'

  if ($RequestedParallelism -gt 0) {
    $recommendedParallelism = [int]$RequestedParallelism
    $decisionSource = 'explicit-override'
    $reason = 'explicit-override'
  } else {
    $budgetScriptPath = Join-Path $RepoRoot 'tools' 'priority' 'host-ram-budget.mjs'
    if (-not (Test-Path -LiteralPath $budgetScriptPath -PathType Leaf)) {
      throw ("Host RAM budget helper not found: {0}" -f $budgetScriptPath)
    }

    Push-Location $RepoRoot
    try {
      & node $budgetScriptPath `
        --target-profile $targetProfile `
        --output $budgetPathResolved | Out-Host
      if ($LASTEXITCODE -ne 0) {
        throw ("host-ram-budget helper exited with code {0}" -f $LASTEXITCODE)
      }
    } finally {
      Pop-Location | Out-Null
    }

    if (-not (Test-Path -LiteralPath $budgetPathResolved -PathType Leaf)) {
      throw ("Host RAM budget helper did not emit a report: {0}" -f $budgetPathResolved)
    }

    $budgetReport = Get-Content -LiteralPath $budgetPathResolved -Raw | ConvertFrom-Json -Depth 20
    if (-not $budgetReport.selectedProfile -or -not $budgetReport.selectedProfile.PSObject.Properties['recommendedParallelism']) {
      throw ("Host RAM budget report missing selected profile recommendation: {0}" -f $budgetPathResolved)
    }
    $recommendedParallelism = [int]$budgetReport.selectedProfile.recommendedParallelism
    $decisionSource = 'host-ram-budget'
    $reason = if ($budgetReport.selectedProfile.PSObject.Properties['reasons'] -and @($budgetReport.selectedProfile.reasons).Count -gt 0) {
      [string]::Join(', ', @($budgetReport.selectedProfile.reasons | ForEach-Object { [string]$_ }))
    } else {
      'host-ram-budget'
    }
  }

  $actualParallelism = [int]$recommendedParallelism
  if ($actualParallelism -lt 1) {
    $actualParallelism = 1
  }
  if (-not $threadJobAvailable -and $actualParallelism -gt 1) {
    $actualParallelism = 1
    $reason = 'threadjob-unavailable'
  }
  if (-not [string]::IsNullOrWhiteSpace($ReuseContainerName)) {
    $actualParallelism = 1
    $reason = 'reuse-container-single-runtime'
  }

  return [pscustomobject]@{
    targetProfile = $targetProfile
    path = $budgetPathResolved
    requestedParallelism = [int]$RequestedParallelism
    recommendedParallelism = [int]$recommendedParallelism
    actualParallelism = [int]$actualParallelism
    decisionSource = $decisionSource
    reason = $reason
    threadJobAvailable = [bool]$threadJobAvailable
    report = $budgetReport
  }
}

function Select-FlagScenarioWorkerResult {
  param([AllowNull()]$InvocationResult)

  $canonicalResults = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($InvocationResult)) {
    if ($null -eq $candidate) {
      continue
    }

    $properties = $candidate.PSObject.Properties
    if (
      $properties['name'] -and
      $properties['scenarioDir'] -and
      $properties['reportPath'] -and
      $properties['capturePath'] -and
      $properties['runtimeSnapshotPath']
    ) {
      $canonicalResults.Add($candidate) | Out-Null
    }
  }

  if ($canonicalResults.Count -eq 0) {
    return $null
  }

  return $canonicalResults[$canonicalResults.Count - 1]
}

function Invoke-FlagScenarioCompares {
  param(
    [Parameter(Mandatory = $true)][object[]]$ScenarioDefinitions,
    [Parameter(Mandatory = $true)][int]$Parallelism,
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$FlagScenarioRoot,
    [Parameter(Mandatory = $true)][string]$CompareScriptPath,
    [Parameter(Mandatory = $true)][string]$BaseVi,
    [Parameter(Mandatory = $true)][string]$HeadVi,
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][string]$LabVIEWPath,
    [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
    [Parameter(Mandatory = $true)][int]$HeartbeatSeconds,
    [Parameter(Mandatory = $true)][int]$RuntimeEngineReadyTimeoutSeconds,
    [Parameter(Mandatory = $true)][int]$RuntimeEngineReadyPollSeconds,
    [AllowEmptyString()][string]$ReuseContainerName,
    [Parameter(Mandatory = $true)][string]$ReuseRepoHostPath,
    [Parameter(Mandatory = $true)][string]$ReuseRepoContainerPath,
    [Parameter(Mandatory = $true)][string]$ReuseResultsHostPath,
    [Parameter(Mandatory = $true)][string]$ReuseResultsContainerPath,
    [string[]]$RuntimeInjectionMount = @()
  )

  $worker = {
    param(
      [int]$Sequence,
      [object]$ScenarioDefinition,
      [string]$RepoRootValue,
      [string]$FlagScenarioRootValue,
      [string]$CompareScriptPathValue,
      [string]$BaseViValue,
      [string]$HeadViValue,
      [string]$ImageValue,
      [string]$LabVIEWPathValue,
      [int]$TimeoutSecondsValue,
      [int]$HeartbeatSecondsValue,
      [int]$RuntimeEngineReadyTimeoutSecondsValue,
      [int]$RuntimeEngineReadyPollSecondsValue,
      [string]$ReuseContainerNameValue,
      [string]$ReuseRepoHostPathValue,
      [string]$ReuseRepoContainerPathValue,
      [string]$ReuseResultsHostPathValue,
      [string]$ReuseResultsContainerPathValue,
      [string[]]$RuntimeInjectionMountValue
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $scenarioName = [string]$ScenarioDefinition.name
    $scenarioDir = Join-Path $FlagScenarioRootValue $scenarioName
    New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
    $reportPath = Join-Path $scenarioDir 'compare-report.html'
    $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
    $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'

    try {
      Push-Location $RepoRootValue
      try {
        & $CompareScriptPathValue `
          -BaseVi $BaseViValue `
          -HeadVi $HeadViValue `
          -Image $ImageValue `
          -ReportPath $reportPath `
          -LabVIEWPath $LabVIEWPathValue `
          -ContainerNameLabel $scenarioName `
          -Flags @($ScenarioDefinition.flags) `
          -TimeoutSeconds $TimeoutSecondsValue `
          -HeartbeatSeconds $HeartbeatSecondsValue `
          -AutoRepairRuntime:$true `
          -RuntimeEngineReadyTimeoutSeconds $RuntimeEngineReadyTimeoutSecondsValue `
          -RuntimeEngineReadyPollSeconds $RuntimeEngineReadyPollSecondsValue `
          -RuntimeSnapshotPath $runtimeSnapshotPath `
          -ReuseContainerName $ReuseContainerNameValue `
          -ReuseRepoHostPath $ReuseRepoHostPathValue `
          -ReuseRepoContainerPath $ReuseRepoContainerPathValue `
          -ReuseResultsHostPath $ReuseResultsHostPathValue `
          -ReuseResultsContainerPath $ReuseResultsContainerPathValue `
          -RuntimeInjectionMount $RuntimeInjectionMountValue
        $compareExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      } finally {
        Pop-Location | Out-Null
      }

      if ($compareExit -notin @(0, 1)) {
        throw ("NI Linux review suite scenario '{0}' compare failed (exit={1})." -f $scenarioName, $compareExit)
      }

      return [pscustomobject]@{
        sequence = [int]$Sequence
        name = $scenarioName
        requestedFlagsLabel = [string]$ScenarioDefinition.requestedFlagsLabel
        requestedFlags = @($ScenarioDefinition.flags | ForEach-Object { [string]$_ })
        scenarioDir = $scenarioDir
        reportPath = $reportPath
        runtimeSnapshotPath = $runtimeSnapshotPath
        capturePath = $capturePath
        compareExit = [int]$compareExit
        errorMessage = ''
      }
    } catch {
      return [pscustomobject]@{
        sequence = [int]$Sequence
        name = $scenarioName
        requestedFlagsLabel = [string]$ScenarioDefinition.requestedFlagsLabel
        requestedFlags = @($ScenarioDefinition.flags | ForEach-Object { [string]$_ })
        scenarioDir = $scenarioDir
        reportPath = $reportPath
        runtimeSnapshotPath = $runtimeSnapshotPath
        capturePath = $capturePath
        compareExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        errorMessage = [string]$_.Exception.Message
      }
    }
  }

  $resultBuffer = New-Object System.Collections.Generic.List[object]
  if ($Parallelism -le 1) {
    for ($i = 0; $i -lt $ScenarioDefinitions.Count; $i++) {
      $workerResult = Select-FlagScenarioWorkerResult -InvocationResult (& $worker $i $ScenarioDefinitions[$i] $RepoRoot $FlagScenarioRoot $CompareScriptPath $BaseVi $HeadVi $Image $LabVIEWPath $TimeoutSeconds $HeartbeatSeconds $RuntimeEngineReadyTimeoutSeconds $RuntimeEngineReadyPollSeconds $ReuseContainerName $ReuseRepoHostPath $ReuseRepoContainerPath $ReuseResultsHostPath $ReuseResultsContainerPath $RuntimeInjectionMount)
      if ($null -eq $workerResult) {
        throw ("NI Linux review suite scenario '{0}' worker did not emit a canonical result." -f [string]$ScenarioDefinitions[$i].name)
      }
      $resultBuffer.Add($workerResult) | Out-Null
    }
    return @($resultBuffer.ToArray() | Sort-Object sequence)
  }

  $activeJobs = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $ScenarioDefinitions.Count; $i++) {
    while ($activeJobs.Count -ge $Parallelism) {
      $completedJob = Wait-Job -Job $activeJobs.ToArray() -Any
      if ($null -eq $completedJob) {
        continue
      }
      $jobResult = Select-FlagScenarioWorkerResult -InvocationResult @(Receive-Job -Job $completedJob -ErrorAction SilentlyContinue)
      if ($jobResult) {
        $resultBuffer.Add($jobResult) | Out-Null
      }
      Remove-Job -Job $completedJob -Force -ErrorAction SilentlyContinue | Out-Null
      [void]$activeJobs.Remove($completedJob)
    }

    $job = Start-ThreadJob -ScriptBlock $worker -ArgumentList $i, $ScenarioDefinitions[$i], $RepoRoot, $FlagScenarioRoot, $CompareScriptPath, $BaseVi, $HeadVi, $Image, $LabVIEWPath, $TimeoutSeconds, $HeartbeatSeconds, $RuntimeEngineReadyTimeoutSeconds, $RuntimeEngineReadyPollSeconds, $ReuseContainerName, $ReuseRepoHostPath, $ReuseRepoContainerPath, $ReuseResultsHostPath, $ReuseResultsContainerPath, $RuntimeInjectionMount
    $activeJobs.Add($job) | Out-Null
  }

  while ($activeJobs.Count -gt 0) {
    $completedJob = Wait-Job -Job $activeJobs.ToArray() -Any
    if ($null -eq $completedJob) {
      continue
    }
    $jobResult = Select-FlagScenarioWorkerResult -InvocationResult @(Receive-Job -Job $completedJob -ErrorAction SilentlyContinue)
    if ($jobResult) {
      $resultBuffer.Add($jobResult) | Out-Null
    }
    Remove-Job -Job $completedJob -Force -ErrorAction SilentlyContinue | Out-Null
    [void]$activeJobs.Remove($completedJob)
  }

  return @($resultBuffer.ToArray() | Sort-Object sequence)
}

function Assert-CompareScenarioArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$ScenarioName,
    [Parameter(Mandatory = $true)][string]$CapturePath,
    [Parameter(Mandatory = $true)][string]$ReportPath,
    [Parameter(Mandatory = $true)][string]$RuntimeSnapshotPath,
    [Parameter(Mandatory = $true)][string]$ExpectedImage,
    [string[]]$RequestedFlags = @()
  )

  if (-not (Test-Path -LiteralPath $CapturePath -PathType Leaf)) {
    throw ("NI Linux review suite scenario '{0}' capture missing: {1}" -f $ScenarioName, $CapturePath)
  }
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw ("NI Linux review suite scenario '{0}' report missing: {1}" -f $ScenarioName, $ReportPath)
  }
  if (-not (Test-Path -LiteralPath $RuntimeSnapshotPath -PathType Leaf)) {
    throw ("NI Linux review suite scenario '{0}' runtime snapshot missing: {1}" -f $ScenarioName, $RuntimeSnapshotPath)
  }

  $capture = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json -Depth 24
  $gateOutcome = if ($capture.PSObject.Properties['gateOutcome']) { [string]$capture.gateOutcome } else { '' }
  $resultClass = if ($capture.PSObject.Properties['resultClass']) { [string]$capture.resultClass } else { '' }
  $imageUsed = if ($capture.PSObject.Properties['image']) { [string]$capture.image } else { '' }
  $commandText = if ($capture.PSObject.Properties['command']) { [string]$capture.command } else { '' }
  $containerExecutionMode = if (
    $capture.PSObject.Properties['containerExecution'] -and
    $capture.containerExecution -and
    $capture.containerExecution.PSObject.Properties['mode']
  ) {
    [string]$capture.containerExecution.mode
  } else {
    ''
  }
  $flagsUsed = @()
  if ($capture.PSObject.Properties['flags'] -and $capture.flags) {
    $flagsUsed = @($capture.flags | ForEach-Object { [string]$_ })
  }

  if (-not [string]::Equals($imageUsed, $ExpectedImage, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI Linux review suite scenario '{0}' used unexpected image: {1}" -f $ScenarioName, $imageUsed)
  }
  if (-not [string]::Equals($gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw ("NI Linux review suite scenario '{0}' did not pass (resultClass={1}, gateOutcome={2})." -f $ScenarioName, $resultClass, $gateOutcome)
  }
  if (
    [string]::IsNullOrWhiteSpace($containerExecutionMode) -and
    -not [string]::IsNullOrWhiteSpace($commandText)
  ) {
    if ($commandText -match '(?i)docker exec') {
      $containerExecutionMode = 'docker-exec'
    } elseif ($commandText -match '(?i)docker run') {
      $containerExecutionMode = 'docker-run'
    }
  }
  if ($containerExecutionMode -notin @('docker-run', 'docker-exec')) {
    throw ("NI Linux review suite scenario '{0}' did not emit a recognized docker execution mode in capture evidence." -f $ScenarioName)
  }
  if ($flagsUsed -notcontains '-Headless') {
    throw ("NI Linux review suite scenario '{0}' missing enforced -Headless flag in capture." -f $ScenarioName)
  }
  foreach ($flag in @($RequestedFlags)) {
    if ($flagsUsed -notcontains $flag) {
      throw ("NI Linux review suite scenario '{0}' missing expected flag in capture: {1}" -f $ScenarioName, $flag)
    }
  }

  return [pscustomobject]@{
    capture = $capture
    gateOutcome = $gateOutcome
    resultClass = $resultClass
    executionMode = $containerExecutionMode
    flagsUsed = @($flagsUsed)
  }
}

function Copy-ArtifactIfPresent {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  if (-not (Test-Path -LiteralPath $SourcePath)) {
    return
  }

  $destinationDir = Split-Path -Parent $DestinationPath
  if ($destinationDir -and -not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }

  Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -Recurse
}

function Test-HostPathCoveredByReuseRoots {
  param(
    [Parameter(Mandatory = $true)][string]$HostPath,
    [Parameter(Mandatory = $true)][string[]]$Roots
  )

  foreach ($root in @($Roots)) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }

    if ($HostPath.StartsWith(([System.IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
    if ([string]::Equals([System.IO.Path]::GetFullPath($HostPath), [System.IO.Path]::GetFullPath($root), [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }

  return $false
}

function Get-ReuseAccessibleFilePath {
  param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$ResultsRoot,
    [Parameter(Mandatory = $true)][string[]]$CoveredRoots,
    [Parameter(Mandatory = $true)][string]$StageName
  )

  $resolvedSourcePath = [System.IO.Path]::GetFullPath($SourcePath)
  if (Test-HostPathCoveredByReuseRoots -HostPath $resolvedSourcePath -Roots $CoveredRoots) {
    return $resolvedSourcePath
  }

  $reuseSupportRoot = Join-Path $ResultsRoot '.reuse-support'
  New-Item -ItemType Directory -Path $reuseSupportRoot -Force | Out-Null
  $destinationPath = Join-Path $reuseSupportRoot $StageName
  Copy-Item -LiteralPath $resolvedSourcePath -Destination $destinationPath -Force
  return [System.IO.Path]::GetFullPath($destinationPath)
}

$repoRootResolved = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -Path '..' -BasePath $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
}
$baseViResolved = Resolve-AbsolutePath -Path $BaseVi -BasePath $repoRootResolved
$headViResolved = Resolve-AbsolutePath -Path $HeadVi -BasePath $repoRootResolved
$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved
$historyTargetResolved = Resolve-AbsolutePath -Path $HistoryTargetPath -BasePath $repoRootResolved
$reuseRepoHostPathResolved = if ([string]::IsNullOrWhiteSpace($ReuseRepoHostPath)) { $repoRootResolved } else { Resolve-AbsolutePath -Path $ReuseRepoHostPath -BasePath $repoRootResolved }
$reuseResultsHostPathResolved = if ([string]::IsNullOrWhiteSpace($ReuseResultsHostPath)) { $resultsRootResolved } else { Resolve-AbsolutePath -Path $ReuseResultsHostPath -BasePath $repoRootResolved }
$compareScriptPath = Join-Path $PSScriptRoot 'Run-NILinuxContainerCompare.ps1'
$viHistoryBootstrapScript = Join-Path $PSScriptRoot 'NILinux-VIHistorySuiteBootstrap.sh'
$historyInspectorScript = Join-Path $PSScriptRoot 'Inspect-VIHistorySuiteArtifacts.ps1'

if (-not (Test-Path -LiteralPath $compareScriptPath -PathType Leaf)) {
  throw ("Run-NILinuxContainerCompare.ps1 not found: {0}" -f $compareScriptPath)
}
if (-not (Test-Path -LiteralPath $viHistoryBootstrapScript -PathType Leaf)) {
  throw ("NILinux-VIHistorySuiteBootstrap.sh not found: {0}" -f $viHistoryBootstrapScript)
}
if (-not (Test-Path -LiteralPath $historyInspectorScript -PathType Leaf)) {
  throw ("Inspect-VIHistorySuiteArtifacts.ps1 not found: {0}" -f $historyInspectorScript)
}
if (-not (Test-Path -LiteralPath $baseViResolved -PathType Leaf)) {
  throw ("Base VI not found: {0}" -f $baseViResolved)
}
if (-not (Test-Path -LiteralPath $headViResolved -PathType Leaf)) {
  throw ("Head VI not found: {0}" -f $headViResolved)
}
if (-not (Test-Path -LiteralPath $historyTargetResolved -PathType Leaf)) {
  throw ("VI history target not found: {0}" -f $historyTargetResolved)
}

New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null

$reuseModeEnabled = -not [string]::IsNullOrWhiteSpace($ReuseContainerName)
$reuseCoveredRoots = @($reuseRepoHostPathResolved, $reuseResultsHostPathResolved)
$baseViComparePath = if ($reuseModeEnabled) {
  Get-ReuseAccessibleFilePath -SourcePath $baseViResolved -ResultsRoot $resultsRootResolved -CoveredRoots $reuseCoveredRoots -StageName 'Base.vi'
} else {
  $baseViResolved
}
$headViComparePath = if ($reuseModeEnabled) {
  Get-ReuseAccessibleFilePath -SourcePath $headViResolved -ResultsRoot $resultsRootResolved -CoveredRoots $reuseCoveredRoots -StageName 'Head.vi'
} else {
  $headViResolved
}
$viHistoryBootstrapExecutionPath = if ($reuseModeEnabled) {
  Get-ReuseAccessibleFilePath -SourcePath $viHistoryBootstrapScript -ResultsRoot $resultsRootResolved -CoveredRoots $reuseCoveredRoots -StageName 'NILinux-VIHistorySuiteBootstrap.sh'
} else {
  $viHistoryBootstrapScript
}

$flagScenarioRoot = Join-Path $resultsRootResolved 'flag-combinations'
$historyScenarioRoot = Join-Path $resultsRootResolved 'vi-history-report'
$summaryJsonPath = Join-Path $resultsRootResolved 'review-suite-summary.json'
$summaryMarkdownPath = Join-Path $resultsRootResolved 'review-suite-summary.md'
$summaryHtmlPath = Join-Path $resultsRootResolved 'review-suite-summary.html'
$hostRamBudgetPathResolved = if ([string]::IsNullOrWhiteSpace($HostRamBudgetPath)) {
  Get-DefaultHostRamBudgetPath -ResultsRoot $resultsRootResolved
} else {
  Resolve-AbsolutePath -Path $HostRamBudgetPath -BasePath $repoRootResolved
}
$scenarioResults = @()
$knownFlagScenarios = New-FlagScenarioDefinitions
$flagScenarioParallelBudget = Resolve-FlagScenarioParallelBudget `
  -RepoRoot $repoRootResolved `
  -ResultsRoot $resultsRootResolved `
  -RequestedParallelism $FlagScenarioParallelism `
  -HostRamBudgetPath $hostRamBudgetPathResolved `
  -ReuseContainerName $ReuseContainerName
$historyRefSelection = Resolve-HistoryRefSelection -RequestedBranchRef $HistoryBranchRef -RequestedBaselineRef $HistoryBaselineRef

Write-Host ("[ni-linux-review-suite] resultsRoot={0}" -f $resultsRootResolved) -ForegroundColor Cyan
Write-Host ("[ni-linux-review-suite] historyRefSource={0} requestedBranchRef={1} requestedBaselineRef={2} effectiveBranchRef={3} effectiveBaselineRef={4} maxCommitCount={5}" -f $historyRefSelection.source, ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBranchRef)) { '(default)' } else { $historyRefSelection.requestedBranchRef })), ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBaselineRef)) { '(default)' } else { $historyRefSelection.requestedBaselineRef })), $historyRefSelection.effectiveBranchRef, ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef })), $HistoryMaxCommitCount) -ForegroundColor DarkCyan
Write-Host ("[ni-linux-review-suite] flag-scenario-parallelism requested={0} actual={1} source={2} reason={3}" -f $flagScenarioParallelBudget.requestedParallelism, $flagScenarioParallelBudget.actualParallelism, $flagScenarioParallelBudget.decisionSource, $flagScenarioParallelBudget.reason) -ForegroundColor DarkCyan

$flagScenarioOutputs = Invoke-FlagScenarioCompares `
  -ScenarioDefinitions $knownFlagScenarios `
  -Parallelism $flagScenarioParallelBudget.actualParallelism `
  -RepoRoot $repoRootResolved `
  -FlagScenarioRoot $flagScenarioRoot `
  -CompareScriptPath $compareScriptPath `
  -BaseVi $baseViComparePath `
  -HeadVi $headViComparePath `
  -Image $Image `
  -LabVIEWPath $LabVIEWPath `
  -TimeoutSeconds $TimeoutSeconds `
  -HeartbeatSeconds $HeartbeatSeconds `
  -RuntimeEngineReadyTimeoutSeconds $RuntimeEngineReadyTimeoutSeconds `
  -RuntimeEngineReadyPollSeconds $RuntimeEngineReadyPollSeconds `
  -ReuseContainerName $ReuseContainerName `
  -ReuseRepoHostPath $reuseRepoHostPathResolved `
  -ReuseRepoContainerPath $ReuseRepoContainerPath `
  -ReuseResultsHostPath $reuseResultsHostPathResolved `
  -ReuseResultsContainerPath $ReuseResultsContainerPath `
  -RuntimeInjectionMount $RuntimeInjectionMount

foreach ($scenarioOutput in @($flagScenarioOutputs)) {
  $scenarioErrorMessage = if ($scenarioOutput.PSObject.Properties['errorMessage']) {
    [string]$scenarioOutput.errorMessage
  } else {
    ''
  }
  if (-not [string]::IsNullOrWhiteSpace($scenarioErrorMessage)) {
    throw $scenarioErrorMessage
  }

  $scenarioName = [string]$scenarioOutput.name
  $scenarioDir = [string]$scenarioOutput.scenarioDir
  $reportPath = [string]$scenarioOutput.reportPath
  $runtimeSnapshotPath = [string]$scenarioOutput.runtimeSnapshotPath
  $capturePath = [string]$scenarioOutput.capturePath
  $requestedFlags = @($scenarioOutput.requestedFlags | ForEach-Object { [string]$_ })

  $scenarioCheck = Assert-CompareScenarioArtifacts `
    -ScenarioName $scenarioName `
    -CapturePath $capturePath `
    -ReportPath $reportPath `
    -RuntimeSnapshotPath $runtimeSnapshotPath `
    -ExpectedImage $Image `
    -RequestedFlags $requestedFlags

  if ([string]::Equals($scenarioName, 'baseline', [System.StringComparison]::OrdinalIgnoreCase)) {
    Copy-ArtifactIfPresent -SourcePath $reportPath -DestinationPath (Join-Path $resultsRootResolved 'compare-report.html')
    Copy-ArtifactIfPresent -SourcePath $capturePath -DestinationPath (Join-Path $resultsRootResolved 'ni-linux-container-capture.json')
    Copy-ArtifactIfPresent -SourcePath $runtimeSnapshotPath -DestinationPath (Join-Path $resultsRootResolved 'runtime-determinism.json')
    Copy-ArtifactIfPresent -SourcePath (Join-Path $scenarioDir 'ni-linux-container-stdout.txt') -DestinationPath (Join-Path $resultsRootResolved 'ni-linux-container-stdout.txt')
    Copy-ArtifactIfPresent -SourcePath (Join-Path $scenarioDir 'ni-linux-container-stderr.txt') -DestinationPath (Join-Path $resultsRootResolved 'ni-linux-container-stderr.txt')
    Copy-ArtifactIfPresent -SourcePath (Join-Path $scenarioDir 'container-export') -DestinationPath (Join-Path $resultsRootResolved 'container-export')
  }

  $scenarioResults += [pscustomobject]@{
    kind = 'flag-combination'
    name = $scenarioName
    requestedFlagsLabel = [string]$scenarioOutput.requestedFlagsLabel
    requestedFlags = @($requestedFlags)
    flagsUsed = @($scenarioCheck.flagsUsed)
    executionMode = [string]$scenarioCheck.executionMode
    gateOutcome = [string]$scenarioCheck.gateOutcome
    resultClass = [string]$scenarioCheck.resultClass
    reportPath = $reportPath
    capturePath = $capturePath
    runtimeSnapshotPath = $runtimeSnapshotPath
  }
}

$historyResultsDir = Join-Path $historyScenarioRoot 'results'
New-Item -ItemType Directory -Path $historyResultsDir -Force | Out-Null
$historyReportPath = Join-Path $historyResultsDir 'linux-compare-report.html'
$historyRuntimeSnapshotPath = Join-Path $historyScenarioRoot 'runtime-determinism.json'
$historyCapturePath = Join-Path $historyResultsDir 'ni-linux-container-capture.json'
$historyContractPath = Join-Path $historyScenarioRoot 'runtime-bootstrap.json'
$historyMarkdownPath = Join-Path $historyResultsDir 'history-report.md'
$historyHtmlPath = Join-Path $historyResultsDir 'history-report.html'
$historySummaryPath = Join-Path $historyResultsDir 'history-summary.json'
$historyReceiptPath = Join-Path $historyResultsDir 'vi-history-bootstrap-receipt.json'
$historyInspectionJsonPath = Join-Path $historyResultsDir 'history-suite-inspection.json'
$historyInspectionHtmlPath = Join-Path $historyResultsDir 'history-suite-inspection.html'
$historyReviewReceiptPathResolved = if ([string]::IsNullOrWhiteSpace($HistoryReviewReceiptPath)) {
  Join-Path $resultsRootResolved 'vi-history-review-loop-receipt.json'
} else {
  Resolve-AbsolutePath -Path $HistoryReviewReceiptPath -BasePath $repoRootResolved
}

$historyContract = [ordered]@{
  schema = 'ni-linux-runtime-bootstrap/v1'
  mode = 'vi-history-suite-smoke'
  branchRef = $historyRefSelection.effectiveBranchRef
  maxCommitCount = [int]$HistoryMaxCommitCount
  historyRef = [ordered]@{
    source = [string]$historyRefSelection.source
    requestedBranchRef = [string]$historyRefSelection.requestedBranchRef
    requestedBaselineRef = [string]$historyRefSelection.requestedBaselineRef
    effectiveBranchRef = [string]$historyRefSelection.effectiveBranchRef
    effectiveBaselineRef = [string]$historyRefSelection.effectiveBaselineRef
  }
  scriptPath = $viHistoryBootstrapExecutionPath
  viHistory = [ordered]@{
    repoPath = $repoRootResolved
    targetPath = (Get-RelativeArtifactPath -RootPath $repoRootResolved -Path $historyTargetResolved)
    resultsPath = $historyResultsDir
    baselineRef = $historyRefSelection.effectiveBaselineRef
    maxPairs = [int]$HistoryMaxPairs
  }
}
$historyContract | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $historyContractPath -Encoding utf8

Write-Host ("[ni-linux-review-suite] scenario=vi-history-report branchRef={0} baselineRef={1} target={2}" -f $historyRefSelection.effectiveBranchRef, ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef })), $historyContract.viHistory.targetPath) -ForegroundColor Cyan
Push-Location $repoRootResolved
try {
    & $compareScriptPath `
      -Image $Image `
      -ReportPath $historyReportPath `
      -LabVIEWPath $LabVIEWPath `
    -ContainerNameLabel 'vi-history-report' `
      -TimeoutSeconds $TimeoutSeconds `
      -HeartbeatSeconds $HeartbeatSeconds `
      -AutoRepairRuntime:$true `
      -RuntimeEngineReadyTimeoutSeconds $RuntimeEngineReadyTimeoutSeconds `
      -RuntimeEngineReadyPollSeconds $RuntimeEngineReadyPollSeconds `
      -RuntimeSnapshotPath $historyRuntimeSnapshotPath `
      -RuntimeBootstrapContractPath $historyContractPath `
      -ReuseContainerName $ReuseContainerName `
      -ReuseRepoHostPath $reuseRepoHostPathResolved `
      -ReuseRepoContainerPath $ReuseRepoContainerPath `
      -ReuseResultsHostPath $reuseResultsHostPathResolved `
      -ReuseResultsContainerPath $ReuseResultsContainerPath `
      -RuntimeInjectionMount $RuntimeInjectionMount
  $historyExit = $LASTEXITCODE
  if ($historyExit -notin @(0, 1)) {
    throw ("NI Linux review suite scenario 'vi-history-report' compare failed (exit={0})." -f $historyExit)
  }
} finally {
  Pop-Location | Out-Null
}

$historyCheck = Assert-CompareScenarioArtifacts `
  -ScenarioName 'vi-history-report' `
  -CapturePath $historyCapturePath `
  -ReportPath $historyReportPath `
  -RuntimeSnapshotPath $historyRuntimeSnapshotPath `
  -ExpectedImage $Image `
  -RequestedFlags @()

foreach ($requiredHistoryPath in @($historyMarkdownPath, $historyHtmlPath, $historySummaryPath, $historyReceiptPath)) {
  if (-not (Test-Path -LiteralPath $requiredHistoryPath -PathType Leaf)) {
    throw ("NI Linux review suite missing VI history artifact: {0}" -f $requiredHistoryPath)
  }
}

& $historyInspectorScript `
  -ResultsDir $historyResultsDir `
  -HistoryReportPath $historyHtmlPath `
  -HistorySummaryPath $historySummaryPath `
  -OutputJsonPath $historyInspectionJsonPath `
  -OutputHtmlPath $historyInspectionHtmlPath `
  -GitHubOutputPath '' `
  -GitHubStepSummaryPath ''
if ($LASTEXITCODE -ne 0) {
  throw ("VI history artifact inspection failed (exit={0})." -f $LASTEXITCODE)
}

$historyBootstrapReceipt = Get-Content -LiteralPath $historyReceiptPath -Raw | ConvertFrom-Json -Depth 16
$historyInspection = Get-Content -LiteralPath $historyInspectionJsonPath -Raw | ConvertFrom-Json -Depth 16
$historyReviewReceipt = [ordered]@{
  schema = 'ni-linux-review-suite-review-loop@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  resultsRoot = $resultsRootResolved
  historyReview = [ordered]@{
    targetPath = $historyContract.viHistory.targetPath
    requestedBranchRef = [string]$historyRefSelection.requestedBranchRef
    requestedBaselineRef = [string]$historyRefSelection.requestedBaselineRef
    effectiveBranchRef = [string]$historyRefSelection.effectiveBranchRef
    effectiveBaselineRef = [string]$historyRefSelection.effectiveBaselineRef
    maxCommitCount = [int]$HistoryMaxCommitCount
    touchAware = $true
    selectionSource = [string]$historyRefSelection.source
  }
  artifacts = [ordered]@{
    reviewSuiteSummaryJsonPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $summaryJsonPath
    reviewSuiteSummaryMarkdownPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $summaryMarkdownPath
    reviewSuiteSummaryHtmlPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $summaryHtmlPath
    historyReportMarkdownPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historyMarkdownPath
    historyReportHtmlPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historyHtmlPath
    historySummaryPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historySummaryPath
    historyInspectionJsonPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historyInspectionJsonPath
    historyInspectionHtmlPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historyInspectionHtmlPath
    historyBootstrapReceiptPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $historyReceiptPath
  }
  bootstrap = [ordered]@{
    mode = [string]$historyBootstrapReceipt.mode
    requestedStartRef = [string]$historyBootstrapReceipt.requestedStartRef
    startRef = [string]$historyBootstrapReceipt.startRef
    endRef = [string]$historyBootstrapReceipt.endRef
    processedPairs = [int]$historyBootstrapReceipt.processedPairs
    selectedPairs = [int]$historyBootstrapReceipt.selectedPairs
    compareExitCode = [int]$historyBootstrapReceipt.compareExitCode
    pairPlanPath = [string]$historyBootstrapReceipt.pairPlanPath
    resultLedgerPath = [string]$historyBootstrapReceipt.resultLedgerPath
  }
  inspection = [ordered]@{
    schema = [string]$historyInspection.schema
    overallStatus = [string]$historyInspection.overallStatus
    summary = $historyInspection.summary
  }
  recommendedReviewOrder = @(
    'review-suite-summary.html',
    'history-report.md',
    'history-report.html',
    'history-summary.json',
    'history-suite-inspection.html',
    'history-suite-inspection.json'
  )
}
$historyReviewReceiptParent = Split-Path -Parent $historyReviewReceiptPathResolved
if ($historyReviewReceiptParent -and -not (Test-Path -LiteralPath $historyReviewReceiptParent -PathType Container)) {
  New-Item -ItemType Directory -Path $historyReviewReceiptParent -Force | Out-Null
}
$historyReviewReceipt | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $historyReviewReceiptPathResolved -Encoding utf8

$scenarioResults += [pscustomobject]@{
  kind = 'vi-history-report'
  name = 'vi-history-report'
  requestedFlagsLabel = 'vi-history-suite'
  requestedFlags = @('vi-history-suite')
  flagsUsed = @($historyCheck.flagsUsed)
  executionMode = [string]$historyCheck.executionMode
  gateOutcome = [string]$historyCheck.gateOutcome
  resultClass = [string]$historyCheck.resultClass
  reportPath = $historyReportPath
  capturePath = $historyCapturePath
  runtimeSnapshotPath = $historyRuntimeSnapshotPath
  historyMarkdownPath = $historyMarkdownPath
  historyHtmlPath = $historyHtmlPath
  historySummaryPath = $historySummaryPath
  historyReceiptPath = $historyReceiptPath
  historyReviewReceiptPath = $historyReviewReceiptPathResolved
  historyInspectionJsonPath = $historyInspectionJsonPath
  historyInspectionHtmlPath = $historyInspectionHtmlPath
}

$flagCombinationCertification = Write-FlagCombinationCertificationArtifacts `
  -ResultsRoot $resultsRootResolved `
  -Image $Image `
  -ScenarioResults @($scenarioResults) `
  -ParallelBudget $flagScenarioParallelBudget

$baselineTopLevelReportPath = Join-Path $resultsRootResolved 'compare-report.html'
$summaryRows = foreach ($entry in @($scenarioResults)) {
  $historyMarkdownRelativePath = ''
  $historyHtmlRelativePath = ''
  $historySummaryRelativePath = ''
  $historyInspectionJsonRelativePath = ''
  $historyInspectionHtmlRelativePath = ''
  if ($entry.PSObject.Properties['historyMarkdownPath']) {
    $historyMarkdownRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historyMarkdownPath)
  }
  if ($entry.PSObject.Properties['historyHtmlPath']) {
    $historyHtmlRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historyHtmlPath)
  }
  if ($entry.PSObject.Properties['historySummaryPath']) {
    $historySummaryRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historySummaryPath)
  }
  if ($entry.PSObject.Properties['historyInspectionJsonPath']) {
    $historyInspectionJsonRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historyInspectionJsonPath)
  }
  if ($entry.PSObject.Properties['historyInspectionHtmlPath']) {
    $historyInspectionHtmlRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historyInspectionHtmlPath)
  }
  $historyReviewReceiptRelativePath = ''
  if ($entry.PSObject.Properties['historyReviewReceiptPath']) {
    $historyReviewReceiptRelativePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.historyReviewReceiptPath)
  }

  [pscustomobject]@{
    kind = [string]$entry.kind
    name = [string]$entry.name
    requestedFlagsLabel = [string]$entry.requestedFlagsLabel
    executionMode = [string]$entry.executionMode
    resultClass = [string]$entry.resultClass
    gateOutcome = [string]$entry.gateOutcome
    reportPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.reportPath)
    capturePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.capturePath)
    runtimeSnapshotPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.runtimeSnapshotPath)
    historyMarkdownPath = $historyMarkdownRelativePath
    historyHtmlPath = $historyHtmlRelativePath
    historySummaryPath = $historySummaryRelativePath
    historyReviewReceiptPath = $historyReviewReceiptRelativePath
    historyInspectionJsonPath = $historyInspectionJsonRelativePath
    historyInspectionHtmlPath = $historyInspectionHtmlRelativePath
  }
}

$summaryPayload = [ordered]@{
  schema = 'ni-linux-review-suite@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  image = $Image
  labviewPath = $LabVIEWPath
  resultsRoot = $resultsRootResolved
  historyRef = [ordered]@{
    source = [string]$historyRefSelection.source
    requestedBranchRef = [string]$historyRefSelection.requestedBranchRef
    requestedBaselineRef = [string]$historyRefSelection.requestedBaselineRef
    effectiveBranchRef = [string]$historyRefSelection.effectiveBranchRef
    effectiveBaselineRef = [string]$historyRefSelection.effectiveBaselineRef
    maxCommitCount = [int]$HistoryMaxCommitCount
  }
  baselineCompareReportPath = $baselineTopLevelReportPath
  flagCombinationCertification = [ordered]@{
    schema = [string]$flagCombinationCertification.schema
    jsonPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$flagCombinationCertification.jsonPath)
    markdownPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$flagCombinationCertification.markdownPath)
    htmlPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$flagCombinationCertification.htmlPath)
  }
  flagScenarioBudget = [ordered]@{
    path = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $hostRamBudgetPathResolved
    targetProfile = [string]$flagScenarioParallelBudget.targetProfile
    requestedParallelism = [int]$flagScenarioParallelBudget.requestedParallelism
    recommendedParallelism = [int]$flagScenarioParallelBudget.recommendedParallelism
    actualParallelism = [int]$flagScenarioParallelBudget.actualParallelism
    decisionSource = [string]$flagScenarioParallelBudget.decisionSource
    reason = [string]$flagScenarioParallelBudget.reason
  }
  scenarios = @($summaryRows)
}
$summaryPayload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJsonPath -Encoding utf8

$markdownLines = @(
  '# NI Linux review suite',
  '',
  ('- Image: `{0}`' -f $Image),
  ('- LabVIEW path: `{0}`' -f $LabVIEWPath),
  ('- Results root: `{0}`' -f $resultsRootResolved),
  ('- History ref source: `{0}`' -f $historyRefSelection.source),
  ('- History requested branch ref: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBranchRef)) { '(default)' } else { $historyRefSelection.requestedBranchRef })),
  ('- History requested baseline ref: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBaselineRef)) { '(default)' } else { $historyRefSelection.requestedBaselineRef })),
  ('- History effective branch ref: `{0}`' -f $historyRefSelection.effectiveBranchRef),
  ('- History effective baseline ref: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef })),
  ('- History max commit count: `{0}`' -f $HistoryMaxCommitCount),
  ('- Flag scenario budget: `requested={0}; recommended={1}; actual={2}; source={3}` ([json](./{4}))' -f $summaryPayload.flagScenarioBudget.requestedParallelism, $summaryPayload.flagScenarioBudget.recommendedParallelism, $summaryPayload.flagScenarioBudget.actualParallelism, $summaryPayload.flagScenarioBudget.decisionSource, $summaryPayload.flagScenarioBudget.path),
  ('- Flag certification: [flag-combination-certification.html](./{0}) ([json](./{1}), [md](./{2}))' -f $summaryPayload.flagCombinationCertification.htmlPath, $summaryPayload.flagCombinationCertification.jsonPath, $summaryPayload.flagCombinationCertification.markdownPath),
  '',
  '| Scenario | Kind | Requested Flags | Result | Report | Extra |',
  '| --- | --- | --- | --- | --- | --- |'
)
foreach ($entry in @($summaryRows)) {
  $extra = if ([string]::Equals([string]$entry.kind, 'vi-history-report', [System.StringComparison]::OrdinalIgnoreCase)) {
    ('[history-report.md](./{0}), [history-report.html](./{1}), [history-summary.json](./{2}), [inspection.html](./{3}), [inspection.json](./{4}), [review-loop-receipt.json](./{5})' -f $entry.historyMarkdownPath, $entry.historyHtmlPath, $entry.historySummaryPath, $entry.historyInspectionHtmlPath, $entry.historyInspectionJsonPath, $entry.historyReviewReceiptPath)
  } else {
    ('[capture](./{0})' -f $entry.capturePath)
  }
  $markdownLines += ('| {0} | {1} | {2} | {3}/{4} | [report](./{5}) | {6} |' -f $entry.name, $entry.kind, $entry.requestedFlagsLabel, $entry.resultClass, $entry.gateOutcome, $entry.reportPath, $extra)
}
$markdownLines -join "`n" | Set-Content -LiteralPath $summaryMarkdownPath -Encoding utf8

$htmlLines = @(
  '<html><body><h1>NI Linux review suite</h1>',
  ('<p>Image: <code>{0}</code><br/>LabVIEW path: <code>{1}</code><br/>History ref source: <code>{2}</code><br/>History requested branch ref: <code>{3}</code><br/>History requested baseline ref: <code>{4}</code><br/>History effective branch ref: <code>{5}</code><br/>History effective baseline ref: <code>{6}</code><br/>History max commit count: <code>{7}</code><br/>Flag scenario budget: <code>requested={8}; recommended={9}; actual={10}; source={11}</code> (<a href=\"./{12}\">json</a>)<br/>Flag certification: <a href=\"./{13}\">html</a>, <a href=\"./{14}\">json</a>, <a href=\"./{15}\">md</a></p>' -f $Image, $LabVIEWPath, $historyRefSelection.source, $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBranchRef)) { '(default)' } else { $historyRefSelection.requestedBranchRef }), $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBaselineRef)) { '(default)' } else { $historyRefSelection.requestedBaselineRef }), $historyRefSelection.effectiveBranchRef, $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef }), $HistoryMaxCommitCount, $summaryPayload.flagScenarioBudget.requestedParallelism, $summaryPayload.flagScenarioBudget.recommendedParallelism, $summaryPayload.flagScenarioBudget.actualParallelism, $summaryPayload.flagScenarioBudget.decisionSource, $summaryPayload.flagScenarioBudget.path, $summaryPayload.flagCombinationCertification.htmlPath, $summaryPayload.flagCombinationCertification.jsonPath, $summaryPayload.flagCombinationCertification.markdownPath),
  '<table border="1" cellspacing="0" cellpadding="4">',
  '<thead><tr><th>Scenario</th><th>Kind</th><th>Requested Flags</th><th>Result</th><th>Report</th><th>Extra</th></tr></thead>',
  '<tbody>'
)
foreach ($entry in @($summaryRows)) {
  $extra = if ([string]::Equals([string]$entry.kind, 'vi-history-report', [System.StringComparison]::OrdinalIgnoreCase)) {
    ('<a href="./{0}">history-report.md</a>; <a href="./{1}">history-report.html</a>; <a href="./{2}">history-summary.json</a>; <a href="./{3}">inspection.html</a>; <a href="./{4}">inspection.json</a>; <a href="./{5}">review-loop-receipt.json</a>' -f $entry.historyMarkdownPath, $entry.historyHtmlPath, $entry.historySummaryPath, $entry.historyInspectionHtmlPath, $entry.historyInspectionJsonPath, $entry.historyReviewReceiptPath)
  } else {
    ('<a href="./{0}">capture</a>' -f $entry.capturePath)
  }
  $htmlLines += ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}/{4}</td><td><a href="./{5}">report</a></td><td>{6}</td></tr>' -f $entry.name, $entry.kind, $entry.requestedFlagsLabel, $entry.resultClass, $entry.gateOutcome, $entry.reportPath, $extra)
}
$htmlLines += '</tbody></table></body></html>'
$htmlLines -join "`n" | Set-Content -LiteralPath $summaryHtmlPath -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($GitHubStepSummaryPath)) {
  @(
    '### NI Linux review suite',
    '',
    ('- artifact root: `{0}`' -f $resultsRootResolved),
    ('- compare scenarios: `{0}`' -f $knownFlagScenarios.Count),
    ('- flag scenario budget: `{0}`' -f $summaryPayload.flagScenarioBudget.path),
    ('- vi history report: `enabled`'),
    ('- summary: `{0}`' -f (Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $summaryMarkdownPath)),
    ('- flag certification: `{0}`' -f (Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$flagCombinationCertification.markdownPath)))
  ) -join "`n" | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
}

Write-GitHubOutput -Key 'results_root' -Value $resultsRootResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_json_path' -Value $summaryJsonPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_markdown_path' -Value $summaryMarkdownPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_html_path' -Value $summaryHtmlPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'host_ram_budget_path' -Value $hostRamBudgetPathResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'baseline_report_path' -Value $baselineTopLevelReportPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'flag_combination_certification_json_path' -Value ([string]$flagCombinationCertification.jsonPath) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'flag_combination_certification_markdown_path' -Value ([string]$flagCombinationCertification.markdownPath) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'flag_combination_certification_html_path' -Value ([string]$flagCombinationCertification.htmlPath) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_ref_source' -Value ([string]$historyRefSelection.source) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_requested_branch_ref' -Value ([string]$historyRefSelection.requestedBranchRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_requested_baseline_ref' -Value ([string]$historyRefSelection.requestedBaselineRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_effective_branch_ref' -Value ([string]$historyRefSelection.effectiveBranchRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_effective_baseline_ref' -Value ([string]$historyRefSelection.effectiveBaselineRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_markdown_path' -Value $historyMarkdownPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_html_path' -Value $historyHtmlPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_summary_path' -Value $historySummaryPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_review_receipt_path' -Value $historyReviewReceiptPathResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_inspection_json_path' -Value $historyInspectionJsonPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_inspection_html_path' -Value $historyInspectionHtmlPath -Path $GitHubOutputPath

Write-Host ("[ni-linux-review-suite] summary={0}" -f $summaryJsonPath) -ForegroundColor Green
