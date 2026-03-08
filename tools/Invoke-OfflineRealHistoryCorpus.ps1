#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CatalogPath = 'fixtures/real-history/offline-corpus.targets.json',
  [string]$TargetId,
  [string]$RepoPath,
  [string]$RepoSlug,
  [string]$StartRef,
  [string]$EndRef,
  [string[]]$Mode,
  [Nullable[int]]$MaxPairs,
  [ValidateSet('html', 'xml', 'text')][string]$ReportFormat,
  [ValidateSet('cli-only', 'cli-first', 'lv-first', 'lv-only')][string]$ComparePolicy,
  [string]$ResultsRoot = 'tests/results/offline-real-history',
  [string]$WindowsImage,
  [string]$WindowsLabVIEWPath,
  [string]$WindowsCliPath,
  [Nullable[int]]$CompareTimeoutSeconds = 900,
  [string]$RunId,
  [switch]$PlanOnly,
  [switch]$SkipSchemaValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20)
}

function Resolve-FirstExistingPath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [AllowNull()][string]$ExplicitPath,
    [AllowNull()][object[]]$Hints
  )

  if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
    return (Resolve-AbsolutePath -BasePath $BasePath -PathValue $ExplicitPath)
  }

  foreach ($hint in @($Hints)) {
    if ([string]::IsNullOrWhiteSpace([string]$hint)) {
      continue
    }
    $candidate = Resolve-AbsolutePath -BasePath $BasePath -PathValue ([string]$hint)
    if (Test-Path -LiteralPath $candidate -PathType Container) {
      return $candidate
    }
  }

  return $null
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Schema validation runner not found at '$runner'."
  }

  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Resolve-GitRef {
  param(
    [AllowNull()][string]$RepoPathValue,
    [AllowNull()][string]$Ref
  )

  if ([string]::IsNullOrWhiteSpace($RepoPathValue) -or [string]::IsNullOrWhiteSpace($Ref)) {
    return $null
  }

  try {
    $raw = (& git -C $RepoPathValue rev-parse --verify $Ref 2>$null)
    if ($LASTEXITCODE -ne 0) {
      return $null
    }
    return (($raw -split "`n")[0]).Trim()
  } catch {
    return $null
  }
}

function Resolve-LabVIEWVersionHint {
  param(
    [AllowNull()][string]$LabVIEWPath,
    [AllowNull()][string]$Image
  )

  if (-not [string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $match = [regex]::Match($LabVIEWPath, 'LabVIEW\s+(?<year>\d{4})', 'IgnoreCase')
    if ($match.Success) {
      return $match.Groups['year'].Value
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($Image)) {
    $match = [regex]::Match($Image, 'labview:(?<year>\d{4})q(?<quarter>[1-4])', 'IgnoreCase')
    if ($match.Success) {
      return ('{0} q{1}' -f $match.Groups['year'].Value, $match.Groups['quarter'].Value)
    }
  }

  return $null
}

function Get-StringArray {
  param([AllowNull()][object]$Value)
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if ([string]::IsNullOrWhiteSpace([string]$item)) {
      continue
    }
    $list.Add([string]$item) | Out-Null
  }
  return @($list.ToArray())
}

$repoRoot = Resolve-RepoRoot
$catalogResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CatalogPath
if (-not (Test-Path -LiteralPath $catalogResolved -PathType Leaf)) {
  throw "Offline corpus catalog not found at '$catalogResolved'."
}

$targetSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'offline-real-history-corpus-targets-v1.schema.json'
$runSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'offline-real-history-corpus-run-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $targetSchemaPath -DataPath $catalogResolved
}

$catalog = Read-JsonFile -Path $catalogResolved
$targets = @($catalog.targets)
if ($targets.Count -eq 0) {
  throw "Offline corpus catalog '$catalogResolved' contains no targets."
}

$selectedTarget = $null
if ([string]::IsNullOrWhiteSpace($TargetId)) {
  $selectedTarget = $targets[0]
} else {
  $selectedTarget = @($targets | Where-Object { [string]$_.id -eq $TargetId } | Select-Object -First 1)
}
if (-not $selectedTarget) {
  throw "Offline corpus target '$TargetId' was not found in '$catalogResolved'."
}

$effectiveRepoSlug = if (-not [string]::IsNullOrWhiteSpace($RepoSlug)) {
  $RepoSlug.Trim()
} else {
  [string]$selectedTarget.repo.slug
}
$resolvedRepoPath = Resolve-FirstExistingPath `
  -BasePath $repoRoot `
  -ExplicitPath $RepoPath `
  -Hints @($selectedTarget.repo.localPathHints)

$effectiveStartRef = if (-not [string]::IsNullOrWhiteSpace($StartRef)) {
  $StartRef.Trim()
} else {
  [string]$selectedTarget.repo.startRef
}
$effectiveEndRef = if ($PSBoundParameters.ContainsKey('EndRef')) {
  if ([string]::IsNullOrWhiteSpace($EndRef)) { $null } else { $EndRef.Trim() }
} elseif ($selectedTarget.repo.PSObject.Properties['endRef'] -and $selectedTarget.repo.endRef) {
  [string]$selectedTarget.repo.endRef
} else {
  $null
}
$effectiveModes = if ($Mode -and @($Mode).Count -gt 0) {
  Get-StringArray -Value $Mode
} else {
  Get-StringArray -Value $selectedTarget.requestedModes
}
$effectiveMaxPairs = if ($MaxPairs -and $MaxPairs -gt 0) {
  [int]$MaxPairs
} else {
  [int]$selectedTarget.maxPairs
}
$effectiveReportFormat = if (-not [string]::IsNullOrWhiteSpace($ReportFormat)) {
  $ReportFormat.ToLowerInvariant()
} else {
  [string]$selectedTarget.reportFormat
}
$effectiveComparePolicy = if (-not [string]::IsNullOrWhiteSpace($ComparePolicy)) {
  $ComparePolicy.Trim()
} else {
  [string]$catalog.defaultComparePolicy
}
$effectiveWindowsImage = if (-not [string]::IsNullOrWhiteSpace($WindowsImage)) {
  $WindowsImage.Trim()
} else {
  [string]$catalog.defaultWindowsImage
}
$effectiveWindowsLabVIEWPath = if (-not [string]::IsNullOrWhiteSpace($WindowsLabVIEWPath)) {
  $WindowsLabVIEWPath.Trim()
} else {
  [string]$catalog.defaultLabVIEWPath
}
$effectiveWindowsCliPath = if (-not [string]::IsNullOrWhiteSpace($WindowsCliPath)) {
  $WindowsCliPath.Trim()
} else {
  [string]$catalog.defaultCliPath
}
$effectiveRunId = if (-not [string]::IsNullOrWhiteSpace($RunId)) {
  $RunId.Trim()
} else {
  (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssZ')
}

$resultsRootResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot
$runRoot = Join-Path $resultsRootResolved (Join-Path ([string]$selectedTarget.id) $effectiveRunId)
$historyResultsDir = Join-Path $runRoot 'history'
Ensure-Directory -Path $historyResultsDir

$bridgeScriptPath = Join-Path $repoRoot 'tools' 'Invoke-NIWindowsContainerCompareBridge.ps1'
$historyScriptPath = Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1'
if (-not (Test-Path -LiteralPath $bridgeScriptPath -PathType Leaf)) {
  throw "Offline corpus bridge script not found at '$bridgeScriptPath'."
}
if (-not (Test-Path -LiteralPath $historyScriptPath -PathType Leaf)) {
  throw "Compare-VIHistory.ps1 not found at '$historyScriptPath'."
}

$runManifestPath = Join-Path $runRoot 'offline-real-history-run.json'
$historyManifestPath = Join-Path $historyResultsDir 'manifest.json'
$historyReportMarkdownPath = Join-Path $historyResultsDir 'history-report.md'
$historyReportHtmlPath = Join-Path $historyResultsDir 'history-report.html'
$labviewVersion = Resolve-LabVIEWVersionHint `
  -LabVIEWPath $effectiveWindowsLabVIEWPath `
  -Image $effectiveWindowsImage

$runEnvelope = [ordered]@{
  schema = 'vi-history/offline-real-history-run@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = if ($PlanOnly.IsPresent) { 'planned' } else { 'failed' }
  planOnly = [bool]$PlanOnly
  runId = $effectiveRunId
  message = $null
  target = [ordered]@{
    id = [string]$selectedTarget.id
    label = [string]$selectedTarget.label
    targetPath = [string]$selectedTarget.targetPath
    requestedModes = @($effectiveModes)
    executedModes = @()
    maxPairs = $effectiveMaxPairs
    reportFormat = $effectiveReportFormat
    notes = Get-StringArray -Value $selectedTarget.notes
  }
  source = [ordered]@{
    repoSlug = $effectiveRepoSlug
    repoPath = $resolvedRepoPath
    requestedStartRef = $effectiveStartRef
    requestedEndRef = $effectiveEndRef
    resolvedStartRef = Resolve-GitRef -RepoPathValue $resolvedRepoPath -Ref $effectiveStartRef
    resolvedHeadRef = Resolve-GitRef -RepoPathValue $resolvedRepoPath -Ref 'HEAD'
  }
  capture = [ordered]@{
    comparePolicy = $effectiveComparePolicy
    compareTimeoutSeconds = if ($CompareTimeoutSeconds -and $CompareTimeoutSeconds -gt 0) { [int]$CompareTimeoutSeconds } else { $null }
    invokeScriptPath = $bridgeScriptPath
    historySuiteStatus = $null
    historySuiteStats = $null
  }
  container = [ordered]@{
    lane = 'windows-ni'
    image = $effectiveWindowsImage
    labviewPath = $effectiveWindowsLabVIEWPath
    labviewVersion = $labviewVersion
    cliPath = $effectiveWindowsCliPath
    runnerScriptPath = $bridgeScriptPath
  }
  outputs = [ordered]@{
    runRoot = $runRoot
    historyResultsDir = $historyResultsDir
    aggregateManifestPath = if (Test-Path -LiteralPath $historyManifestPath -PathType Leaf) { $historyManifestPath } else { $null }
    historyReportMarkdownPath = if (Test-Path -LiteralPath $historyReportMarkdownPath -PathType Leaf) { $historyReportMarkdownPath } else { $null }
    historyReportHtmlPath = if (Test-Path -LiteralPath $historyReportHtmlPath -PathType Leaf) { $historyReportHtmlPath } else { $null }
    modeManifestPaths = @()
    lvcompareCapturePaths = @()
    niContainerCapturePaths = @()
  }
  storage = [ordered]@{
    catalogPath = $catalogResolved
    generatedRoot = $resultsRootResolved
    rawArtifactsInGit = $false
  }
}

$writeRunEnvelope = {
  $runEnvelope.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  $runEnvelope | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $runManifestPath -Encoding utf8
}.GetNewClosure()

& $writeRunEnvelope

if ($PlanOnly.IsPresent) {
  if (-not $SkipSchemaValidation.IsPresent) {
    Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $runSchemaPath -DataPath $runManifestPath
  }
  return [pscustomobject]$runEnvelope
}

if ([string]::IsNullOrWhiteSpace($resolvedRepoPath) -or -not (Test-Path -LiteralPath $resolvedRepoPath -PathType Container)) {
  $runEnvelope.message = 'Local external repository checkout not found for offline corpus run.'
  & $writeRunEnvelope
  throw $runEnvelope.message
}

$previousScriptsRoot = [Environment]::GetEnvironmentVariable('COMPAREVI_SCRIPTS_ROOT', 'Process')
$previousImage = [Environment]::GetEnvironmentVariable('COMPAREVI_NI_WINDOWS_IMAGE', 'Process')
$previousLabVIEWPath = [Environment]::GetEnvironmentVariable('COMPAREVI_NI_WINDOWS_LABVIEW_PATH', 'Process')
$previousCliPath = [Environment]::GetEnvironmentVariable('COMPAREVI_NI_WINDOWS_CLI_PATH', 'Process')
$previousComparePolicy = [Environment]::GetEnvironmentVariable('COMPAREVI_NI_WINDOWS_COMPARE_POLICY', 'Process')

try {
  [Environment]::SetEnvironmentVariable('COMPAREVI_SCRIPTS_ROOT', $repoRoot, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_IMAGE', $effectiveWindowsImage, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_LABVIEW_PATH', $effectiveWindowsLabVIEWPath, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_CLI_PATH', $effectiveWindowsCliPath, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_COMPARE_POLICY', $effectiveComparePolicy, 'Process')

  Push-Location $resolvedRepoPath
  try {
    $compareArgs = @{
      TargetPath = [string]$selectedTarget.targetPath
      StartRef = $effectiveStartRef
      ResultsDir = $historyResultsDir
      Mode = @($effectiveModes)
      MaxPairs = $effectiveMaxPairs
      FailOnDiff = $false
      RenderReport = $true
      ReportFormat = $effectiveReportFormat
      InvokeScriptPath = $bridgeScriptPath
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveEndRef)) {
      $compareArgs['EndRef'] = $effectiveEndRef
    }
    if ($CompareTimeoutSeconds -and $CompareTimeoutSeconds -gt 0) {
      $compareArgs['CompareTimeoutSeconds'] = [int]$CompareTimeoutSeconds
    }

    & $historyScriptPath @compareArgs | Out-Null
  } finally {
    Pop-Location
  }

  $suiteManifest = Read-JsonFile -Path $historyManifestPath
  $modeManifestPaths = @(
    $suiteManifest.modes |
      ForEach-Object { [string]$_.manifestPath } |
      Where-Object { $_ }
  )
  $lvcompareCaptures = @(
    Get-ChildItem -LiteralPath $historyResultsDir -Recurse -Filter 'lvcompare-capture.json' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName }
  )
  $niCaptures = @(
    Get-ChildItem -LiteralPath $historyResultsDir -Recurse -Filter 'ni-windows-container-capture.json' -File -ErrorAction SilentlyContinue |
      ForEach-Object { $_.FullName }
  )

  $runEnvelope.status = 'captured'
  $runEnvelope.target.executedModes = Get-StringArray -Value $suiteManifest.executedModes
  $runEnvelope.capture.historySuiteStatus = [string]$suiteManifest.status
  $runEnvelope.capture.historySuiteStats = $suiteManifest.stats
  $runEnvelope.outputs.aggregateManifestPath = $historyManifestPath
  $runEnvelope.outputs.historyReportMarkdownPath = if (Test-Path -LiteralPath $historyReportMarkdownPath -PathType Leaf) { $historyReportMarkdownPath } else { $null }
  $runEnvelope.outputs.historyReportHtmlPath = if (Test-Path -LiteralPath $historyReportHtmlPath -PathType Leaf) { $historyReportHtmlPath } else { $null }
  $runEnvelope.outputs.modeManifestPaths = @($modeManifestPaths)
  $runEnvelope.outputs.lvcompareCapturePaths = @($lvcompareCaptures)
  $runEnvelope.outputs.niContainerCapturePaths = @($niCaptures)
  $runEnvelope.message = $null
} catch {
  $runEnvelope.status = 'failed'
  $runEnvelope.message = $_.Exception.Message
  throw
} finally {
  [Environment]::SetEnvironmentVariable('COMPAREVI_SCRIPTS_ROOT', $previousScriptsRoot, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_IMAGE', $previousImage, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_LABVIEW_PATH', $previousLabVIEWPath, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_CLI_PATH', $previousCliPath, 'Process')
  [Environment]::SetEnvironmentVariable('COMPAREVI_NI_WINDOWS_COMPARE_POLICY', $previousComparePolicy, 'Process')
  & $writeRunEnvelope
}

if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $runSchemaPath -DataPath $runManifestPath
}

return [pscustomobject]$runEnvelope
