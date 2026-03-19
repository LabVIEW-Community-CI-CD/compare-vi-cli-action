#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('proof', 'dev-fast', 'warm-dev')]
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
  [string]$ProofImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$DevImage = 'comparevi-vi-history-dev:local',
  [string]$LabVIEWPath = '/usr/local/natinst/LabVIEW-2026-64/labview',
  [switch]$SkipDevImageBuild,
  [switch]$PassThru,
  [string]$BuildImageScriptPath = '',
  [string]$ReviewSuiteScriptPath = '',
  [string]$WarmRuntimeManagerScriptPath = ''
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
  }

  return ('{0}-{1}' -f $RuntimeProfile, $ColdWarmClass)
}

$repoRootResolved = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -Path '..' -BasePath $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $RepoRoot -BasePath (Get-Location).Path
}
$toolingRootResolved = Resolve-ToolingRoot -PathValue $ToolingRoot -RepoRootResolved $repoRootResolved
$resultsRootResolved = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Get-ProfileDefaultResultsRoot -RepoRootResolved $repoRootResolved -RuntimeProfile $Profile
} else {
  Resolve-AbsolutePath -Path $ResultsRoot -BasePath $repoRootResolved
}
New-Item -ItemType Directory -Path $resultsRootResolved -Force | Out-Null

$buildImageScriptResolved = ''
if ($Profile -ne 'proof') {
  $buildImageScriptResolved = Resolve-ScriptPath -PathValue $BuildImageScriptPath -DefaultPath 'tools/Build-VIHistoryDevImage.ps1' -RepoRootResolved $toolingRootResolved
}
$reviewSuiteScriptResolved = Resolve-ScriptPath -PathValue $ReviewSuiteScriptPath -DefaultPath 'tools/Invoke-NILinuxReviewSuite.ps1' -RepoRootResolved $toolingRootResolved
$warmRuntimeManagerScriptResolved = ''
if ($Profile -eq 'warm-dev') {
  $warmRuntimeManagerScriptResolved = Resolve-ScriptPath -PathValue $WarmRuntimeManagerScriptPath -DefaultPath 'tools/Manage-VIHistoryRuntimeInDocker.ps1' -RepoRootResolved $toolingRootResolved
}

$imageUsed = if ($Profile -eq 'proof') { $ProofImage } else { $DevImage }
$cacheReuseState = 'none'
$coldWarmClass = 'cold'
$toolSource = if ($Profile -eq 'proof') { 'canonical-proof-image' } else { 'local-dev-image' }
$warmRuntimeState = $null

if ($Profile -ne 'proof') {
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
  $cacheReuseState = 'canonical-proof-image'
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
  $warmRuntimeJson = & $warmRuntimeManagerScriptResolved `
    -Action reconcile `
    -RepoRoot $repoRootResolved `
    -ResultsRoot $resultsRootResolved `
    -RuntimeDir $warmRuntimeDir `
    -Image $imageUsed
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

  $reviewParams.ReuseContainerName = [string]$warmRuntimeState.container.name
  $reviewParams.ReuseRepoHostPath = [string]$warmRuntimeState.mounts.repoHostPath
  $reviewParams.ReuseRepoContainerPath = [string]$warmRuntimeState.mounts.repoContainerPath
  $reviewParams.ReuseResultsHostPath = [string]$warmRuntimeState.mounts.resultsHostPath
  $reviewParams.ReuseResultsContainerPath = [string]$warmRuntimeState.mounts.resultsContainerPath
}

$timer = [System.Diagnostics.Stopwatch]::StartNew()
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
  warmRuntime = if ($warmRuntimeState) { $warmRuntimeState } else { $null }
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
  }
  selectedSamples = [ordered]@{
    proofCold = if ($latestBySampleKind.ContainsKey('proof-cold')) { $latestBySampleKind['proof-cold'] } else { $null }
    devFastCold = if ($latestBySampleKind.ContainsKey('dev-fast-cold')) { $latestBySampleKind['dev-fast-cold'] } else { $null }
    warmDevRepeat = if ($latestBySampleKind.ContainsKey('warm-dev-repeat')) { $latestBySampleKind['warm-dev-repeat'] } else { $null }
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
  }
}
$benchmarkPath = Join-Path $resultsRootResolved 'local-refinement-benchmark.json'
Write-JsonFile -Path $benchmarkPath -Payload $benchmarkPayload

if ($PassThru) {
  [pscustomobject]$receipt
}
