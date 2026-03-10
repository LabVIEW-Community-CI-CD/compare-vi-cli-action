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
  [ValidateRange(30, 900)]
  [int]$TimeoutSeconds = 240,
  [ValidateRange(5, 120)]
  [int]$HeartbeatSeconds = 15,
  [ValidateRange(30, 600)]
  [int]$RuntimeEngineReadyTimeoutSeconds = 120,
  [ValidateRange(1, 30)]
  [int]$RuntimeEngineReadyPollSeconds = 3,
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
  if ([string]::IsNullOrWhiteSpace($commandText) -or $commandText -notmatch '(?i)docker run') {
    throw ("NI Linux review suite scenario '{0}' did not emit a docker run command in capture evidence." -f $ScenarioName)
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

$repoRootResolved = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -Path '..' -BasePath $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
}
$baseViResolved = Resolve-AbsolutePath -Path $BaseVi -BasePath $repoRootResolved
$headViResolved = Resolve-AbsolutePath -Path $HeadVi -BasePath $repoRootResolved
$resultsRootResolved = Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved
$historyTargetResolved = Resolve-AbsolutePath -Path $HistoryTargetPath -BasePath $repoRootResolved
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

$flagScenarioRoot = Join-Path $resultsRootResolved 'flag-combinations'
$historyScenarioRoot = Join-Path $resultsRootResolved 'vi-history-report'
$summaryJsonPath = Join-Path $resultsRootResolved 'review-suite-summary.json'
$summaryMarkdownPath = Join-Path $resultsRootResolved 'review-suite-summary.md'
$summaryHtmlPath = Join-Path $resultsRootResolved 'review-suite-summary.html'
$scenarioResults = @()
$knownFlagScenarios = New-FlagScenarioDefinitions
$historyRefSelection = Resolve-HistoryRefSelection -RequestedBranchRef $HistoryBranchRef -RequestedBaselineRef $HistoryBaselineRef

Write-Host ("[ni-linux-review-suite] resultsRoot={0}" -f $resultsRootResolved) -ForegroundColor Cyan
Write-Host ("[ni-linux-review-suite] historyRefSource={0} requestedBranchRef={1} requestedBaselineRef={2} effectiveBranchRef={3} effectiveBaselineRef={4} maxCommitCount={5}" -f $historyRefSelection.source, ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBranchRef)) { '(default)' } else { $historyRefSelection.requestedBranchRef })), ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBaselineRef)) { '(default)' } else { $historyRefSelection.requestedBaselineRef })), $historyRefSelection.effectiveBranchRef, ($(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef })), $HistoryMaxCommitCount) -ForegroundColor DarkCyan

foreach ($scenario in $knownFlagScenarios) {
  $scenarioName = [string]$scenario.name
  $scenarioDir = Join-Path $flagScenarioRoot $scenarioName
  New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
  $reportPath = Join-Path $scenarioDir 'compare-report.html'
  $runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'
  $capturePath = Join-Path $scenarioDir 'ni-linux-container-capture.json'

  Write-Host ("[ni-linux-review-suite] scenario={0} requestedFlags={1}" -f $scenarioName, [string]$scenario.requestedFlagsLabel) -ForegroundColor Cyan
  Push-Location $repoRootResolved
  try {
    & $compareScriptPath `
      -BaseVi $baseViResolved `
      -HeadVi $headViResolved `
      -Image $Image `
      -ReportPath $reportPath `
      -LabVIEWPath $LabVIEWPath `
      -ContainerNameLabel $scenarioName `
      -Flags @($scenario.flags) `
      -TimeoutSeconds $TimeoutSeconds `
      -HeartbeatSeconds $HeartbeatSeconds `
      -AutoRepairRuntime:$true `
      -RuntimeEngineReadyTimeoutSeconds $RuntimeEngineReadyTimeoutSeconds `
      -RuntimeEngineReadyPollSeconds $RuntimeEngineReadyPollSeconds `
      -RuntimeSnapshotPath $runtimeSnapshotPath
    $compareExit = $LASTEXITCODE
    if ($compareExit -notin @(0, 1)) {
      throw ("NI Linux review suite scenario '{0}' compare failed (exit={1})." -f $scenarioName, $compareExit)
    }
  } finally {
    Pop-Location | Out-Null
  }

  $scenarioCheck = Assert-CompareScenarioArtifacts `
    -ScenarioName $scenarioName `
    -CapturePath $capturePath `
    -ReportPath $reportPath `
    -RuntimeSnapshotPath $runtimeSnapshotPath `
    -ExpectedImage $Image `
    -RequestedFlags @($scenario.flags)

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
    requestedFlagsLabel = [string]$scenario.requestedFlagsLabel
    requestedFlags = @($scenario.flags)
    flagsUsed = @($scenarioCheck.flagsUsed)
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
  scriptPath = $viHistoryBootstrapScript
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
    -RuntimeBootstrapContractPath $historyContractPath
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

$scenarioResults += [pscustomobject]@{
  kind = 'vi-history-report'
  name = 'vi-history-report'
  requestedFlagsLabel = 'vi-history-suite'
  requestedFlags = @('vi-history-suite')
  flagsUsed = @($historyCheck.flagsUsed)
  gateOutcome = [string]$historyCheck.gateOutcome
  resultClass = [string]$historyCheck.resultClass
  reportPath = $historyReportPath
  capturePath = $historyCapturePath
  runtimeSnapshotPath = $historyRuntimeSnapshotPath
  historyMarkdownPath = $historyMarkdownPath
  historyHtmlPath = $historyHtmlPath
  historySummaryPath = $historySummaryPath
  historyReceiptPath = $historyReceiptPath
  historyInspectionJsonPath = $historyInspectionJsonPath
  historyInspectionHtmlPath = $historyInspectionHtmlPath
}

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

  [pscustomobject]@{
    kind = [string]$entry.kind
    name = [string]$entry.name
    requestedFlagsLabel = [string]$entry.requestedFlagsLabel
    resultClass = [string]$entry.resultClass
    gateOutcome = [string]$entry.gateOutcome
    reportPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.reportPath)
    capturePath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.capturePath)
    runtimeSnapshotPath = Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path ([string]$entry.runtimeSnapshotPath)
    historyMarkdownPath = $historyMarkdownRelativePath
    historyHtmlPath = $historyHtmlRelativePath
    historySummaryPath = $historySummaryRelativePath
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
  '',
  '| Scenario | Kind | Requested Flags | Result | Report | Extra |',
  '| --- | --- | --- | --- | --- | --- |'
)
foreach ($entry in @($summaryRows)) {
  $extra = if ([string]::Equals([string]$entry.kind, 'vi-history-report', [System.StringComparison]::OrdinalIgnoreCase)) {
    ('[history-report.md](./{0}), [history-report.html](./{1}), [history-summary.json](./{2}), [inspection.html](./{3}), [inspection.json](./{4})' -f $entry.historyMarkdownPath, $entry.historyHtmlPath, $entry.historySummaryPath, $entry.historyInspectionHtmlPath, $entry.historyInspectionJsonPath)
  } else {
    ('[capture](./{0})' -f $entry.capturePath)
  }
  $markdownLines += ('| {0} | {1} | {2} | {3}/{4} | [report](./{5}) | {6} |' -f $entry.name, $entry.kind, $entry.requestedFlagsLabel, $entry.resultClass, $entry.gateOutcome, $entry.reportPath, $extra)
}
$markdownLines -join "`n" | Set-Content -LiteralPath $summaryMarkdownPath -Encoding utf8

$htmlLines = @(
  '<html><body><h1>NI Linux review suite</h1>',
  ('<p>Image: <code>{0}</code><br/>LabVIEW path: <code>{1}</code><br/>History ref source: <code>{2}</code><br/>History requested branch ref: <code>{3}</code><br/>History requested baseline ref: <code>{4}</code><br/>History effective branch ref: <code>{5}</code><br/>History effective baseline ref: <code>{6}</code><br/>History max commit count: <code>{7}</code></p>' -f $Image, $LabVIEWPath, $historyRefSelection.source, $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBranchRef)) { '(default)' } else { $historyRefSelection.requestedBranchRef }), $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.requestedBaselineRef)) { '(default)' } else { $historyRefSelection.requestedBaselineRef }), $historyRefSelection.effectiveBranchRef, $(if ([string]::IsNullOrWhiteSpace($historyRefSelection.effectiveBaselineRef)) { '(default)' } else { $historyRefSelection.effectiveBaselineRef }), $HistoryMaxCommitCount),
  '<table border="1" cellspacing="0" cellpadding="4">',
  '<thead><tr><th>Scenario</th><th>Kind</th><th>Requested Flags</th><th>Result</th><th>Report</th><th>Extra</th></tr></thead>',
  '<tbody>'
)
foreach ($entry in @($summaryRows)) {
  $extra = if ([string]::Equals([string]$entry.kind, 'vi-history-report', [System.StringComparison]::OrdinalIgnoreCase)) {
    ('<a href="./{0}">history-report.md</a>; <a href="./{1}">history-report.html</a>; <a href="./{2}">history-summary.json</a>; <a href="./{3}">inspection.html</a>; <a href="./{4}">inspection.json</a>' -f $entry.historyMarkdownPath, $entry.historyHtmlPath, $entry.historySummaryPath, $entry.historyInspectionHtmlPath, $entry.historyInspectionJsonPath)
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
    ('- vi history report: `enabled`'),
    ('- summary: `{0}`' -f (Get-RelativeArtifactPath -RootPath $resultsRootResolved -Path $summaryMarkdownPath))
  ) -join "`n" | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
}

Write-GitHubOutput -Key 'results_root' -Value $resultsRootResolved -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_json_path' -Value $summaryJsonPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_markdown_path' -Value $summaryMarkdownPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'summary_html_path' -Value $summaryHtmlPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'baseline_report_path' -Value $baselineTopLevelReportPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_ref_source' -Value ([string]$historyRefSelection.source) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_requested_branch_ref' -Value ([string]$historyRefSelection.requestedBranchRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_requested_baseline_ref' -Value ([string]$historyRefSelection.requestedBaselineRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_effective_branch_ref' -Value ([string]$historyRefSelection.effectiveBranchRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'history_effective_baseline_ref' -Value ([string]$historyRefSelection.effectiveBaselineRef) -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_markdown_path' -Value $historyMarkdownPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_html_path' -Value $historyHtmlPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_summary_path' -Value $historySummaryPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_inspection_json_path' -Value $historyInspectionJsonPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi_history_inspection_html_path' -Value $historyInspectionHtmlPath -Path $GitHubOutputPath

Write-Host ("[ni-linux-review-suite] summary={0}" -f $summaryJsonPath) -ForegroundColor Green
