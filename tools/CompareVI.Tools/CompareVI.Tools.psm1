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

function Get-CompareVIFacadeValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }
  if ($InputObject -is [System.Collections.IDictionary]) {
    return $InputObject[$Name]
  }
  if ($InputObject.PSObject.Properties[$Name]) {
    return $InputObject.$Name
  }
  return $null
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

function Invoke-CompareVILocalRefinementScript {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Parameters
  )

  $refinementScript = Get-CompareVIScriptPath -Name 'Invoke-VIHistoryLocalRefinement.ps1'
  $parametersWithPassThru = @{}
  foreach ($entry in $Parameters.GetEnumerator()) {
    $parametersWithPassThru[$entry.Key] = $entry.Value
  }
  $parametersWithPassThru['PassThru'] = $true

  $env:COMPAREVI_SCRIPTS_ROOT = $script:BundleRoot
  try {
    return & $refinementScript @parametersWithPassThru
  } finally {
    Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
  }
}

function Invoke-CompareVILocalOperatorSessionScript {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Parameters
  )

  $operatorSessionScript = Get-CompareVIScriptPath -Name 'Invoke-VIHistoryLocalOperatorSession.ps1'
  $parametersWithPassThru = @{}
  foreach ($entry in $Parameters.GetEnumerator()) {
    $parametersWithPassThru[$entry.Key] = $entry.Value
  }
  $parametersWithPassThru['PassThru'] = $true

  $env:COMPAREVI_SCRIPTS_ROOT = $script:BundleRoot
  try {
    return & $operatorSessionScript @parametersWithPassThru
  } finally {
    Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
  }
}

function ConvertTo-CompareVILocalRefinementFacade {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Receipt
  )

  if (-not $Receipt) {
    throw 'Local refinement receipt was not produced.'
  }
  if ([string]$Receipt.schema -ne 'comparevi/local-refinement@v1') {
    throw ("Unexpected local refinement receipt schema: {0}" -f [string]$Receipt.schema)
  }

  $resultsRoot = Resolve-CompareVIOutputPath -PathValue ([string]$Receipt.resultsRoot)
  $localRefinementPath = if ($resultsRoot) { Join-Path $resultsRoot 'local-refinement.json' } else { $null }
  $benchmarkPath = if ($resultsRoot) { Join-Path $resultsRoot 'local-refinement-benchmark.json' } else { $null }

  $warmRuntimeReceipt = Get-CompareVIFacadeValue -InputObject $Receipt -Name 'warmRuntime'
  $warmRuntimeFacade = $null
  if ($warmRuntimeReceipt) {
    $warmRuntimeContainer = Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'container'
    $warmRuntimeFacade = [ordered]@{
      schema = [string](Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'schema')
      action = [string](Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'action')
      outcome = [string](Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'outcome')
      container = [ordered]@{
        name = [string](Get-CompareVIFacadeValue -InputObject $warmRuntimeContainer -Name 'name')
        image = [string](Get-CompareVIFacadeValue -InputObject $warmRuntimeContainer -Name 'image')
      }
      health = Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'health'
      artifacts = Get-CompareVIFacadeValue -InputObject $warmRuntimeReceipt -Name 'artifacts'
    }
  }

  return [pscustomobject]@{
    schema = 'comparevi-tools/local-refinement-facade@v1'
    generatedAtUtc = [string]$Receipt.generatedAt
    backendReceiptSchema = [string]$Receipt.schema
    runtimeProfile = [string]$Receipt.runtimeProfile
    runtimePlane = if ($Receipt.PSObject.Properties['runtimePlane']) { [string]$Receipt.runtimePlane } else { 'linux' }
    image = [string]$Receipt.image
    toolSource = [string]$Receipt.toolSource
    cacheReuseState = [string]$Receipt.cacheReuseState
    coldWarmClass = [string]$Receipt.coldWarmClass
    benchmarkSampleKind = if ($Receipt.PSObject.Properties['benchmarkSampleKind']) { [string]$Receipt.benchmarkSampleKind } else { '' }
    repoRoot = [string]$Receipt.repoRoot
    resultsRoot = [string]$Receipt.resultsRoot
    timings = $Receipt.timings
    history = $Receipt.history
    reviewSuite = if ($Receipt.PSObject.Properties['reviewSuite']) { $Receipt.reviewSuite } else { $null }
    reviewLoop = if ($Receipt.PSObject.Properties['reviewLoop']) { $Receipt.reviewLoop } else { $null }
    windowsMirror = if ($Receipt.PSObject.Properties['windowsMirror']) { $Receipt.windowsMirror } else { $null }
    warmRuntime = $warmRuntimeFacade
    artifacts = [ordered]@{
      localRefinementPath = $localRefinementPath
      benchmarkPath = $benchmarkPath
    }
    finalStatus = [string]$Receipt.finalStatus
  }
}

function ConvertTo-CompareVILocalOperatorSessionFacade {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Receipt
  )

  if (-not $Receipt) {
    throw 'Local operator session receipt was not produced.'
  }
  if ([string]$Receipt.schema -ne 'comparevi/local-operator-session@v1') {
    throw ("Unexpected local operator session receipt schema: {0}" -f [string]$Receipt.schema)
  }

  return [pscustomobject]@{
    schema = 'comparevi-tools/local-operator-session-facade@v1'
    generatedAtUtc = [string]$Receipt.generatedAt
    backendReceiptSchema = [string]$Receipt.schema
    runtimeProfile = [string]$Receipt.runtimeProfile
    runtimePlane = if ($Receipt.PSObject.Properties['runtimePlane']) { [string]$Receipt.runtimePlane } else { 'linux' }
    repoRoot = [string]$Receipt.repoRoot
    resultsRoot = [string]$Receipt.resultsRoot
    localRefinement = Get-CompareVIFacadeValue -InputObject $Receipt -Name 'localRefinement'
    review = Get-CompareVIFacadeValue -InputObject $Receipt -Name 'review'
    artifacts = Get-CompareVIFacadeValue -InputObject $Receipt -Name 'artifacts'
    finalStatus = [string]$Receipt.finalStatus
    failure = Get-CompareVIFacadeValue -InputObject $Receipt -Name 'failure'
  }
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
    [string]$SourceBranchRef,
    [Nullable[int]]$MaxBranchCommits,

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
    [string]$SourceBranchRef,
    [Nullable[int]]$MaxBranchCommits,

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

function Invoke-CompareVIHistoryLocalRefinementFacade {
  [CmdletBinding()]
  param(
    [ValidateSet('proof', 'dev-fast', 'warm-dev', 'windows-mirror-proof')]
    [string]$Profile = 'dev-fast',
    [string]$BaseVi = 'fixtures/vi-attr/Base.vi',
    [string]$HeadVi = 'fixtures/vi-attr/Head.vi',
    [string]$RepoRoot = '',
    [string]$ToolingRoot = '',
    [string]$HistoryTargetPath = 'fixtures/vi-attr/Head.vi',
    [string]$HistoryBranchRef = 'HEAD',
    [string]$HistoryBaselineRef = '',
    [Nullable[int]]$HistoryMaxPairs,
    [Nullable[int]]$HistoryMaxCommitCount,
    [string]$ResultsRoot = '',
    [string]$WarmRuntimeDir = '',
    [string]$ProofImage = 'nationalinstruments/labview:2026q1-linux',
    [string]$DevImage = 'comparevi-vi-history-dev:local',
    [string]$WindowsMirrorImage = 'nationalinstruments/labview:2026q1-windows',
    [string]$LabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview',
    [string]$WindowsMirrorLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$WindowsHostPreflightScriptPath = '',
    [string]$WindowsCompareScriptPath = '',
    [switch]$SkipDevImageBuild
  )

  $invokeParameters = @{}
  foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($null -ne $entry.Value) {
      $invokeParameters[$entry.Key] = $entry.Value
    }
  }

  if (-not $invokeParameters.ContainsKey('RepoRoot') -or [string]::IsNullOrWhiteSpace([string]$invokeParameters['RepoRoot'])) {
    $invokeParameters['RepoRoot'] = (Get-Location).Path
  }

  $receipt = Invoke-CompareVILocalRefinementScript -Parameters $invokeParameters
  return ConvertTo-CompareVILocalRefinementFacade -Receipt $receipt
}

function Invoke-CompareVIHistoryLocalOperatorSessionFacade {
  [CmdletBinding()]
  param(
    [ValidateSet('proof', 'dev-fast', 'warm-dev', 'windows-mirror-proof')]
    [string]$Profile = 'dev-fast',
    [string]$BaseVi = 'fixtures/vi-attr/Base.vi',
    [string]$HeadVi = 'fixtures/vi-attr/Head.vi',
    [string]$RepoRoot = '',
    [string]$ToolingRoot = '',
    [string]$HistoryTargetPath = 'fixtures/vi-attr/Head.vi',
    [string]$HistoryBranchRef = 'HEAD',
    [string]$HistoryBaselineRef = '',
    [Nullable[int]]$HistoryMaxPairs,
    [Nullable[int]]$HistoryMaxCommitCount,
    [string]$ResultsRoot = '',
    [string]$WarmRuntimeDir = '',
    [string]$ProofImage = 'nationalinstruments/labview:2026q1-linux',
    [string]$DevImage = 'comparevi-vi-history-dev:local',
    [string]$WindowsMirrorImage = 'nationalinstruments/labview:2026q1-windows',
    [string]$LabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview',
    [string]$WindowsMirrorLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
    [string]$WindowsHostPreflightScriptPath = '',
    [string]$WindowsCompareScriptPath = '',
    [switch]$SkipDevImageBuild,
    [string]$ReviewCommandPath = '',
    [string[]]$ReviewCommandArguments = @(),
    [string]$ReviewWorkingDirectory = '',
    [string]$ReviewReceiptPath = '',
    [string]$ReviewBundlePath = '',
    [string]$ReviewWorkspaceHtmlPath = '',
    [string]$ReviewWorkspaceMarkdownPath = '',
    [string]$ReviewPreviewManifestPath = '',
    [string]$ReviewRunPath = '',
    [string]$SessionManifestPath = ''
  )

  $invokeParameters = @{}
  foreach ($entry in $PSBoundParameters.GetEnumerator()) {
    if ($null -ne $entry.Value) {
      $invokeParameters[$entry.Key] = $entry.Value
    }
  }

  if (-not $invokeParameters.ContainsKey('RepoRoot') -or [string]::IsNullOrWhiteSpace([string]$invokeParameters['RepoRoot'])) {
    $invokeParameters['RepoRoot'] = (Get-Location).Path
  }

  $receipt = Invoke-CompareVILocalOperatorSessionScript -Parameters $invokeParameters
  return ConvertTo-CompareVILocalOperatorSessionFacade -Receipt $receipt
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

Export-ModuleMember -Function Invoke-CompareVIHistory, Invoke-CompareVIHistoryFacade, Invoke-CompareVIHistoryLocalRefinementFacade, Invoke-CompareVIHistoryLocalOperatorSessionFacade, Invoke-CompareRefsToTemp
