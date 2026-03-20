#Requires -Version 7.0
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
  [ValidateRange(1, 64)]
  [int]$HistoryMaxPairs = 2,
  [ValidateRange(1, 4096)]
  [int]$HistoryMaxCommitCount = 64,
  [string]$ResultsRoot = '',
  [string]$WarmRuntimeDir = '',
  [ValidateRange(0, 8)]
  [int]$HeavyExecutionParallelism = 0,
  [string]$HostRamBudgetPath = '',
  [Nullable[long]]$HostRamBudgetTotalBytes = $null,
  [Nullable[long]]$HostRamBudgetFreeBytes = $null,
  [Nullable[int]]$HostRamBudgetCpuParallelism = $null,
  [string]$ProofImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$DevImage = 'comparevi-vi-history-dev:local',
  [string]$WindowsMirrorImage = 'nationalinstruments/labview:2026q1-windows',
  [string]$LabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview',
  [string]$WindowsMirrorLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe',
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
  [string]$SessionManifestPath = '',
  [switch]$PassThru,
  [string]$LocalRefinementScriptPath = '',
  [string]$WindowsHostPreflightScriptPath = '',
  [string]$WindowsCompareScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-OptionalAbsolutePath {
  param(
    [AllowEmptyString()][string]$Path,
    [Parameter(Mandatory)][string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  return Resolve-AbsolutePath -Path $Path -BasePath $BasePath
}

function Write-JsonFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object]$Payload
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  $Payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Resolve-ScriptPath {
  param(
    [AllowEmptyString()][string]$PathValue,
    [Parameter(Mandatory)][string]$DefaultPath,
    [Parameter(Mandatory)][string]$RepoRootResolved
  )

  $candidate = if ([string]::IsNullOrWhiteSpace($PathValue)) { $DefaultPath } else { $PathValue }
  $resolved = Resolve-AbsolutePath -Path $candidate -BasePath $RepoRootResolved
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw ("Script not found: {0}" -f $resolved)
  }
  return $resolved
}

function Resolve-ToolingRoot {
  param(
    [AllowEmptyString()][string]$PathValue,
    [Parameter(Mandatory)][string]$RepoRootResolved
  )

  $candidate = if ([string]::IsNullOrWhiteSpace($PathValue)) {
    $env:COMPAREVI_SCRIPTS_ROOT
  } else {
    $PathValue
  }

  if ([string]::IsNullOrWhiteSpace($candidate)) {
    return $RepoRootResolved
  }

  return Resolve-AbsolutePath -Path $candidate -BasePath (Get-Location).Path
}

function Get-OptionalObjectValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory)][string]$Name
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

function New-TimingPayload {
  param([Parameter(Mandatory)][System.Diagnostics.Stopwatch]$Stopwatch)

  return [ordered]@{
    elapsedMilliseconds = [int]$Stopwatch.ElapsedMilliseconds
    elapsedSeconds = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 3)
  }
}

function Set-ScopedEnvironmentValue {
  param(
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()][string]$Value,
    [Parameter(Mandatory)][hashtable]$ScopeState
  )

  if (-not $ScopeState.ContainsKey($Name)) {
    $existingItem = Get-Item ("Env:{0}" -f $Name) -ErrorAction SilentlyContinue
    $ScopeState[$Name] = @{
      existed = Test-Path ("Env:{0}" -f $Name)
      value = if ($null -ne $existingItem) { $existingItem.Value } else { $null }
    }
  }

  if ($null -eq $Value) {
    Remove-Item ("Env:{0}" -f $Name) -ErrorAction SilentlyContinue
  } else {
    Set-Item ("Env:{0}" -f $Name) -Value $Value
  }
}

function Restore-ScopedEnvironment {
  param([Parameter(Mandatory)][hashtable]$ScopeState)

  foreach ($entry in $ScopeState.GetEnumerator()) {
    $name = [string]$entry.Key
    $state = $entry.Value
    if ($state.existed) {
      Set-Item ("Env:{0}" -f $name) -Value $state.value
    } else {
      Remove-Item ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
    }
  }
}

function New-ReviewOutputsPayload {
  param(
    [AllowNull()][string]$ReviewReceiptResolved,
    [AllowNull()][string]$ReviewBundleResolved,
    [AllowNull()][string]$ReviewWorkspaceHtmlResolved,
    [AllowNull()][string]$ReviewWorkspaceMarkdownResolved,
    [AllowNull()][string]$ReviewPreviewManifestResolved,
    [AllowNull()][string]$ReviewRunResolved
  )

  return [ordered]@{
    receiptPath = $ReviewReceiptResolved
    reviewBundlePath = $ReviewBundleResolved
    workspaceHtmlPath = $ReviewWorkspaceHtmlResolved
    workspaceMarkdownPath = $ReviewWorkspaceMarkdownResolved
    previewManifestPath = $ReviewPreviewManifestResolved
    runPath = $ReviewRunResolved
  }
}

function Select-LocalRefinementReceipt {
  param([AllowNull()]$InvocationResult)

  $candidateReceipts = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($InvocationResult)) {
    if ($null -eq $candidate) {
      continue
    }

    if ($candidate.PSObject.Properties['schema'] -and [string]$candidate.schema -eq 'comparevi/local-refinement@v1') {
      $candidateReceipts.Add($candidate) | Out-Null
    }
  }

  if ($candidateReceipts.Count -eq 1) {
    return $candidateReceipts[0]
  }

  if ($candidateReceipts.Count -gt 1) {
    throw 'Invoke-VIHistoryLocalRefinement.ps1 returned multiple comparevi/local-refinement@v1 receipts.'
  }

  if ($null -eq $InvocationResult) {
    return $null
  }

  throw 'Invoke-VIHistoryLocalRefinement.ps1 did not return a comparevi/local-refinement@v1 receipt.'
}

$repoRootResolved = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -Path '..' -BasePath $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
}
$toolingRootResolved = Resolve-ToolingRoot -PathValue $ToolingRoot -RepoRootResolved $repoRootResolved

$localRefinementScriptResolved = Resolve-ScriptPath `
  -PathValue $LocalRefinementScriptPath `
  -DefaultPath 'tools/Invoke-VIHistoryLocalRefinement.ps1' `
  -RepoRootResolved $toolingRootResolved

$refinementParameters = [ordered]@{
  Profile = $Profile
  BaseVi = $BaseVi
  HeadVi = $HeadVi
  RepoRoot = $repoRootResolved
  ToolingRoot = $toolingRootResolved
  HistoryTargetPath = $HistoryTargetPath
  HistoryBranchRef = $HistoryBranchRef
  HistoryBaselineRef = $HistoryBaselineRef
  HistoryMaxPairs = $HistoryMaxPairs
  HistoryMaxCommitCount = $HistoryMaxCommitCount
  ResultsRoot = $ResultsRoot
  WarmRuntimeDir = $WarmRuntimeDir
  HeavyExecutionParallelism = $HeavyExecutionParallelism
  HostRamBudgetPath = $HostRamBudgetPath
  HostRamBudgetTotalBytes = $HostRamBudgetTotalBytes
  HostRamBudgetFreeBytes = $HostRamBudgetFreeBytes
  HostRamBudgetCpuParallelism = $HostRamBudgetCpuParallelism
  ProofImage = $ProofImage
  DevImage = $DevImage
  WindowsMirrorImage = $WindowsMirrorImage
  LabVIEWPath = $LabVIEWPath
  WindowsMirrorLabVIEWPath = $WindowsMirrorLabVIEWPath
  WindowsHostPreflightScriptPath = $WindowsHostPreflightScriptPath
  WindowsCompareScriptPath = $WindowsCompareScriptPath
}
if ($SkipDevImageBuild) {
  $refinementParameters.SkipDevImageBuild = $true
}
$refinementParameters.PassThru = $true

$localRefinementReceipt = $null
$reviewStatus = 'not-requested'
$reviewCommandResolved = $null
$reviewWorkingDirectoryResolved = $null
$reviewTimingPayload = $null
$reviewFailureMessage = $null
$failurePayload = $null
$finalStatus = 'failed'
$sessionReceipt = $null
$resultsRootResolved = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) { $null } else { Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved }
$sessionManifestResolved = if ([string]::IsNullOrWhiteSpace($SessionManifestPath)) {
  $null
} else {
  Resolve-AbsolutePath -Path $SessionManifestPath -BasePath $repoRootResolved
}
$reviewOutputsPayload = New-ReviewOutputsPayload `
  -ReviewReceiptResolved (Resolve-OptionalAbsolutePath -Path $ReviewReceiptPath -BasePath $repoRootResolved) `
  -ReviewBundleResolved (Resolve-OptionalAbsolutePath -Path $ReviewBundlePath -BasePath $repoRootResolved) `
  -ReviewWorkspaceHtmlResolved (Resolve-OptionalAbsolutePath -Path $ReviewWorkspaceHtmlPath -BasePath $repoRootResolved) `
  -ReviewWorkspaceMarkdownResolved (Resolve-OptionalAbsolutePath -Path $ReviewWorkspaceMarkdownPath -BasePath $repoRootResolved) `
  -ReviewPreviewManifestResolved (Resolve-OptionalAbsolutePath -Path $ReviewPreviewManifestPath -BasePath $repoRootResolved) `
  -ReviewRunResolved (Resolve-OptionalAbsolutePath -Path $ReviewRunPath -BasePath $repoRootResolved)

try {
  $localRefinementReceipt = Select-LocalRefinementReceipt -InvocationResult (& $localRefinementScriptResolved @refinementParameters)
  if (-not $localRefinementReceipt) {
    throw 'Invoke-VIHistoryLocalRefinement.ps1 did not return a receipt.'
  }
  if ([string]$localRefinementReceipt.schema -ne 'comparevi/local-refinement@v1') {
    throw ("Unexpected local refinement receipt schema: {0}" -f [string]$localRefinementReceipt.schema)
  }

  $resultsRootResolved = Resolve-AbsolutePath -Path ([string]$localRefinementReceipt.resultsRoot) -BasePath $repoRootResolved
  $localRefinementReceiptPath = Join-Path $resultsRootResolved 'local-refinement.json'
  $benchmarkPath = Join-Path $resultsRootResolved 'local-refinement-benchmark.json'
  if (-not $sessionManifestResolved) {
    $sessionManifestResolved = Join-Path $resultsRootResolved 'local-operator-session.json'
  }

  if (-not [string]::IsNullOrWhiteSpace($ReviewCommandPath)) {
    $reviewCommandResolved = Resolve-AbsolutePath -Path $ReviewCommandPath -BasePath $repoRootResolved
    if (-not (Test-Path -LiteralPath $reviewCommandResolved -PathType Leaf)) {
      throw ("Review command not found: {0}" -f $reviewCommandResolved)
    }

    $reviewWorkingDirectoryResolved = if ([string]::IsNullOrWhiteSpace($ReviewWorkingDirectory)) {
      $repoRootResolved
    } else {
      Resolve-AbsolutePath -Path $ReviewWorkingDirectory -BasePath $repoRootResolved
    }
    if (-not (Test-Path -LiteralPath $reviewWorkingDirectoryResolved -PathType Container)) {
      throw ("Review working directory not found: {0}" -f $reviewWorkingDirectoryResolved)
    }

    $reviewEnvState = @{}
    try {
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_RUNTIME_PROFILE' -Value ([string]$localRefinementReceipt.runtimeProfile) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH' -Value $localRefinementReceiptPath -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_REFINEMENT_BENCHMARK_PATH' -Value $benchmarkPath -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_REFINEMENT_RESULTS_ROOT' -Value $resultsRootResolved -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_OPERATOR_SESSION_PATH' -Value $sessionManifestResolved -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_REFINEMENT_IMAGE' -Value ([string]$localRefinementReceipt.image) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_LOCAL_REFINEMENT_TOOL_SOURCE' -Value ([string]$localRefinementReceipt.toolSource) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_RECEIPT_PATH' -Value ([string]$reviewOutputsPayload.receiptPath) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_BUNDLE_PATH' -Value ([string]$reviewOutputsPayload.reviewBundlePath) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_WORKSPACE_HTML_PATH' -Value ([string]$reviewOutputsPayload.workspaceHtmlPath) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_WORKSPACE_MARKDOWN_PATH' -Value ([string]$reviewOutputsPayload.workspaceMarkdownPath) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_PREVIEW_MANIFEST_PATH' -Value ([string]$reviewOutputsPayload.previewManifestPath) -ScopeState $reviewEnvState
      Set-ScopedEnvironmentValue -Name 'COMPAREVI_REVIEW_RUN_PATH' -Value ([string]$reviewOutputsPayload.runPath) -ScopeState $reviewEnvState

      $reviewTimer = [System.Diagnostics.Stopwatch]::StartNew()
      Push-Location $reviewWorkingDirectoryResolved
      try {
        & $reviewCommandResolved @ReviewCommandArguments
        $reviewExitCode = $LASTEXITCODE
      } finally {
        Pop-Location | Out-Null
        $reviewTimer.Stop()
      }
      $reviewTimingPayload = New-TimingPayload -Stopwatch $reviewTimer
      if ($reviewExitCode -ne 0) {
        $reviewStatus = 'failed'
        $reviewFailureMessage = ("Review command failed with exit code {0}." -f $reviewExitCode)
        throw $reviewFailureMessage
      }

      $reviewStatus = 'succeeded'
    } finally {
      Restore-ScopedEnvironment -ScopeState $reviewEnvState
    }
  }

  $finalStatus = 'succeeded'
} catch {
  if ($reviewStatus -eq 'not-requested' -and -not [string]::IsNullOrWhiteSpace($ReviewCommandPath)) {
    $reviewStatus = 'failed'
  }
  $failureStage = if ($null -eq $localRefinementReceipt) { 'local-refinement' } elseif ($reviewStatus -eq 'failed') { 'review' } else { 'operator-session' }
  $failurePayload = [ordered]@{
    stage = $failureStage
    message = $_.Exception.Message
  }
}

if (-not $resultsRootResolved) {
  $resultsRootResolved = Join-Path $repoRootResolved ('tests/results/local-vi-history/{0}' -f $Profile)
}
New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null

$localRefinementReceiptPath = Join-Path $resultsRootResolved 'local-refinement.json'
$benchmarkPath = Join-Path $resultsRootResolved 'local-refinement-benchmark.json'
if (-not $sessionManifestResolved) {
  $sessionManifestResolved = Join-Path $resultsRootResolved 'local-operator-session.json'
}

$warmRuntimeArtifacts = $null
if ($localRefinementReceipt -and $localRefinementReceipt.PSObject.Properties['warmRuntime'] -and $localRefinementReceipt.warmRuntime) {
  $warmRuntimeArtifacts = $localRefinementReceipt.warmRuntime.artifacts
}
$hostRamBudget = if ($localRefinementReceipt -and $localRefinementReceipt.PSObject.Properties['hostRamBudget']) {
  $localRefinementReceipt.hostRamBudget
} else {
  $null
}
$windowsMirrorPayload = if (
  $localRefinementReceipt -and
  $localRefinementReceipt.PSObject.Properties['windowsMirror'] -and
  $localRefinementReceipt.windowsMirror
) {
  $localRefinementReceipt.windowsMirror
} else {
  $null
}
$windowsMirrorHostPreflight = Get-OptionalObjectValue -InputObject $windowsMirrorPayload -Name 'hostPreflight'
$windowsMirrorCompare = Get-OptionalObjectValue -InputObject $windowsMirrorPayload -Name 'compare'

$sessionReceipt = [ordered]@{
  schema = 'comparevi/local-operator-session@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  runtimeProfile = if ($localRefinementReceipt) { [string]$localRefinementReceipt.runtimeProfile } else { $Profile }
  runtimePlane = if ($localRefinementReceipt -and $localRefinementReceipt.PSObject.Properties['runtimePlane']) { [string]$localRefinementReceipt.runtimePlane } else { 'linux' }
  repoRoot = if ($localRefinementReceipt) { [string]$localRefinementReceipt.repoRoot } else { $repoRootResolved }
  resultsRoot = $resultsRootResolved
  localRefinement = if ($localRefinementReceipt) {
    [ordered]@{
      schema = [string]$localRefinementReceipt.schema
      receiptPath = $localRefinementReceiptPath
      benchmarkPath = $benchmarkPath
      runtimePlane = if ($localRefinementReceipt.PSObject.Properties['runtimePlane']) { [string]$localRefinementReceipt.runtimePlane } else { 'linux' }
      image = [string]$localRefinementReceipt.image
      toolSource = [string]$localRefinementReceipt.toolSource
      cacheReuseState = [string]$localRefinementReceipt.cacheReuseState
      coldWarmClass = [string]$localRefinementReceipt.coldWarmClass
      benchmarkSampleKind = [string]$localRefinementReceipt.benchmarkSampleKind
      hostRamBudget = if ($localRefinementReceipt.PSObject.Properties['hostRamBudget']) { $localRefinementReceipt.hostRamBudget } else { $null }
      timings = $localRefinementReceipt.timings
      windowsMirror = $windowsMirrorPayload
      finalStatus = [string]$localRefinementReceipt.finalStatus
    }
  } else {
    $null
  }
  review = [ordered]@{
    status = $reviewStatus
    commandPath = $reviewCommandResolved
    arguments = @($ReviewCommandArguments)
    workingDirectory = $reviewWorkingDirectoryResolved
    timings = $reviewTimingPayload
    outputs = $reviewOutputsPayload
  }
  hostRamBudget = $hostRamBudget
  artifacts = [ordered]@{
    sessionPath = $sessionManifestResolved
    localRefinementPath = if (Test-Path -LiteralPath $localRefinementReceiptPath -PathType Leaf) { $localRefinementReceiptPath } else { $null }
    benchmarkPath = if (Test-Path -LiteralPath $benchmarkPath -PathType Leaf) { $benchmarkPath } else { $null }
    hostRamBudgetPath = [string](Get-OptionalObjectValue -InputObject $hostRamBudget -Name 'path')
    warmRuntimeStatePath = if ($warmRuntimeArtifacts) { [string]$warmRuntimeArtifacts.statePath } else { $null }
    warmRuntimeHealthPath = if ($warmRuntimeArtifacts) { [string]$warmRuntimeArtifacts.healthPath } else { $null }
    warmRuntimeLeasePath = if ($warmRuntimeArtifacts) { [string]$warmRuntimeArtifacts.leasePath } else { $null }
    windowsMirrorHostPreflightPath = [string](Get-OptionalObjectValue -InputObject $windowsMirrorHostPreflight -Name 'path')
    windowsMirrorReportPath = [string](Get-OptionalObjectValue -InputObject $windowsMirrorCompare -Name 'reportPath')
    windowsMirrorCapturePath = [string](Get-OptionalObjectValue -InputObject $windowsMirrorCompare -Name 'capturePath')
    windowsMirrorRuntimeSnapshotPath = [string](Get-OptionalObjectValue -InputObject $windowsMirrorCompare -Name 'runtimeSnapshotPath')
    reviewReceiptPath = [string]$reviewOutputsPayload.receiptPath
    reviewBundlePath = [string]$reviewOutputsPayload.reviewBundlePath
    workspaceHtmlPath = [string]$reviewOutputsPayload.workspaceHtmlPath
    workspaceMarkdownPath = [string]$reviewOutputsPayload.workspaceMarkdownPath
    previewManifestPath = [string]$reviewOutputsPayload.previewManifestPath
    runPath = [string]$reviewOutputsPayload.runPath
  }
  finalStatus = $finalStatus
}

if ($failurePayload) {
  $sessionReceipt.failure = $failurePayload
}

Write-JsonFile -Path $sessionManifestResolved -Payload $sessionReceipt

if ($PassThru) {
  [pscustomobject]$sessionReceipt
}

if ($finalStatus -ne 'succeeded') {
  if ($failurePayload) {
    throw $failurePayload.message
  }
  throw 'Local operator session failed.'
}
