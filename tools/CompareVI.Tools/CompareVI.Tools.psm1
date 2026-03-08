Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = Split-Path -Parent $PSCommandPath
$script:ToolsRoot = Split-Path -Parent $script:ModuleRoot
$script:BundleRoot = Split-Path -Parent $script:ToolsRoot

function Get-CompareVIScriptPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $candidate = Join-Path $script:ToolsRoot $Name
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "CompareVI script '$Name' not found at $candidate"
  }
  return $candidate
}

function Resolve-CompareVIOutputPath {
  param([string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $PathValue))
}

function Read-CompareVIGitHubOutputValue {
  param(
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  $resolvedPath = Resolve-CompareVIOutputPath -PathValue $Path
  if ([string]::IsNullOrWhiteSpace($resolvedPath)) { return $null }
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) { return $null }

  foreach ($line in Get-Content -LiteralPath $resolvedPath) {
    if ($line -match '^(?<name>[^=]+)=(?<value>.*)$') {
      if ([string]::Equals($matches['name'], $Key, [System.StringComparison]::Ordinal)) {
        return [string]$matches['value']
      }
    }
  }

  return $null
}

function Invoke-CompareVIHistoryScript {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Parameters
  )

  $compareScript = Get-CompareVIScriptPath -Name 'Compare-VIHistory.ps1'
  $env:COMPAREVI_SCRIPTS_ROOT = $script:BundleRoot
  try {
    & $compareScript @Parameters
  } finally {
    Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
  }
}

function Resolve-CompareVIHistorySummary {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$InvokeParameters,
    [string]$GitHubOutputPath
  )

  $resolvedGitHubOutputPath = Resolve-CompareVIOutputPath -PathValue $GitHubOutputPath
  $resultsDir = if ($InvokeParameters.ContainsKey('ResultsDir')) {
    Resolve-CompareVIOutputPath -PathValue ([string]$InvokeParameters['ResultsDir'])
  } else {
    Resolve-CompareVIOutputPath -PathValue 'tests/results/ref-compare/history'
  }

  $summaryPath = Read-CompareVIGitHubOutputValue -Path $resolvedGitHubOutputPath -Key 'history-summary-json'
  if (-not [string]::IsNullOrWhiteSpace($summaryPath)) {
    $summaryPath = Resolve-CompareVIOutputPath -PathValue $summaryPath
  }

  if ((-not $summaryPath) -and $resultsDir) {
    $candidateSummaryPath = Join-Path $resultsDir 'history-summary.json'
    if (Test-Path -LiteralPath $candidateSummaryPath -PathType Leaf) {
      $summaryPath = $candidateSummaryPath
    }
  }

  if ((-not $summaryPath) -or -not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    $manifestPath = Read-CompareVIGitHubOutputValue -Path $resolvedGitHubOutputPath -Key 'manifest-path'
    if ($manifestPath) {
      $manifestPath = Resolve-CompareVIOutputPath -PathValue $manifestPath
    }

    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath -PathType Leaf) -and $resultsDir) {
      $rendererScript = Get-CompareVIScriptPath -Name 'Render-VIHistoryReport.ps1'
      $rendererParameters = @{
        ManifestPath = $manifestPath
        HistoryContextPath = Join-Path $resultsDir 'history-context.json'
        OutputDir = $resultsDir
        MarkdownPath = Join-Path $resultsDir 'history-report.md'
        GitHubOutputPath = $resolvedGitHubOutputPath
      }

      $historyHtmlPath = Read-CompareVIGitHubOutputValue -Path $resolvedGitHubOutputPath -Key 'history-report-html'
      if (-not [string]::IsNullOrWhiteSpace($historyHtmlPath)) {
        $rendererParameters['EmitHtml'] = $true
        $rendererParameters['HtmlPath'] = $historyHtmlPath
      }

      & $rendererScript @rendererParameters | Out-Null
      $summaryPath = Read-CompareVIGitHubOutputValue -Path $resolvedGitHubOutputPath -Key 'history-summary-json'
      if ($summaryPath) {
        $summaryPath = Resolve-CompareVIOutputPath -PathValue $summaryPath
      }
    }
  }

  if ((-not $summaryPath) -or -not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
    throw 'CompareVI history facade summary was not produced. Ensure Render-VIHistoryReport.ps1 completed successfully.'
  }

  return Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 12
}

function Invoke-CompareVIHistory {
  [CmdletBinding(DefaultParameterSetName = 'Default')]
  param(
    [Parameter(Mandatory = $true)]
    [Alias('ViName')]
    [string]$TargetPath,

    [Alias('Branch')]
    [string]$StartRef = 'HEAD',
    [string]$EndRef,
    [int]$MaxPairs,

    [bool]$FlagNoAttr = $true,
    [bool]$FlagNoFp = $true,
    [bool]$FlagNoFpPos = $true,
    [bool]$FlagNoBdCosm = $true,
    [bool]$ForceNoBd = $true,
    [string]$AdditionalFlags,
    [string]$LvCompareArgs,
    [switch]$ReplaceFlags,

    [string[]]$Mode = @('default'),
    [switch]$FailFast,
    [switch]$FailOnDiff,
    [switch]$Quiet,

    [string]$ResultsDir = 'tests/results/ref-compare/history',
    [string]$OutPrefix,
    [string]$ManifestPath,
    [switch]$Detailed,
    [switch]$RenderReport,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [switch]$KeepArtifactsOnNoDiff,
    [string]$InvokeScriptPath,

    [string]$GitHubOutputPath,
    [string]$StepSummaryPath,

    [switch]$IncludeMergeParents
  )

  $invokeParameters = @{}
  foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $invokeParameters[$entry.Key] = $entry.Value
  }

  Invoke-CompareVIHistoryScript -Parameters $invokeParameters
}

function Invoke-CompareVIHistoryFacade {
  [CmdletBinding(DefaultParameterSetName = 'Default')]
  param(
    [Parameter(Mandatory = $true)]
    [Alias('ViName')]
    [string]$TargetPath,

    [Alias('Branch')]
    [string]$StartRef = 'HEAD',
    [string]$EndRef,
    [int]$MaxPairs,

    [bool]$FlagNoAttr = $true,
    [bool]$FlagNoFp = $true,
    [bool]$FlagNoFpPos = $true,
    [bool]$FlagNoBdCosm = $true,
    [bool]$ForceNoBd = $true,
    [string]$AdditionalFlags,
    [string]$LvCompareArgs,
    [switch]$ReplaceFlags,

    [string[]]$Mode = @('default'),
    [switch]$FailFast,
    [switch]$FailOnDiff,
    [switch]$Quiet,

    [string]$ResultsDir = 'tests/results/ref-compare/history',
    [string]$OutPrefix,
    [string]$ManifestPath,
    [switch]$Detailed,
    [switch]$RenderReport,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [switch]$KeepArtifactsOnNoDiff,
    [string]$InvokeScriptPath,

    [string]$GitHubOutputPath,
    [string]$StepSummaryPath,

    [switch]$IncludeMergeParents
  )

  $invokeParameters = @{}
  foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    $invokeParameters[$entry.Key] = $entry.Value
  }

  $generatedGitHubOutputPath = $false
  $effectiveGitHubOutputPath = Resolve-CompareVIOutputPath -PathValue $GitHubOutputPath
  if ([string]::IsNullOrWhiteSpace($effectiveGitHubOutputPath)) {
    $effectiveGitHubOutputPath = [System.IO.Path]::GetTempFileName()
    $invokeParameters['GitHubOutputPath'] = $effectiveGitHubOutputPath
    $generatedGitHubOutputPath = $true
  }

  try {
    Invoke-CompareVIHistoryScript -Parameters $invokeParameters
    Resolve-CompareVIHistorySummary -InvokeParameters $invokeParameters -GitHubOutputPath $effectiveGitHubOutputPath
  } finally {
    if ($generatedGitHubOutputPath -and (Test-Path -LiteralPath $effectiveGitHubOutputPath -PathType Leaf)) {
      Remove-Item -LiteralPath $effectiveGitHubOutputPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-CompareRefsToTemp {
  [CmdletBinding(DefaultParameterSetName = 'ByPath')]
  param(
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)][string]$Path,
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$ViName,
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$RefA,
    [Parameter(ParameterSetName = 'ByPath', Mandatory = $true)]
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true)][string]$RefB,
    [string]$ResultsDir = 'tests/results/ref-compare',
    [string]$OutName,
    [switch]$Quiet,
    [switch]$Detailed,
    [switch]$RenderReport,
    [ValidateSet('html','xml','text')]
    [string]$ReportFormat = 'html',
    [string]$LvCompareArgs,
    [switch]$ReplaceFlags,
    [string]$LvComparePath,
    [string]$LabVIEWExePath,
    [string]$InvokeScriptPath,
    [switch]$LeakCheck,
    [double]$LeakGraceSeconds = 1.5,
    [string]$LeakJsonPath,
    [switch]$FailOnDiff
  )

  $compareScript = Get-CompareVIScriptPath -Name 'Compare-RefsToTemp.ps1'
  & $compareScript @PSBoundParameters
}

Export-ModuleMember -Function Invoke-CompareVIHistory, Invoke-CompareVIHistoryFacade, Invoke-CompareRefsToTemp
