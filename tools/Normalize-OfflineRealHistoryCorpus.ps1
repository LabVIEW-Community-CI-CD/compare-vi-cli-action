#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CatalogPath = 'fixtures/real-history/offline-corpus.targets.json',
  [string]$OutputPath = 'fixtures/real-history/offline-corpus.normalized.json',
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

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $PathValue
  $normalizedRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
  if ($resolved.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $relative = $resolved.Substring($normalizedRoot.Length).TrimStart('\', '/')
    return ($relative -replace '\\', '/')
  }

  return ($resolved -replace '\\', '/')
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 64 -DateKind String)
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

function Test-HasProperty {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  if ($InputObject -is [System.Collections.IDictionary]) {
    return $InputObject.Contains($Name)
  }

  return ($null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name])
}

function Get-PropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()]$Default = $null
  )

  if (Test-HasProperty -InputObject $InputObject -Name $Name) {
    if ($InputObject -is [System.Collections.IDictionary]) {
      return $InputObject[$Name]
    }

    return $InputObject.PSObject.Properties[$Name].Value
  }

  return $Default
}

function Test-NonEmptyString {
  param([AllowNull()][object]$Value)

  return (-not [string]::IsNullOrWhiteSpace([string]$Value))
}

function Get-StringArray {
  param([AllowNull()][object]$Value)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if (-not (Test-NonEmptyString -Value $item)) {
      continue
    }

    $items.Add(([string]$item).Trim()) | Out-Null
  }

  return @($items.ToArray())
}

function Get-SortedUniqueStringArray {
  param([AllowNull()][object]$Value)

  return @(
    Get-StringArray -Value $Value |
      Sort-Object -Unique
  )
}

function Get-SortedUniqueIntArray {
  param([AllowNull()][object]$Value)

  $items = New-Object System.Collections.Generic.List[int]
  foreach ($item in @($Value)) {
    if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item)) {
      continue
    }

    $items.Add([int]$item) | Out-Null
  }

  return @($items.ToArray() | Sort-Object -Unique)
}

function Get-SortedUniquePathArray {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [AllowNull()][object]$Value
  )

  $paths = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if (-not (Test-NonEmptyString -Value $item)) {
      continue
    }

    $paths.Add((Convert-ToRepoRelativePath -RepoRoot $RepoRoot -PathValue ([string]$item))) | Out-Null
  }

  return @($paths.ToArray() | Sort-Object -Unique)
}

function Get-PositiveCountMap {
  param([AllowNull()][object]$Value)

  $ordered = [ordered]@{}
  if ($null -eq $Value) {
    return $ordered
  }

  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    $count = [int]$property.Value
    if ($count -le 0) {
      continue
    }

    $ordered[$name] = $count
  }

  return $ordered
}

function Get-StatsSummary {
  param([AllowNull()][object]$Stats)

  return [ordered]@{
    processed = [int](Get-PropertyValue -InputObject $Stats -Name 'processed' -Default 0)
    diffs = [int](Get-PropertyValue -InputObject $Stats -Name 'diffs' -Default 0)
    signalDiffs = [int](Get-PropertyValue -InputObject $Stats -Name 'signalDiffs' -Default 0)
    noiseCollapsed = [int](Get-PropertyValue -InputObject $Stats -Name 'noiseCollapsed' -Default 0)
    errors = [int](Get-PropertyValue -InputObject $Stats -Name 'errors' -Default 0)
    missing = [int](Get-PropertyValue -InputObject $Stats -Name 'missing' -Default 0)
    categoryCounts = Get-PositiveCountMap -Value (Get-PropertyValue -InputObject $Stats -Name 'categoryCounts')
    bucketCounts = Get-PositiveCountMap -Value (Get-PropertyValue -InputObject $Stats -Name 'bucketCounts')
  }
}

function Get-BucketProfile {
  param([AllowNull()][object]$Stats)

  $names = New-Object System.Collections.Generic.List[string]
  $bucketCounts = Get-PropertyValue -InputObject $Stats -Name 'bucketCounts'
  if ($null -ne $bucketCounts) {
    foreach ($property in @($bucketCounts.PSObject.Properties)) {
      if ([int]$property.Value -gt 0) {
        $names.Add([string]$property.Name) | Out-Null
      }
    }
  }

  $collapsedNoise = Get-PropertyValue -InputObject $Stats -Name 'collapsedNoise'
  $collapsedBucketCounts = Get-PropertyValue -InputObject $collapsedNoise -Name 'bucketCounts'
  if ($null -ne $collapsedBucketCounts) {
    foreach ($property in @($collapsedBucketCounts.PSObject.Properties)) {
      if ([int]$property.Value -gt 0) {
        $names.Add([string]$property.Name) | Out-Null
      }
    }
  }

  return @($names.ToArray() | Sort-Object -Unique)
}

function Get-CategoriesForComparison {
  param([AllowNull()][object]$Comparison)

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  $categories = Get-StringArray -Value (Get-PropertyValue -InputObject $result -Name 'categories')
  if (@($categories).Count -gt 0) {
    return $categories
  }

  return @(
    Get-PropertyValue -InputObject $result -Name 'categoryDetails' |
      ForEach-Object { Get-PropertyValue -InputObject $_ -Name 'label' } |
      Where-Object { Test-NonEmptyString -Value $_ }
  )
}

function Get-BucketForComparison {
  param([AllowNull()][object]$Comparison)

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  $bucket = [string](Get-PropertyValue -InputObject $result -Name 'bucket')
  if (Test-NonEmptyString -Value $bucket) {
    return $bucket
  }

  $bucketDetails = @(Get-PropertyValue -InputObject $result -Name 'categoryBucketDetails')
  foreach ($detail in $bucketDetails) {
    $slug = [string](Get-PropertyValue -InputObject $detail -Name 'slug')
    if (Test-NonEmptyString -Value $slug) {
      return $slug
    }
  }

  $buckets = Get-StringArray -Value (Get-PropertyValue -InputObject $result -Name 'categoryBuckets')
  if (@($buckets).Count -gt 0) {
    return $buckets[0]
  }

  return $null
}

function Get-ComparisonDiffValue {
  param([AllowNull()][object]$Comparison)

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  foreach ($candidate in @(
    (Get-PropertyValue -InputObject $result -Name 'diff'),
    (Get-PropertyValue -InputObject $Comparison -Name 'diff')
  )) {
    if ($candidate -is [bool]) {
      return [bool]$candidate
    }
  }

  return $null
}

function Get-ComparisonStatusValue {
  param([AllowNull()][object]$Comparison)

  if (Test-HasProperty -InputObject $Comparison -Name 'error') {
    return 'error'
  }

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  $status = [string](Get-PropertyValue -InputObject $result -Name 'status')
  if (Test-NonEmptyString -Value $status) {
    return $status
  }

  return $null
}

function Get-ComparisonMessageValue {
  param([AllowNull()][object]$Comparison)

  $topLevelError = [string](Get-PropertyValue -InputObject $Comparison -Name 'error')
  if (Test-NonEmptyString -Value $topLevelError) {
    return $topLevelError
  }

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  $message = [string](Get-PropertyValue -InputObject $result -Name 'message')
  if (Test-NonEmptyString -Value $message) {
    return $message
  }

  return $null
}

function Get-ComparisonClassificationValue {
  param([AllowNull()][object]$Comparison)

  $result = Get-PropertyValue -InputObject $Comparison -Name 'result'
  foreach ($candidate in @(
    [string](Get-PropertyValue -InputObject $result -Name 'classification'),
    [string](Get-PropertyValue -InputObject $Comparison -Name 'classification')
  )) {
    if (Test-NonEmptyString -Value $candidate) {
      return $candidate.Trim().ToLowerInvariant()
    }
  }

  return $null
}

function Resolve-ComparisonOutcomeClass {
  param([AllowNull()][object]$Comparison)

  $status = Get-ComparisonStatusValue -Comparison $Comparison
  if ($status -eq 'error') {
    return 'error'
  }

  if ((Test-NonEmptyString -Value $status) -and $status.StartsWith('missing-', [System.StringComparison]::OrdinalIgnoreCase)) {
    return 'missing'
  }

  $diff = Get-ComparisonDiffValue -Comparison $Comparison
  $classification = Get-ComparisonClassificationValue -Comparison $Comparison
  if ($diff -eq $true) {
    if ($classification -eq 'noise') {
      return 'noise-diff'
    }

    return 'signal-diff'
  }

  if ($diff -eq $false) {
    return 'clean'
  }

  if ($classification -eq 'noise') {
    return 'noise-diff'
  }

  if ($classification -eq 'signal') {
    return 'signal-diff'
  }

  return 'clean'
}

function Resolve-ModeOutcomeClass {
  param(
    [AllowNull()][object]$Stats,
    [Parameter(Mandatory)][string[]]$ComparisonClasses
  )

  if ([int](Get-PropertyValue -InputObject $Stats -Name 'errors' -Default 0) -gt 0 -or $ComparisonClasses -contains 'error') {
    return 'error'
  }

  if ([int](Get-PropertyValue -InputObject $Stats -Name 'missing' -Default 0) -gt 0 -or $ComparisonClasses -contains 'missing') {
    return 'missing'
  }

  if ([int](Get-PropertyValue -InputObject $Stats -Name 'signalDiffs' -Default 0) -gt 0 -or $ComparisonClasses -contains 'signal-diff') {
    return 'signal-diff'
  }

  if ([int](Get-PropertyValue -InputObject $Stats -Name 'noiseCollapsed' -Default 0) -gt 0 -or $ComparisonClasses -contains 'noise-diff') {
    return 'noise-diff'
  }

  if ([int](Get-PropertyValue -InputObject $Stats -Name 'diffs' -Default 0) -gt 0) {
    return 'signal-diff'
  }

  return 'clean'
}

function Resolve-CoverageClass {
  param(
    [Parameter(Mandatory)][string[]]$RequestedModes,
    [Parameter(Mandatory)][string[]]$ExecutedModes
  )

  $requested = Get-SortedUniqueStringArray -Value $RequestedModes
  $executed = Get-SortedUniqueStringArray -Value $ExecutedModes

  $missing = @($requested | Where-Object { $_ -notin $executed })
  $extra = @($executed | Where-Object { $_ -notin $requested })

  if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
    return 'catalog-aligned'
  }

  if ($missing.Count -gt 0 -and $extra.Count -eq 0) {
    return 'catalog-partial'
  }

  if ($missing.Count -eq 0 -and $extra.Count -gt 0) {
    return 'catalog-extra'
  }

  return 'catalog-mismatch'
}

function Resolve-ModeSensitivity {
  param([Parameter(Mandatory)][object[]]$Modes)

  if ($Modes.Count -eq 0) {
    return 'none-observed'
  }

  if ($Modes.Count -eq 1) {
    return 'single-mode-observed'
  }

  $outcomes = @(
    $Modes |
      ForEach-Object { Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $_ -Name 'annotations') -Name 'outcomeClass' } |
      Where-Object { Test-NonEmptyString -Value $_ }
  )

  if ($outcomes.Count -eq 0) {
    return 'mixed-observed-modes'
  }

  if (@($outcomes | Where-Object { $_ -ne 'clean' }).Count -eq 0) {
    return 'all-observed-modes-clean'
  }

  if (@($outcomes | Where-Object { $_ -notin @('signal-diff', 'noise-diff') }).Count -eq 0) {
    return 'all-observed-modes-diff'
  }

  return 'mixed-observed-modes'
}

function Resolve-CapturePresence {
  param(
    [Parameter(Mandatory)][int]$LvcompareCount,
    [Parameter(Mandatory)][int]$NiContainerCount
  )

  if ($LvcompareCount -gt 0 -and $NiContainerCount -gt 0) {
    return 'dual-capture'
  }

  if ($LvcompareCount -gt 0) {
    return 'lvcompare-only'
  }

  if ($NiContainerCount -gt 0) {
    return 'ni-container-only'
  }

  return 'none'
}

function Get-LatestTimestamp {
  param([AllowNull()][object]$Value)

  $latest = $null
  foreach ($candidate in @($Value)) {
    if (-not (Test-NonEmptyString -Value $candidate)) {
      continue
    }

    $parsed = [System.DateTimeOffset]::MinValue
    if (-not [System.DateTimeOffset]::TryParse([string]$candidate, [ref]$parsed)) {
      continue
    }

    if ($null -eq $latest -or $parsed -gt $latest) {
      $latest = $parsed
    }
  }

  if ($null -eq $latest) {
    return $null
  }

  return $latest.ToUniversalTime().ToString('o')
}

function Get-CaptureDiscoveryRoots {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SuiteDirectory,
    [AllowNull()][object]$SeedFixture,
    [AllowNull()][object]$ModeEntry,
    [AllowNull()][object]$ModeManifest
  )

  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($rootPath in @(Get-PropertyValue -InputObject $SeedFixture -Name 'captureRoots')) {
    if (-not (Test-NonEmptyString -Value $rootPath)) {
      continue
    }

    $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue ([string]$rootPath)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
      $roots.Add($resolved) | Out-Null
    }
  }

  foreach ($candidate in @(
    (Join-Path $SuiteDirectory ([string](Get-PropertyValue -InputObject $ModeEntry -Name 'slug' -Default (Get-PropertyValue -InputObject $ModeEntry -Name 'name' -Default (Get-PropertyValue -InputObject $ModeManifest -Name 'mode'))))),
    (Get-PropertyValue -InputObject $ModeManifest -Name 'resultsDir')
  )) {
    if (-not (Test-NonEmptyString -Value $candidate)) {
      continue
    }

    $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue ([string]$candidate)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
      $roots.Add($resolved) | Out-Null
    }
  }

  foreach ($comparison in @(Get-PropertyValue -InputObject $ModeManifest -Name 'comparisons')) {
    $result = Get-PropertyValue -InputObject $comparison -Name 'result'
    $artifactDir = [string](Get-PropertyValue -InputObject $result -Name 'artifactDir')
    if (-not (Test-NonEmptyString -Value $artifactDir)) {
      continue
    }

    $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $artifactDir
    if (Test-Path -LiteralPath $resolved -PathType Container) {
      $roots.Add($resolved) | Out-Null
    }
  }

  return @($roots.ToArray() | Sort-Object -Unique)
}

function Get-CapturePathsForMode {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SuiteDirectory,
    [AllowNull()][object]$SeedFixture,
    [AllowNull()][object]$ModeEntry,
    [AllowNull()][object]$ModeManifest
  )

  $roots = Get-CaptureDiscoveryRoots `
    -RepoRoot $RepoRoot `
    -SuiteDirectory $SuiteDirectory `
    -SeedFixture $SeedFixture `
    -ModeEntry $ModeEntry `
    -ModeManifest $ModeManifest

  $lvcompare = New-Object System.Collections.Generic.List[string]
  $niContainer = New-Object System.Collections.Generic.List[string]
  foreach ($root in $roots) {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'lvcompare-capture.json' -File -ErrorAction SilentlyContinue)) {
      $lvcompare.Add($file.FullName) | Out-Null
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'ni-windows-container-capture.json' -File -ErrorAction SilentlyContinue)) {
      $niContainer.Add($file.FullName) | Out-Null
    }
  }

  return [ordered]@{
    lvcompare = @($lvcompare.ToArray() | Sort-Object -Unique)
    niContainer = @($niContainer.ToArray() | Sort-Object -Unique)
  }
}

function Get-CaptureSummary {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [AllowEmptyCollection()][string[]]$LvcomparePaths = @(),
    [AllowEmptyCollection()][string[]]$NiContainerPaths = @()
  )

  $captureTimestamps = New-Object System.Collections.Generic.List[string]
  $lvcompareExitCodes = New-Object System.Collections.Generic.List[int]
  $lvcompareDiffStates = New-Object System.Collections.Generic.List[string]
  $niStatuses = New-Object System.Collections.Generic.List[string]
  $niImages = New-Object System.Collections.Generic.List[string]

  foreach ($path in $LvcomparePaths) {
    $capture = Read-JsonFile -Path $path
    $timestamp = [string](Get-PropertyValue -InputObject $capture -Name 'timestamp')
    if (Test-NonEmptyString -Value $timestamp) {
      $captureTimestamps.Add($timestamp) | Out-Null
    }

    $cli = Get-PropertyValue -InputObject $capture -Name 'cli'
    $exitCode = Get-PropertyValue -InputObject $cli -Name 'exitCode' -Default (Get-PropertyValue -InputObject $capture -Name 'exitCode')
    if ($null -ne $exitCode -and -not [string]::IsNullOrWhiteSpace([string]$exitCode)) {
      $lvcompareExitCodes.Add([int]$exitCode) | Out-Null
    }

    $diff = Get-PropertyValue -InputObject $cli -Name 'diff'
    if ($diff -is [bool]) {
      $diffState = if ($diff) { 'diff' } else { 'match' }
      $lvcompareDiffStates.Add($diffState) | Out-Null
    }
  }

  foreach ($path in $NiContainerPaths) {
    $capture = Read-JsonFile -Path $path
    $generatedAt = [string](Get-PropertyValue -InputObject $capture -Name 'generatedAt')
    if (Test-NonEmptyString -Value $generatedAt) {
      $captureTimestamps.Add($generatedAt) | Out-Null
    }

    $status = [string](Get-PropertyValue -InputObject $capture -Name 'status')
    if (Test-NonEmptyString -Value $status) {
      $niStatuses.Add($status) | Out-Null
    }

    $image = [string](Get-PropertyValue -InputObject $capture -Name 'image')
    if (Test-NonEmptyString -Value $image) {
      $niImages.Add($image) | Out-Null
    }
  }

  return [ordered]@{
    presence = Resolve-CapturePresence -LvcompareCount $LvcomparePaths.Count -NiContainerCount $NiContainerPaths.Count
    lvcompareCount = $LvcomparePaths.Count
    niContainerCount = $NiContainerPaths.Count
    lvcompareExitCodes = @(Get-SortedUniqueIntArray -Value $lvcompareExitCodes.ToArray())
    lvcompareDiffStates = @(Get-SortedUniqueStringArray -Value $lvcompareDiffStates.ToArray())
    niStatuses = @(Get-SortedUniqueStringArray -Value $niStatuses.ToArray())
    niImages = @(Get-SortedUniqueStringArray -Value $niImages.ToArray())
    latestCaptureAt = Get-LatestTimestamp -Value $captureTimestamps.ToArray()
    lvcomparePaths = @(Get-SortedUniquePathArray -RepoRoot $RepoRoot -Value $LvcomparePaths)
    niContainerPaths = @(Get-SortedUniquePathArray -RepoRoot $RepoRoot -Value $NiContainerPaths)
  }
}

$repoRoot = Resolve-RepoRoot
$catalogPathResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CatalogPath
$outputPathResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $OutputPath
if (-not (Test-Path -LiteralPath $catalogPathResolved -PathType Leaf)) {
  throw "Offline corpus catalog not found at '$catalogPathResolved'."
}

$catalogSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'offline-real-history-corpus-targets-v1.schema.json'
$normalizedSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'offline-real-history-corpus-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $catalogSchemaPath -DataPath $catalogPathResolved
}

$catalog = Read-JsonFile -Path $catalogPathResolved
$targets = @($catalog.targets | Sort-Object { [string]$_.id })
if ($targets.Count -eq 0) {
  throw "Offline corpus catalog '$catalogPathResolved' contains no targets."
}

$allKnownTimestamps = New-Object System.Collections.Generic.List[string]
$catalogGeneratedAt = [string](Get-PropertyValue -InputObject $catalog -Name 'generatedAt')
if (Test-NonEmptyString -Value $catalogGeneratedAt) {
  $allKnownTimestamps.Add($catalogGeneratedAt) | Out-Null
}

$normalizedTargets = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
  $seedFixture = Get-PropertyValue -InputObject $target -Name 'seedFixture'
  $suiteManifestRelativePath = [string](Get-PropertyValue -InputObject $seedFixture -Name 'historySuitePath')
  if (-not (Test-NonEmptyString -Value $suiteManifestRelativePath)) {
    throw "Target '$([string]$target.id)' is missing seedFixture.historySuitePath."
  }

  $suiteManifestPath = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $suiteManifestRelativePath
  if (-not (Test-Path -LiteralPath $suiteManifestPath -PathType Leaf)) {
    throw "Seed fixture suite manifest not found at '$suiteManifestPath' for target '$([string]$target.id)'."
  }

  $suiteManifest = Read-JsonFile -Path $suiteManifestPath
  $suiteGeneratedAt = [string](Get-PropertyValue -InputObject $suiteManifest -Name 'generatedAt')
  if (Test-NonEmptyString -Value $suiteGeneratedAt) {
    $allKnownTimestamps.Add($suiteGeneratedAt) | Out-Null
  }

  $suiteDirectory = Split-Path -Parent $suiteManifestPath
  $historyReportMarkdownPath = Join-Path $suiteDirectory 'history-report.md'
  $historyReportHtmlPath = Join-Path $suiteDirectory 'history-report.html'

  $normalizedModes = New-Object System.Collections.Generic.List[object]
  $allTargetLvcomparePaths = New-Object System.Collections.Generic.List[string]
  $allTargetNiContainerPaths = New-Object System.Collections.Generic.List[string]

  foreach ($modeEntry in @($suiteManifest.modes | Sort-Object { [string]($_.slug ?? $_.name) })) {
    $modeManifestPath = Resolve-AbsolutePath -BasePath $repoRoot -PathValue ([string]$modeEntry.manifestPath)
    if (-not (Test-Path -LiteralPath $modeManifestPath -PathType Leaf)) {
      throw "Mode manifest not found at '$modeManifestPath' for target '$([string]$target.id)'."
    }

    $modeManifest = Read-JsonFile -Path $modeManifestPath
    $modeGeneratedAt = [string](Get-PropertyValue -InputObject $modeManifest -Name 'generatedAt')
    if (Test-NonEmptyString -Value $modeGeneratedAt) {
      $allKnownTimestamps.Add($modeGeneratedAt) | Out-Null
    }

    $comparisons = New-Object System.Collections.Generic.List[object]
    $comparisonClasses = New-Object System.Collections.Generic.List[string]
    foreach ($comparison in @($modeManifest.comparisons | Sort-Object { [int]$_.index })) {
      $outcomeClass = Resolve-ComparisonOutcomeClass -Comparison $comparison
      $comparisonClasses.Add($outcomeClass) | Out-Null

      $comparisons.Add([ordered]@{
          index = [int](Get-PropertyValue -InputObject $comparison -Name 'index' -Default 0)
          baseRef = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $comparison -Name 'base') -Name 'ref')
          headRef = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $comparison -Name 'head') -Name 'ref')
          status = Get-ComparisonStatusValue -Comparison $comparison
          diff = Get-ComparisonDiffValue -Comparison $comparison
          bucket = Get-BucketForComparison -Comparison $comparison
          categories = @(Get-CategoriesForComparison -Comparison $comparison)
          message = Get-ComparisonMessageValue -Comparison $comparison
          annotations = [ordered]@{
            outcomeClass = $outcomeClass
          }
        }) | Out-Null
    }

    $modeStats = Get-StatsSummary -Stats $modeManifest.stats
    if ([int](Get-PropertyValue -InputObject $modeManifest.stats -Name 'noiseCollapsed' -Default 0) -gt 0) {
      $comparisonClasses.Add('noise-diff') | Out-Null
    }
    $comparisonClassSet = Get-SortedUniqueStringArray -Value $comparisonClasses.ToArray()

    $capturePaths = Get-CapturePathsForMode `
      -RepoRoot $repoRoot `
      -SuiteDirectory $suiteDirectory `
      -SeedFixture $seedFixture `
      -ModeEntry $modeEntry `
      -ModeManifest $modeManifest
    foreach ($path in @($capturePaths.lvcompare)) {
      $allTargetLvcomparePaths.Add($path) | Out-Null
    }
    foreach ($path in @($capturePaths.niContainer)) {
      $allTargetNiContainerPaths.Add($path) | Out-Null
    }

    $captureSummary = Get-CaptureSummary `
      -RepoRoot $repoRoot `
      -LvcomparePaths @($capturePaths.lvcompare) `
      -NiContainerPaths @($capturePaths.niContainer)
    if (Test-NonEmptyString -Value $captureSummary.latestCaptureAt) {
      $allKnownTimestamps.Add([string]$captureSummary.latestCaptureAt) | Out-Null
    }

    $modeOutcomeClass = Resolve-ModeOutcomeClass -Stats $modeManifest.stats -ComparisonClasses $comparisonClassSet
    $normalizedModes.Add([ordered]@{
        mode = [string](Get-PropertyValue -InputObject $modeEntry -Name 'slug' -Default (Get-PropertyValue -InputObject $modeManifest -Name 'mode'))
        status = [string](Get-PropertyValue -InputObject $modeManifest -Name 'status' -Default (Get-PropertyValue -InputObject $modeEntry -Name 'status'))
        flags = @(Get-StringArray -Value (Get-PropertyValue -InputObject $modeManifest -Name 'flags' -Default (Get-PropertyValue -InputObject $modeEntry -Name 'flags')))
        stats = $modeStats
        annotations = [ordered]@{
          outcomeClass = $modeOutcomeClass
          comparisonClasses = @($comparisonClassSet)
          bucketProfile = @(Get-BucketProfile -Stats $modeManifest.stats)
          capturePresence = [string]$captureSummary.presence
        }
        captureSummary = $captureSummary
        comparisons = @($comparisons.ToArray())
      }) | Out-Null
  }

  $targetCaptureSummary = Get-CaptureSummary `
    -RepoRoot $repoRoot `
    -LvcomparePaths @($allTargetLvcomparePaths.ToArray() | Sort-Object -Unique) `
    -NiContainerPaths @($allTargetNiContainerPaths.ToArray() | Sort-Object -Unique)
  if (Test-NonEmptyString -Value $targetCaptureSummary.latestCaptureAt) {
    $allKnownTimestamps.Add([string]$targetCaptureSummary.latestCaptureAt) | Out-Null
  }

  $requestedModes = Get-StringArray -Value $target.requestedModes
  $executedModes = Get-StringArray -Value $suiteManifest.executedModes
  $modeList = @($normalizedModes.ToArray())
  $targetOutcomeLabels = New-Object System.Collections.Generic.List[string]
  $targetBucketProfile = New-Object System.Collections.Generic.List[string]
  foreach ($mode in $modeList) {
    foreach ($value in @(Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $mode -Name 'annotations') -Name 'comparisonClasses')) {
      if (Test-NonEmptyString -Value $value) {
        $targetOutcomeLabels.Add([string]$value) | Out-Null
      }
    }

    $modeOutcome = [string](Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $mode -Name 'annotations') -Name 'outcomeClass')
    if (Test-NonEmptyString -Value $modeOutcome) {
      $targetOutcomeLabels.Add($modeOutcome) | Out-Null
    }

    foreach ($bucket in @(Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $mode -Name 'annotations') -Name 'bucketProfile')) {
      if (Test-NonEmptyString -Value $bucket) {
        $targetBucketProfile.Add([string]$bucket) | Out-Null
      }
    }
  }

  $suiteStats = Get-StatsSummary -Stats $suiteManifest.stats
  $normalizedTargets.Add([ordered]@{
      id = [string]$target.id
      label = [string]$target.label
      repoSlug = [string](Get-PropertyValue -InputObject $target.repo -Name 'slug')
      targetPath = [string]$target.targetPath
      requestedModes = @($requestedModes)
      executedModes = @($executedModes)
      status = [string](Get-PropertyValue -InputObject $suiteManifest -Name 'status')
      stats = $suiteStats
      annotations = [ordered]@{
        outcomeLabels = @(Get-SortedUniqueStringArray -Value $targetOutcomeLabels.ToArray())
        modeSensitivity = Resolve-ModeSensitivity -Modes $modeList
        coverageClass = Resolve-CoverageClass -RequestedModes $requestedModes -ExecutedModes $executedModes
        bucketProfile = @(Get-SortedUniqueStringArray -Value $targetBucketProfile.ToArray())
        capturePresence = [string]$targetCaptureSummary.presence
      }
      provenance = [ordered]@{
        suiteGeneratedAt = [string](Get-PropertyValue -InputObject $suiteManifest -Name 'generatedAt')
        suiteManifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $suiteManifestPath
        modeManifestPaths = @(Get-SortedUniquePathArray -RepoRoot $repoRoot -Value @($suiteManifest.modes | ForEach-Object { [string]$_.manifestPath }))
        historyReportMarkdownPath = if (Test-Path -LiteralPath $historyReportMarkdownPath -PathType Leaf) {
          Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $historyReportMarkdownPath
        } else {
          $null
        }
        historyReportHtmlPath = if (Test-Path -LiteralPath $historyReportHtmlPath -PathType Leaf) {
          Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $historyReportHtmlPath
        } else {
          $null
        }
        latestCaptureAt = [string]$targetCaptureSummary.latestCaptureAt
        lvcompareCapturePaths = @($targetCaptureSummary.lvcomparePaths)
        niContainerCapturePaths = @($targetCaptureSummary.niContainerPaths)
      }
      captureSummary = [ordered]@{
        presence = [string]$targetCaptureSummary.presence
        lvcompareCount = [int]$targetCaptureSummary.lvcompareCount
        niContainerCount = [int]$targetCaptureSummary.niContainerCount
        lvcompareExitCodes = @($targetCaptureSummary.lvcompareExitCodes)
        lvcompareDiffStates = @($targetCaptureSummary.lvcompareDiffStates)
        niStatuses = @($targetCaptureSummary.niStatuses)
        niImages = @($targetCaptureSummary.niImages)
      }
      modes = $modeList
    }) | Out-Null
}

$normalizedCorpus = [ordered]@{
  '$schema' = '../../docs/schemas/offline-real-history-corpus-v1.schema.json'
  schema = 'vi-history/offline-real-history-corpus@v1'
  generatedAt = (Get-LatestTimestamp -Value $allKnownTimestamps.ToArray())
  storageBoundary = [ordered]@{
    catalogPath = [string](Get-PropertyValue -InputObject $catalog.storagePolicy -Name 'checkedInCatalogPath')
    normalizedPath = [string](Get-PropertyValue -InputObject $catalog.storagePolicy -Name 'checkedInNormalizedPath')
    generatedRoot = [string](Get-PropertyValue -InputObject $catalog.storagePolicy -Name 'generatedRoot')
    rawArtifactsInGit = $false
  }
  targets = @($normalizedTargets.ToArray())
}

Ensure-Directory -Path (Split-Path -Parent $outputPathResolved)
$normalizedCorpus | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $outputPathResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $normalizedSchemaPath -DataPath $outputPathResolved
}

return [pscustomobject]$normalizedCorpus
