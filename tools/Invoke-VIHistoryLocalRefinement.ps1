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
  [switch]$PassThru,
  [string]$BuildImageScriptPath = '',
  [string]$ReviewSuiteScriptPath = '',
  [string]$WarmRuntimeManagerScriptPath = '',
  [string]$WindowsHostPreflightScriptPath = '',
  [string]$WindowsCompareScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HostRamBudget.psm1') -Force

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

function Test-DockerImageExists {
  param([Parameter(Mandatory)][string]$ImageName)

  & docker image inspect $ImageName *> $null
  return ($LASTEXITCODE -eq 0)
}

function Get-ProfileDefaultResultsRoot {
  param(
    [Parameter(Mandatory)][string]$RepoRootResolved,
    [Parameter(Mandatory)][string]$RuntimeProfile
  )

  return Join-Path $RepoRootResolved ('tests/results/local-vi-history/{0}' -f $RuntimeProfile)
}

function Get-WarmRuntimeDirectory {
  param(
    [AllowEmptyString()][string]$PathValue,
    [Parameter(Mandatory)][string]$RepoRootResolved,
    [Parameter(Mandatory)][string]$ResultsRootResolved
  )

  if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
    return Resolve-AbsolutePath -Path $PathValue -BasePath $RepoRootResolved
  }

  $resultsParent = Split-Path -Parent $ResultsRootResolved
  $resultsLeaf = Split-Path -Leaf $ResultsRootResolved
  return Join-Path (Join-Path $resultsParent 'runtime') $resultsLeaf
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

function Get-DefaultLocalRefinementHostRamBudgetPath {
  param(
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][string]$ResultsRootResolved,
    [AllowNull()][string]$WarmRuntimeDirResolved
  )

  if (
    [string]::Equals($ProfileName, 'warm-dev', [System.StringComparison]::OrdinalIgnoreCase) -and
    -not [string]::IsNullOrWhiteSpace($WarmRuntimeDirResolved)
  ) {
    return Join-Path $WarmRuntimeDirResolved 'host-ram-budget.json'
  }

  return Join-Path $ResultsRootResolved 'host-ram-budget.json'
}

function Resolve-DefaultAwarePath {
  param(
    [Parameter(Mandatory)][string]$PathValue,
    [Parameter(Mandatory)][string]$DefaultRelativePath,
    [Parameter(Mandatory)][string]$RepoRootResolved,
    [Parameter(Mandatory)][string]$ToolingRootResolved
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  if (
    [string]::Equals($PathValue, $DefaultRelativePath, [System.StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath (Join-Path $ToolingRootResolved $PathValue))
  ) {
    return Resolve-AbsolutePath -Path $PathValue -BasePath $ToolingRootResolved
  }

  return Resolve-AbsolutePath -Path $PathValue -BasePath $RepoRootResolved
}

function Read-JsonText {
  param([Parameter(Mandatory)][string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return $null
  }

  try {
    return $Text | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  } catch {
    return $null
  }
}

function Read-JsonFileIfPresent {
  param([AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 20 -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Add-HostRamBudgetProjectionToJsonArtifact {
  param(
    [AllowEmptyString()][string]$Path,
    [AllowNull()]$HostRamBudget
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $HostRamBudget) {
    return $null
  }

  $payload = Read-JsonFileIfPresent -Path $Path
  if ($null -eq $payload) {
    return $null
  }

  if ($payload -is [System.Collections.IDictionary]) {
    $payload['hostRamBudget'] = $HostRamBudget
  } else {
    $payload | Add-Member -NotePropertyName 'hostRamBudget' -NotePropertyValue $HostRamBudget -Force
  }

  Write-JsonFile -Path $Path -Payload $payload
  return $payload
}

function Select-WindowsCompareCapture {
  param(
    [AllowNull()]$InvocationResult,
    [AllowEmptyString()][string]$CapturePath
  )

  $candidateCaptures = New-Object System.Collections.Generic.List[object]
  foreach ($candidate in @($InvocationResult)) {
    if ($null -eq $candidate) {
      continue
    }

    if (
      $candidate.PSObject.Properties['schema'] -and
      [string]$candidate.schema -eq 'ni-windows-container-compare/v1'
    ) {
      $candidateCaptures.Add($candidate) | Out-Null
    }
  }

  if ($candidateCaptures.Count -eq 1) {
    return $candidateCaptures[0]
  }

  if ($candidateCaptures.Count -gt 1) {
    throw 'Run-NIWindowsContainerCompare.ps1 returned multiple ni-windows-container-compare/v1 captures.'
  }

  $captureFromDisk = Read-JsonFileIfPresent -Path $CapturePath
  if ($captureFromDisk) {
    return $captureFromDisk
  }

  if ($null -eq $InvocationResult) {
    return $null
  }

  throw 'Run-NIWindowsContainerCompare.ps1 did not return a ni-windows-container-compare/v1 capture.'
}

function Parse-UtcDateTime {
  param([AllowEmptyString()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  try {
    return [datetime]::Parse(
      $Value,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
  } catch {
    return $null
  }
}

function Get-BenchmarkSampleKind {
  param(
    [Parameter(Mandatory)][string]$RuntimeProfile,
    [Parameter(Mandatory)][string]$ColdWarmClass,
    [Parameter(Mandatory)][string]$CacheReuseState
  )

  switch ($RuntimeProfile) {
    'proof' {
      return 'proof-cold'
    }
    'dev-fast' {
      if ($ColdWarmClass -eq 'cold') {
        return 'dev-fast-cold'
      }
      return 'dev-fast-repeat'
    }
    'warm-dev' {
      if ($CacheReuseState -eq 'warm-runtime-reused' -and $ColdWarmClass -eq 'warm') {
        return 'warm-dev-repeat'
      }
      return 'warm-dev-cold-start'
    }
    'windows-mirror-proof' {
      return 'windows-mirror-proof-cold'
    }
  }

  return ('{0}-{1}' -f $RuntimeProfile, $ColdWarmClass)
}

$repoRootResolved = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -Path '..' -BasePath $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
}
$canonicalWindowsMirrorImage = 'nationalinstruments/labview:2026q1-windows'
$toolingRootResolved = Resolve-ToolingRoot -PathValue $ToolingRoot -RepoRootResolved $repoRootResolved
$resultsRootResolved = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Get-ProfileDefaultResultsRoot -RepoRootResolved $repoRootResolved -RuntimeProfile $Profile
} else {
  Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved
}
New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null

$buildImageScriptResolved = ''
if ($Profile -in @('dev-fast', 'warm-dev')) {
  $buildImageScriptResolved = Resolve-ScriptPath -PathValue $BuildImageScriptPath -DefaultPath 'tools/Build-VIHistoryDevImage.ps1' -RepoRootResolved $toolingRootResolved
}
$reviewSuiteScriptResolved = ''
if ($Profile -ne 'windows-mirror-proof') {
  $reviewSuiteScriptResolved = Resolve-ScriptPath -PathValue $ReviewSuiteScriptPath -DefaultPath 'tools/Invoke-NILinuxReviewSuite.ps1' -RepoRootResolved $toolingRootResolved
}
$warmRuntimeManagerScriptResolved = ''
if ($Profile -eq 'warm-dev') {
  $warmRuntimeManagerScriptResolved = Resolve-ScriptPath -PathValue $WarmRuntimeManagerScriptPath -DefaultPath 'tools/Manage-VIHistoryRuntimeInDocker.ps1' -RepoRootResolved $toolingRootResolved
}
$windowsHostPreflightScriptResolved = ''
$windowsCompareScriptResolved = ''
if ($Profile -eq 'windows-mirror-proof') {
  if (-not [string]::Equals($WindowsMirrorImage, $canonicalWindowsMirrorImage, [System.StringComparison]::Ordinal)) {
    throw ("windows-mirror-proof is pinned to canonical image '{0}'; received '{1}'." -f $canonicalWindowsMirrorImage, $WindowsMirrorImage)
  }
  $windowsHostPreflightScriptResolved = Resolve-ScriptPath -PathValue $WindowsHostPreflightScriptPath -DefaultPath 'tools/Test-WindowsNI2026q1HostPreflight.ps1' -RepoRootResolved $toolingRootResolved
  $windowsCompareScriptResolved = Resolve-ScriptPath -PathValue $WindowsCompareScriptPath -DefaultPath 'tools/Run-NIWindowsContainerCompare.ps1' -RepoRootResolved $toolingRootResolved
}

$runtimePlane = if ($Profile -eq 'windows-mirror-proof') { 'windows-mirror' } else { 'linux' }
$imageUsed = switch ($Profile) {
  'proof' { $ProofImage }
  'windows-mirror-proof' { $canonicalWindowsMirrorImage }
  default { $DevImage }
}
$cacheReuseState = 'none'
$coldWarmClass = 'cold'
$toolSource = switch ($Profile) {
  'proof' { 'canonical-proof-image' }
  'windows-mirror-proof' { 'windows-mirror-proof-image' }
  default { 'local-dev-image' }
}
$warmRuntimeState = $null
$windowsMirrorReceipt = $null
$hostRamBudget = $null
$warmRuntimeDir = $null
$hostRamBudgetTargetProfile = if ($Profile -eq 'windows-mirror-proof') { 'windows-mirror-heavy' } else { 'heavy' }

if ($Profile -in @('dev-fast', 'warm-dev')) {
  if (-not (Test-DockerImageExists -ImageName $imageUsed)) {
    if ($SkipDevImageBuild) {
      throw ("Dev image '{0}' is not available locally and -SkipDevImageBuild was requested." -f $imageUsed)
    }
    & $buildImageScriptResolved -Tag $imageUsed
    if ($LASTEXITCODE -ne 0) {
      throw ("Build-VIHistoryDevImage.ps1 failed with exit code {0}." -f $LASTEXITCODE)
    }
    $cacheReuseState = 'built-local-image'
    $coldWarmClass = 'cold'
  } else {
    $cacheReuseState = 'existing-local-image'
    $coldWarmClass = 'warm'
  }
} else {
  $cacheReuseState = if ($Profile -eq 'windows-mirror-proof') { 'canonical-windows-proof-image' } else { 'canonical-proof-image' }
}

$reviewParams = [ordered]@{
  BaseVi = Resolve-DefaultAwarePath -PathValue $BaseVi -DefaultRelativePath 'fixtures/vi-attr/Base.vi' -RepoRootResolved $repoRootResolved -ToolingRootResolved $toolingRootResolved
  HeadVi = Resolve-DefaultAwarePath -PathValue $HeadVi -DefaultRelativePath 'fixtures/vi-attr/Head.vi' -RepoRootResolved $repoRootResolved -ToolingRootResolved $toolingRootResolved
  RepoRoot = $repoRootResolved
  ResultsRoot = $resultsRootResolved
  Image = $imageUsed
  LabVIEWPath = $LabVIEWPath
  HistoryTargetPath = Resolve-DefaultAwarePath -PathValue $HistoryTargetPath -DefaultRelativePath 'fixtures/vi-attr/Head.vi' -RepoRootResolved $repoRootResolved -ToolingRootResolved $toolingRootResolved
  HistoryBranchRef = $HistoryBranchRef
  HistoryMaxPairs = $HistoryMaxPairs
  HistoryMaxCommitCount = $HistoryMaxCommitCount
}
if (-not [string]::IsNullOrWhiteSpace($HistoryBaselineRef)) {
  $reviewParams.HistoryBaselineRef = $HistoryBaselineRef
}

if ($Profile -eq 'warm-dev') {
  $warmRuntimeDir = Get-WarmRuntimeDirectory `
    -PathValue $WarmRuntimeDir `
    -RepoRootResolved $repoRootResolved `
    -ResultsRootResolved $resultsRootResolved
  New-Item -ItemType Directory -Path $warmRuntimeDir -Force | Out-Null
  $hostRamBudgetPathResolved = if ([string]::IsNullOrWhiteSpace($HostRamBudgetPath)) {
    Get-DefaultLocalRefinementHostRamBudgetPath -ProfileName $Profile -ResultsRootResolved $resultsRootResolved -WarmRuntimeDirResolved $warmRuntimeDir
  } else {
    Resolve-AbsolutePath -Path $HostRamBudgetPath -BasePath $repoRootResolved
  }
  $warmRuntimeJson = & $warmRuntimeManagerScriptResolved `
    -Action reconcile `
    -RepoRoot $repoRootResolved `
    -ResultsRoot $resultsRootResolved `
    -RuntimeDir $warmRuntimeDir `
    -Image $imageUsed `
    -HeavyExecutionParallelism $HeavyExecutionParallelism `
    -HostRamBudgetPath $hostRamBudgetPathResolved `
    -HostRamBudgetTargetProfile $hostRamBudgetTargetProfile `
    -HostRamBudgetTotalBytes $HostRamBudgetTotalBytes `
    -HostRamBudgetFreeBytes $HostRamBudgetFreeBytes `
    -HostRamBudgetCpuParallelism $HostRamBudgetCpuParallelism
  if ($LASTEXITCODE -ne 0) {
    throw ("Manage-VIHistoryRuntimeInDocker.ps1 failed with exit code {0}." -f $LASTEXITCODE)
  }
  $warmRuntimeState = Read-JsonText -Text ($warmRuntimeJson -join "`n")
  if (-not $warmRuntimeState) {
    throw 'Warm runtime manager did not emit valid JSON state.'
  }
  switch ([string]$warmRuntimeState.outcome) {
    { $_ -in @('healthy', 'reused') } {
      $cacheReuseState = 'warm-runtime-reused'
      $coldWarmClass = 'warm'
      break
    }
    'recovered-stale-runtime' {
      $cacheReuseState = 'warm-runtime-recovered'
      $coldWarmClass = 'cold'
      break
    }
    default {
      $cacheReuseState = 'warm-runtime-started'
      $coldWarmClass = 'cold'
      break
    }
  }
  if ($warmRuntimeState.PSObject.Properties['hostRamBudget']) {
    $hostRamBudget = $warmRuntimeState.hostRamBudget
  }

  $reviewParams.ReuseContainerName = [string]$warmRuntimeState.container.name
  $reviewParams.ReuseRepoHostPath = [string]$warmRuntimeState.mounts.repoHostPath
  $reviewParams.ReuseRepoContainerPath = [string]$warmRuntimeState.mounts.repoContainerPath
  $reviewParams.ReuseResultsHostPath = [string]$warmRuntimeState.mounts.resultsHostPath
  $reviewParams.ReuseResultsContainerPath = [string]$warmRuntimeState.mounts.resultsContainerPath
  $reviewParams.FlagScenarioParallelism = if (
    $hostRamBudget -and
    $hostRamBudget.PSObject.Properties['actualParallelism']
  ) {
    [int]$hostRamBudget.actualParallelism
  } else {
    1
  }
} else {
  $hostRamBudgetPathResolved = if ([string]::IsNullOrWhiteSpace($HostRamBudgetPath)) {
    Get-DefaultLocalRefinementHostRamBudgetPath -ProfileName $Profile -ResultsRootResolved $resultsRootResolved -WarmRuntimeDirResolved $null
  } else {
    Resolve-AbsolutePath -Path $HostRamBudgetPath -BasePath $repoRootResolved
  }
  $hostRamBudgetReport = Resolve-CompareVIHostRamBudgetReport `
    -RepoRoot $toolingRootResolved `
    -OutputPath $hostRamBudgetPathResolved `
    -TargetProfile $hostRamBudgetTargetProfile `
    -TotalBytes $HostRamBudgetTotalBytes `
    -FreeBytes $HostRamBudgetFreeBytes `
    -CpuParallelism $HostRamBudgetCpuParallelism
  $hostRamBudget = New-CompareVISerialHostRamBudgetDecision `
    -BudgetReport $hostRamBudgetReport.report `
    -BudgetPath $hostRamBudgetReport.path `
    -RequestedParallelism $HeavyExecutionParallelism `
    -ReasonWhenParallelEligible 'single-review-execution'
  if ($HeavyExecutionParallelism -gt 0) {
    $reviewParams.FlagScenarioParallelism = $HeavyExecutionParallelism
  }
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
if ($Profile -eq 'windows-mirror-proof') {
  $hostPreflightPath = Join-Path $resultsRootResolved 'windows-ni-2026q1-host-preflight.json'
  $reportPath = Join-Path $resultsRootResolved 'windows-mirror-report.html'
  $runtimeSnapshotPath = Join-Path $resultsRootResolved 'windows-mirror-runtime-snapshot.json'
  $capturePath = Join-Path (Split-Path -Parent $reportPath) 'ni-windows-container-capture.json'
  $resolvedWindowsMirrorLabVIEWPath = $WindowsMirrorLabVIEWPath.Trim()
  if ([string]::IsNullOrWhiteSpace($resolvedWindowsMirrorLabVIEWPath)) {
    throw 'Windows mirror proof requires -WindowsMirrorLabVIEWPath.'
  }

  Push-Location $repoRootResolved
  try {
    & $windowsHostPreflightScriptResolved `
      -Image $imageUsed `
      -ResultsDir $resultsRootResolved `
      -OutputJsonPath $hostPreflightPath | Out-Null
    $preflightExitCode = $LASTEXITCODE
    if ($preflightExitCode -ne 0) {
      throw ("Test-WindowsNI2026q1HostPreflight.ps1 failed with exit code {0}." -f $preflightExitCode)
    }

    $windowsCompareInvocationResult = & $windowsCompareScriptResolved `
      -BaseVi $reviewParams.BaseVi `
      -HeadVi $reviewParams.HeadVi `
      -Image $imageUsed `
      -ReportPath $reportPath `
      -LabVIEWPath $resolvedWindowsMirrorLabVIEWPath `
      -RuntimeSnapshotPath $runtimeSnapshotPath `
      -PassThru
    $reviewExitCode = $LASTEXITCODE
  } finally {
    Pop-Location | Out-Null
    $timer.Stop()
  }
  if ($reviewExitCode -ne 0) {
    throw ("Run-NIWindowsContainerCompare.ps1 failed with exit code {0}." -f $reviewExitCode)
  }

  $windowsCompareCapture = Select-WindowsCompareCapture -InvocationResult $windowsCompareInvocationResult -CapturePath $capturePath
  $windowsMirrorHostRamBudget = $hostRamBudget
  $null = Add-HostRamBudgetProjectionToJsonArtifact -Path $hostPreflightPath -HostRamBudget $windowsMirrorHostRamBudget
  $projectedWindowsCompareCapture = Add-HostRamBudgetProjectionToJsonArtifact -Path $capturePath -HostRamBudget $windowsMirrorHostRamBudget
  if ($projectedWindowsCompareCapture) {
    $windowsCompareCapture = $projectedWindowsCompareCapture
  }
  $null = Add-HostRamBudgetProjectionToJsonArtifact -Path $runtimeSnapshotPath -HostRamBudget $windowsMirrorHostRamBudget
  $windowsMirrorReceipt = [ordered]@{
    hostPreflight = [ordered]@{
      path = $hostPreflightPath
    }
    compare = [ordered]@{
      reportPath = $reportPath
      capturePath = $capturePath
      runtimeSnapshotPath = $runtimeSnapshotPath
      status = if ($windowsCompareCapture -and $windowsCompareCapture.PSObject.Properties['status']) { [string]$windowsCompareCapture.status } else { '' }
      classification = if ($windowsCompareCapture -and $windowsCompareCapture.PSObject.Properties['classification']) { [string]$windowsCompareCapture.classification } else { '' }
      resultClass = if ($windowsCompareCapture -and $windowsCompareCapture.PSObject.Properties['resultClass']) { [string]$windowsCompareCapture.resultClass } else { '' }
      gateOutcome = if ($windowsCompareCapture -and $windowsCompareCapture.PSObject.Properties['gateOutcome']) { [string]$windowsCompareCapture.gateOutcome } else { '' }
      failureClass = if ($windowsCompareCapture -and $windowsCompareCapture.PSObject.Properties['failureClass']) { [string]$windowsCompareCapture.failureClass } else { '' }
    }
    hostRamBudget = $windowsMirrorHostRamBudget
    headlessContract = [ordered]@{
      required = $true
      labviewCliMode = 'headless'
    }
    labviewPath = $resolvedWindowsMirrorLabVIEWPath
  }
} else {
  Push-Location $repoRootResolved
  try {
    $null = & $reviewSuiteScriptResolved @reviewParams
    $reviewExitCode = $LASTEXITCODE
  } finally {
    Pop-Location | Out-Null
    $timer.Stop()
  }
  if ($reviewExitCode -ne 0) {
    throw ("Invoke-NILinuxReviewSuite.ps1 failed with exit code {0}." -f $reviewExitCode)
  }
}

$receiptPath = Join-Path $resultsRootResolved 'local-refinement.json'
$summaryPath = Join-Path $resultsRootResolved 'review-suite-summary.json'
$reviewLoopReceiptPath = Join-Path $resultsRootResolved 'vi-history-review-loop-receipt.json'
$summary = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
  Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 20
} else {
  $null
}
$reviewLoopReceipt = if (Test-Path -LiteralPath $reviewLoopReceiptPath -PathType Leaf) {
  Get-Content -LiteralPath $reviewLoopReceiptPath -Raw | ConvertFrom-Json -Depth 20
} else {
  $null
}

$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  runtimeProfile = $Profile
  runtimePlane = $runtimePlane
  image = $imageUsed
  toolSource = $toolSource
  cacheReuseState = $cacheReuseState
  coldWarmClass = $coldWarmClass
  benchmarkSampleKind = Get-BenchmarkSampleKind -RuntimeProfile $Profile -ColdWarmClass $coldWarmClass -CacheReuseState $cacheReuseState
  repoRoot = $repoRootResolved
  resultsRoot = $resultsRootResolved
  timings = [ordered]@{
    elapsedMilliseconds = [int]$timer.ElapsedMilliseconds
    elapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
  }
  history = [ordered]@{
    targetPath = Resolve-AbsolutePath -Path $HistoryTargetPath -BasePath $repoRootResolved
    branchRef = $HistoryBranchRef
    baselineRef = $HistoryBaselineRef
    maxPairs = [int]$HistoryMaxPairs
    maxCommitCount = [int]$HistoryMaxCommitCount
  }
  reviewSuite = if ($summary) {
    [ordered]@{
      schema = [string]$summary.schema
      image = [string]$summary.image
      scenarioCount = @($summary.scenarios).Count
      summaryPath = $summaryPath
    }
  } else {
    $null
  }
  windowsMirror = if ($windowsMirrorReceipt) { $windowsMirrorReceipt } else { $null }
  warmRuntime = if ($warmRuntimeState) { $warmRuntimeState } else { $null }
  hostRamBudget = $hostRamBudget
  reviewLoop = if ($reviewLoopReceipt) {
    [ordered]@{
      schema = [string]$reviewLoopReceipt.schema
      path = $reviewLoopReceiptPath
    }
  } else {
    $null
  }
  finalStatus = 'succeeded'
}
Write-JsonFile -Path $receiptPath -Payload $receipt

$benchmarkRoot = Join-Path $repoRootResolved 'tests/results/local-vi-history'
$allReceipts = @()
if (Test-Path -LiteralPath $benchmarkRoot -PathType Container) {
  $allReceipts = @(Get-ChildItem -Path $benchmarkRoot -Recurse -Filter 'local-refinement.json' -File -ErrorAction SilentlyContinue)
}
$latestByProfile = @{}
$latestBySampleKind = @{}
foreach ($candidate in $allReceipts) {
  try {
    $candidateReceipt = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json -Depth 20 -ErrorAction Stop
  } catch {
    continue
  }
  if ([string]$candidateReceipt.schema -ne 'comparevi/local-refinement@v1') {
    continue
  }
  $profileName = [string]$candidateReceipt.runtimeProfile
  if ([string]::IsNullOrWhiteSpace($profileName)) {
    continue
  }
  $currentGeneratedAt = Parse-UtcDateTime -Value ([string]$candidateReceipt.generatedAt)
  if (-not $currentGeneratedAt) {
    continue
  }
  if (-not $latestByProfile.ContainsKey($profileName)) {
    $latestByProfile[$profileName] = $candidateReceipt
  } else {
    $previousGeneratedAt = Parse-UtcDateTime -Value ([string]$latestByProfile[$profileName].generatedAt)
    if ($previousGeneratedAt -and $currentGeneratedAt -gt $previousGeneratedAt) {
      $latestByProfile[$profileName] = $candidateReceipt
    }
  }

  $sampleKind = [string]$candidateReceipt.benchmarkSampleKind
  if ([string]::IsNullOrWhiteSpace($sampleKind)) {
    continue
  }
  if (-not $latestBySampleKind.ContainsKey($sampleKind)) {
    $latestBySampleKind[$sampleKind] = $candidateReceipt
    continue
  }
  $previousSampleGeneratedAt = Parse-UtcDateTime -Value ([string]$latestBySampleKind[$sampleKind].generatedAt)
  if ($previousSampleGeneratedAt -and $currentGeneratedAt -gt $previousSampleGeneratedAt) {
    $latestBySampleKind[$sampleKind] = $candidateReceipt
  }
}

function New-BenchmarkComparison {
  param(
    [AllowNull()]$Left,
    [AllowNull()]$Right,
    [Parameter(Mandatory)][string]$LeftLabel,
    [Parameter(Mandatory)][string]$RightLabel
  )

  if (-not $Left -or -not $Right) {
    return $null
  }

  $leftMs = [double]$Left.timings.elapsedMilliseconds
  $rightMs = [double]$Right.timings.elapsedMilliseconds
  if ($leftMs -le 0 -or $rightMs -le 0) {
    return $null
  }

  return [ordered]@{
    left = $LeftLabel
    right = $RightLabel
    deltaMilliseconds = [int]($leftMs - $rightMs)
    improvementRatio = [math]::Round((($leftMs - $rightMs) / $leftMs), 4)
  }
}

$benchmarkPayload = [ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  latest = [ordered]@{
    proof = if ($latestByProfile.ContainsKey('proof')) { $latestByProfile['proof'] } else { $null }
    devFast = if ($latestByProfile.ContainsKey('dev-fast')) { $latestByProfile['dev-fast'] } else { $null }
    warmDev = if ($latestByProfile.ContainsKey('warm-dev')) { $latestByProfile['warm-dev'] } else { $null }
    windowsMirrorProof = if ($latestByProfile.ContainsKey('windows-mirror-proof')) { $latestByProfile['windows-mirror-proof'] } else { $null }
  }
  selectedSamples = [ordered]@{
    proofCold = if ($latestBySampleKind.ContainsKey('proof-cold')) { $latestBySampleKind['proof-cold'] } else { $null }
    devFastCold = if ($latestBySampleKind.ContainsKey('dev-fast-cold')) { $latestBySampleKind['dev-fast-cold'] } else { $null }
    warmDevRepeat = if ($latestBySampleKind.ContainsKey('warm-dev-repeat')) { $latestBySampleKind['warm-dev-repeat'] } else { $null }
    windowsMirrorProofCold = if ($latestBySampleKind.ContainsKey('windows-mirror-proof-cold')) { $latestBySampleKind['windows-mirror-proof-cold'] } else { $null }
  }
  comparisons = [ordered]@{
    devFastVsProof = New-BenchmarkComparison `
      -Left $(if ($latestBySampleKind.ContainsKey('proof-cold')) { $latestBySampleKind['proof-cold'] } else { $null }) `
      -Right $(if ($latestBySampleKind.ContainsKey('dev-fast-cold')) { $latestBySampleKind['dev-fast-cold'] } else { $null }) `
      -LeftLabel 'proof-cold' `
      -RightLabel 'dev-fast-cold'
    warmDevVsDevFast = New-BenchmarkComparison `
      -Left $(if ($latestBySampleKind.ContainsKey('dev-fast-cold')) { $latestBySampleKind['dev-fast-cold'] } else { $null }) `
      -Right $(if ($latestBySampleKind.ContainsKey('warm-dev-repeat')) { $latestBySampleKind['warm-dev-repeat'] } else { $null }) `
      -LeftLabel 'dev-fast-cold' `
      -RightLabel 'warm-dev-repeat'
    windowsMirrorVsLinuxProof = New-BenchmarkComparison `
      -Left $(if ($latestBySampleKind.ContainsKey('proof-cold')) { $latestBySampleKind['proof-cold'] } else { $null }) `
      -Right $(if ($latestBySampleKind.ContainsKey('windows-mirror-proof-cold')) { $latestBySampleKind['windows-mirror-proof-cold'] } else { $null }) `
      -LeftLabel 'proof-cold' `
      -RightLabel 'windows-mirror-proof-cold'
  }
}
$benchmarkPath = Join-Path $resultsRootResolved 'local-refinement-benchmark.json'
Write-JsonFile -Path $benchmarkPath -Payload $benchmarkPayload

if ($PassThru) {
  [pscustomobject]$receipt
}
