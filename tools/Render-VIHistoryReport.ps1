param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [string]$HistoryContextPath,
  [string[]]$RequestedModesOverride,
  [string]$OutputDir,
  [string]$MarkdownPath,
  [string]$HtmlPath,
  [string]$SummaryJsonPath,
  [switch]$EmitHtml,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  $categoryModule = Join-Path (Split-Path -Parent $PSCommandPath) 'VICategoryBuckets.psm1'
  if (Test-Path -LiteralPath $categoryModule -PathType Leaf) {
    Import-Module $categoryModule -Force
  }
} catch {}

function Resolve-ExistingPath {
  param(
    [string]$Path,
    [string]$Description,
    [switch]$Optional
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    if ($Optional.IsPresent) { return $null }
    throw ("{0} path not provided." -f $Description)
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($Optional.IsPresent) { return $null }
    throw ("{0} file not found: {1}" -f $Description, $Path)
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Ensure-Directory {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-FullPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  try {
    return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  } catch {
    if ([System.IO.Path]::IsPathRooted($Path)) {
      return [System.IO.Path]::GetFullPath($Path)
    }
    $cwd = Get-Location
    return [System.IO.Path]::GetFullPath((Join-Path $cwd.Path $Path))
  }
}

$script:HistoryCommitMetadataCache = @{}
function Get-CommitMetadata {
  param([string]$Commit)

  if ([string]::IsNullOrWhiteSpace($Commit)) { return $null }
  if ($script:HistoryCommitMetadataCache.ContainsKey($Commit)) {
    return $script:HistoryCommitMetadataCache[$Commit]
  }

  $meta = $null
  try {
    $formatArg = "--format=%H%x00%an%x00%ae%x00%ad%x00%s"
    $output = & git log -1 --no-patch --date=iso-strict $formatArg $Commit 2>$null
    if ($LASTEXITCODE -eq 0 -and $output) {
      $parts = $output -split [char]0
      if ($parts.Count -ge 5) {
        $meta = [pscustomobject]@{
          sha         = $parts[0]
          authorName  = $parts[1]
          authorEmail = $parts[2]
          authorDate  = $parts[3]
          subject     = $parts[4]
        }
      }
    }
  } catch {
    $meta = $null
  }

  $script:HistoryCommitMetadataCache[$Commit] = $meta
  return $meta
}

function Get-ShortSha {
  param(
    [string]$Value,
    [int]$Length = 12
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
  if ($Value.Length -le $Length) { return $Value }
  return $Value.Substring(0, $Length)
}

function Get-LineageLabel {
  param(
    [object]$Lineage,
    [string]$HeadRef,
    [string]$BaseRef
  )

  if (-not $Lineage) {
    return 'Mainline'
  }

  $type = if ($Lineage.PSObject.Properties['type']) { [string]$Lineage.type } else { 'mainline' }
  $parentIndex = if ($Lineage.PSObject.Properties['parentIndex']) { [int]$Lineage.parentIndex } else { $null }
  $parentCount = if ($Lineage.PSObject.Properties['parentCount']) { [int]$Lineage.parentCount } else { $null }
  $depth = if ($Lineage.PSObject.Properties['depth']) { [int]$Lineage.depth } else { $null }
  $mergeCommit = if ($Lineage.PSObject.Properties['mergeCommit']) { [string]$Lineage.mergeCommit } else { $null }
  $branchHead = if ($Lineage.PSObject.Properties['branchHead']) { [string]$Lineage.branchHead } else { $null }
  $rootMerge = if ($Lineage.PSObject.Properties['rootMerge']) { [string]$Lineage.rootMerge } else { $mergeCommit }

  switch ($type.ToLowerInvariant()) {
    'touch-history' {
      return 'Touch history'
    }
    'merge-parent' {
      $label = if ($parentIndex -and $parentIndex -gt 0) { "Merge parent #$parentIndex" } else { 'Merge parent' }
      if ($depth -and $depth -gt 0) {
        $label = '{0} depth {1}' -f $label, $depth
      }
      if ($branchHead) {
        $label = '{0} @ {1}' -f $label, (Get-ShortSha -Value $branchHead -Length 8)
      }
      if ($rootMerge) {
        $label = '{0} (merge {1})' -f $label, (Get-ShortSha -Value $rootMerge -Length 8)
      }
      return $label
    }
    'merge-branch' {
      $label = if ($parentIndex -and $parentIndex -gt 0) { "Branch parent #$parentIndex" } else { 'Branch parent' }
      if ($depth -and $depth -gt 0) {
        $label = '{0} depth {1}' -f $label, $depth
      }
      if ($branchHead) {
        $label = '{0} @ {1}' -f $label, (Get-ShortSha -Value $branchHead -Length 8)
      }
      if ($rootMerge) {
        $label = '{0} (merge {1})' -f $label, (Get-ShortSha -Value $rootMerge -Length 8)
      }
      return $label
    }
    default {
      if ($parentCount -and $parentCount -gt 1) {
        return "Mainline (parent 1 of $parentCount)"
      }
      return 'Mainline'
    }
  }
}

function Write-GitHubOutput {
  param(
    [string]$Key,
    [string]$Value,
    [string]$DestPath
  )
  if ([string]::IsNullOrWhiteSpace($DestPath) -or [string]::IsNullOrWhiteSpace($Key)) {
    return
  }

  $resolved = $DestPath
  if (-not (Test-Path -LiteralPath $resolved)) {
    New-Item -ItemType File -Force -Path $resolved | Out-Null
  }
  $encodedValue = $Value -replace "`r?`n", "%0A"
  Add-Content -Path $resolved -Value ("{0}={1}" -f $Key, $encodedValue)
}

function Write-StepSummary {
  param(
    [string[]]$Lines,
    [string]$DestPath
  )
  if ([string]::IsNullOrWhiteSpace($DestPath) -or -not $Lines -or $Lines.Count -eq 0) {
    return
  }

  $resolved = $DestPath
  if (-not (Test-Path -LiteralPath $resolved)) {
    New-Item -ItemType File -Force -Path $resolved | Out-Null
  }
  Add-Content -Path $resolved -Value ($Lines -join [Environment]::NewLine)
}

$script:HtmlEncoder = [System.Net.WebUtility]
function ConvertTo-HtmlSafe {
  param([object]$Value)
  if ($null -eq $Value) { return '' }
  return $script:HtmlEncoder::HtmlEncode([string]$Value)
}

function Coalesce {
  param(
    [Parameter()]$Value,
    [Parameter()]$Fallback
  )
  if ($Value -ne $null) { return $Value }
  return $Fallback
}

function Get-ObjectPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name,
    $Default = $null
  )

  if ($null -eq $InputObject) { return $Default }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) {
      return $InputObject[$Name]
    }
    return $Default
  }

  $property = $InputObject.PSObject.Properties[$Name]
  if ($property) {
    return $property.Value
  }

  return $Default
}

function Get-IntPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name,
    [int]$Default = 0
  )

  if ($null -eq $InputObject) { return $Default }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) {
      try { return [int]$InputObject[$Name] } catch { return $Default }
    }
    return $Default
  }

  if ($InputObject.PSObject.Properties[$Name]) {
    try { return [int]$InputObject.$Name } catch { return $Default }
  }

  return $Default
}

function Get-NullableIntPropertyValue {
  param(
    [AllowNull()][object]$InputObject,
    [Parameter(Mandatory)][string]$Name
  )

  $value = Get-ObjectPropertyValue -InputObject $InputObject -Name $Name -Default $null
  if ($null -eq $value) { return $null }

  try {
    return [int]$value
  } catch {
    return $null
  }
}

function New-BranchBudgetFacade {
  param([AllowNull()][object]$BranchBudget)

  if ($null -eq $BranchBudget) {
    return $null
  }

  return [ordered]@{
    sourceBranchRef = [string](Coalesce (Get-ObjectPropertyValue -InputObject $BranchBudget -Name 'sourceBranchRef') '')
    baselineRef = Get-ObjectPropertyValue -InputObject $BranchBudget -Name 'baselineRef'
    maxCommitCount = Get-NullableIntPropertyValue -InputObject $BranchBudget -Name 'maxCommitCount'
    commitCount = Get-NullableIntPropertyValue -InputObject $BranchBudget -Name 'commitCount'
    status = [string](Coalesce (Get-ObjectPropertyValue -InputObject $BranchBudget -Name 'status') '')
    reason = [string](Coalesce (Get-ObjectPropertyValue -InputObject $BranchBudget -Name 'reason') '')
  }
}

function Get-StringArray {
  param([object]$Value)

  if ($null -eq $Value) { return @() }

  $items = @()
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @($Value)
  } else {
    $items = @($Value)
  }

  return @($items | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-SortedUniqueStringArray {
  param([object]$Value)

  $items = @(Get-StringArray -Value $Value)
  if ($items.Count -eq 0) { return @() }
  return @($items | Sort-Object -Unique)
}

function Get-ComparisonClassificationValue {
  param([AllowNull()][object]$Comparison)

  if (-not $Comparison) { return $null }

  $resultNode = if ($Comparison.PSObject.Properties['result']) { $Comparison.result } else { $null }
  foreach ($candidate in @(
    $(if ($resultNode -and $resultNode.PSObject.Properties['classification']) { [string]$resultNode.classification } else { $null }),
    $(if ($Comparison.PSObject.Properties['classification']) { [string]$Comparison.classification } else { $null })
  )) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim().ToLowerInvariant()
    }
  }

  $classificationEntries = New-Object System.Collections.Generic.List[object]
  if ($resultNode) {
    if ($resultNode.PSObject.Properties['categoryDetails'] -and $resultNode.categoryDetails) {
      foreach ($entry in @($resultNode.categoryDetails)) {
        $classificationEntries.Add($entry) | Out-Null
      }
    }
    if ($resultNode.PSObject.Properties['categoryBucketDetails'] -and $resultNode.categoryBucketDetails) {
      foreach ($entry in @($resultNode.categoryBucketDetails)) {
        $classificationEntries.Add($entry) | Out-Null
      }
    }
  }

  $hasSignal = $false
  $hasOther = $false
  foreach ($entry in @($classificationEntries.ToArray())) {
    if (-not $entry -or -not $entry.PSObject.Properties['classification']) { continue }
    $classification = [string]$entry.classification
    if ([string]::IsNullOrWhiteSpace($classification)) { continue }
    switch ($classification.Trim().ToLowerInvariant()) {
      'signal' {
        $hasSignal = $true
      }
      'noise' {
        $hasOther = $true
      }
      'neutral' {
        $hasOther = $true
      }
    }
  }

  if ($hasSignal) { return 'signal' }
  if ($hasOther) { return 'noise' }
  return $null
}

function Resolve-ComparisonOutcomeClass {
  param([AllowNull()][object]$Comparison)

  if (-not $Comparison) { return 'clean' }

  $resultNode = if ($Comparison.PSObject.Properties['result']) { $Comparison.result } else { $null }
  $statusValue = $null
  foreach ($candidate in @(
    $(if ($resultNode -and $resultNode.PSObject.Properties['status']) { [string]$resultNode.status } else { $null }),
    $(if ($Comparison.PSObject.Properties['status']) { [string]$Comparison.status } else { $null })
  )) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      $statusValue = $candidate.Trim()
      break
    }
  }

  if ($statusValue -eq 'error') {
    return 'error'
  }

  if (-not [string]::IsNullOrWhiteSpace($statusValue) -and $statusValue.StartsWith('missing-', [System.StringComparison]::OrdinalIgnoreCase)) {
    return 'missing'
  }

  $hasDiffValue = $false
  $diffValue = $false
  foreach ($candidate in @(
    $(if ($resultNode -and $resultNode.PSObject.Properties['diff']) { $resultNode.diff } else { $null }),
    $(if ($Comparison.PSObject.Properties['diff']) { $Comparison.diff } else { $null })
  )) {
    if ($candidate -ne $null) {
      $hasDiffValue = $true
      $diffValue = [bool]$candidate
      break
    }
  }

  $classification = Get-ComparisonClassificationValue -Comparison $Comparison
  if ($hasDiffValue) {
    if ($diffValue) {
      if ($classification -eq 'noise') {
        return 'noise-diff'
      }
      return 'signal-diff'
    }
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
    [AllowEmptyCollection()][string[]]$ComparisonClasses = @()
  )

  if ((Get-IntPropertyValue -InputObject $Stats -Name 'errors') -gt 0 -or $ComparisonClasses -contains 'error') {
    return 'error'
  }

  if ((Get-IntPropertyValue -InputObject $Stats -Name 'missing') -gt 0 -or $ComparisonClasses -contains 'missing') {
    return 'missing'
  }

  if ((Get-IntPropertyValue -InputObject $Stats -Name 'signalDiffs') -gt 0 -or $ComparisonClasses -contains 'signal-diff') {
    return 'signal-diff'
  }

  if ((Get-IntPropertyValue -InputObject $Stats -Name 'noiseCollapsed') -gt 0 -or $ComparisonClasses -contains 'noise-diff') {
    return 'noise-diff'
  }

  if ((Get-IntPropertyValue -InputObject $Stats -Name 'diffs') -gt 0) {
    return 'signal-diff'
  }

  return 'clean'
}

function Resolve-CoverageClass {
  param(
    [Parameter(Mandatory)][string[]]$RequestedModes,
    [Parameter(Mandatory)][string[]]$ExecutedModes
  )

  $requested = @(Get-SortedUniqueStringArray -Value $RequestedModes)
  $executed = @(Get-SortedUniqueStringArray -Value $ExecutedModes)

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
  param(
    [Parameter(Mandatory)][int]$ObservedModeCount,
    [AllowEmptyCollection()][string[]]$ModeOutcomeClasses = @()
  )

  if ($ObservedModeCount -le 0) {
    return 'none-observed'
  }

  if ($ObservedModeCount -eq 1) {
    return 'single-mode-observed'
  }

  $outcomes = @(Get-SortedUniqueStringArray -Value $ModeOutcomeClasses)
  if ($outcomes.Count -eq 0) {
    return 'mixed-observed-modes'
  }

  if (@($ModeOutcomeClasses | Where-Object { $_ -ne 'clean' }).Count -eq 0) {
    return 'all-observed-modes-clean'
  }

  if (@($ModeOutcomeClasses | Where-Object { $_ -notin @('signal-diff', 'noise-diff') }).Count -eq 0) {
    return 'all-observed-modes-diff'
  }

  return 'mixed-observed-modes'
}

function Get-CoverageClassDetail {
  param(
    [Parameter(Mandatory)][string[]]$RequestedModes,
    [Parameter(Mandatory)][string[]]$ExecutedModes
  )

  $requested = @(Get-SortedUniqueStringArray -Value $RequestedModes)
  $executed = @(Get-SortedUniqueStringArray -Value $ExecutedModes)
  $missing = @(Get-SortedUniqueStringArray -Value @($requested | Where-Object { $_ -notin $executed }))
  $extra = @(Get-SortedUniqueStringArray -Value @($executed | Where-Object { $_ -notin $requested }))

  if ($missing.Count -eq 0 -and $extra.Count -eq 0) {
    return 'Requested and executed modes match.'
  }

  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add(('requested: {0}; executed: {1}' -f $requested.Count, $executed.Count)) | Out-Null
  if ($missing.Count -gt 0) {
    $parts.Add(('missing: {0}' -f ([string]::Join(', ', $missing)))) | Out-Null
  }
  if ($extra.Count -gt 0) {
    $parts.Add(('extra: {0}' -f ([string]::Join(', ', $extra)))) | Out-Null
  }
  return [string]::Join('; ', $parts)
}

function Format-MarkdownCodeList {
  param([AllowEmptyCollection()][string[]]$Values = @())

  $items = @(Get-SortedUniqueStringArray -Value $Values)
  if ($items.Count -eq 0) {
    return 'n/a'
  }

  return (($items | ForEach-Object { ('`{0}`' -f $_) }) -join ', ')
}

function Format-HtmlCodeList {
  param([AllowEmptyCollection()][string[]]$Values = @())

  $items = @(Get-SortedUniqueStringArray -Value $Values)
  if ($items.Count -eq 0) {
    return '<span class="muted">n/a</span>'
  }

  return (($items | ForEach-Object { ('<code>{0}</code>' -f (ConvertTo-HtmlSafe $_)) }) -join ', ')
}

function Get-CategoryMetadata {
  param([string]$Name)

  return Get-VICategoryMetadata -Name $Name
}

function Get-CategoryLabelEntries {
  param([object]$Categories)

  $entries = New-Object System.Collections.Generic.List[pscustomobject]
  if ($null -eq $Categories) { return @() }

  $items = @()
  if ($Categories -is [System.Collections.IEnumerable] -and -not ($Categories -is [string])) {
    $items = @($Categories)
  } else {
    $items = @($Categories)
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    $text = [string]$item
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    $meta = Get-CategoryMetadata -Name $text
    if ($meta -and $seen.Add($meta.slug)) {
      $entries.Add($meta) | Out-Null
    }
  }

  return @($entries | Sort-Object -Property label, slug)
}

function Get-CategoryCountEntries {
  param([object]$CategoryCounts)

  $map = @{}
  if ($null -eq $CategoryCounts) { return @() }

  if ($CategoryCounts -is [System.Collections.IDictionary]) {
    foreach ($key in $CategoryCounts.Keys) {
      $value = $CategoryCounts[$key]
      $meta = Get-CategoryMetadata -Name $key
      if (-not $meta) { continue }
      if (-not $map.ContainsKey($meta.slug)) {
        $map[$meta.slug] = [pscustomobject]@{
          slug           = $meta.slug
          label          = $meta.label
          classification = $meta.classification
          count          = 0
        }
      }
      try {
        $map[$meta.slug].count += [int]$value
      } catch {
        $map[$meta.slug].count += 0
      }
    }
  } elseif ($CategoryCounts -and $CategoryCounts.PSObject) {
    foreach ($prop in $CategoryCounts.PSObject.Properties) {
      if (-not $prop) { continue }
      $meta = Get-CategoryMetadata -Name $prop.Name
      if (-not $meta) { continue }
      if (-not $map.ContainsKey($meta.slug)) {
        $map[$meta.slug] = [pscustomobject]@{
          slug           = $meta.slug
          label          = $meta.label
          classification = $meta.classification
          count          = 0
        }
      }
      $value = $prop.Value
      try {
        $map[$meta.slug].count += [int]$value
      } catch {
        $map[$meta.slug].count += 0
      }
    }
  }

  return @($map.Values | Sort-Object -Property label, slug)
}

function Get-BucketLabelEntries {
  param([object]$Buckets)

  $entries = New-Object System.Collections.Generic.List[pscustomobject]
  if ($null -eq $Buckets) { return @() }

  $items = @()
  if ($Buckets -is [System.Collections.IEnumerable] -and -not ($Buckets -is [string])) {
    $items = @($Buckets)
  } else {
    $items = @($Buckets)
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in $items) {
    if ($null -eq $item) { continue }
    $slug = $null
    if ($item -is [pscustomobject]) {
      if ($item.PSObject.Properties['bucketSlug']) {
        $slug = [string]$item.bucketSlug
      } elseif ($item.PSObject.Properties['slug']) {
        $slug = [string]$item.slug
      }
    } else {
      $slug = [string]$item
    }
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    if ($seen.Add($slug)) {
      $meta = Get-VIBucketMetadata -BucketSlug $slug
      if ($meta) {
        $entries.Add([pscustomobject]@{
          slug           = $meta.slug
          label          = $meta.label
          classification = $meta.classification
        }) | Out-Null
      }
    }
  }

  return @($entries | Sort-Object -Property label, slug)
}

function Get-BucketCountEntries {
  param([object]$BucketCounts)

  $map = @{}
  if ($null -eq $BucketCounts) { return @() }

  if ($BucketCounts -is [System.Collections.IDictionary]) {
    foreach ($key in $BucketCounts.Keys) {
      $value = $BucketCounts[$key]
      $meta = Get-VIBucketMetadata -BucketSlug $key
      if (-not $meta) { continue }
      if (-not $map.ContainsKey($meta.slug)) {
        $map[$meta.slug] = [pscustomobject]@{
          slug           = $meta.slug
          label          = $meta.label
          classification = $meta.classification
          count          = 0
        }
      }
      try {
        $map[$meta.slug].count += [int]$value
      } catch {
        $map[$meta.slug].count = ($map[$meta.slug].count + [int]$value)
      }
    }
  } elseif ($BucketCounts -and $BucketCounts.PSObject) {
    foreach ($prop in $BucketCounts.PSObject.Properties) {
      if (-not $prop) { continue }
      $meta = Get-VIBucketMetadata -BucketSlug $prop.Name
      if (-not $meta) { continue }
      if (-not $map.ContainsKey($meta.slug)) {
        $map[$meta.slug] = [pscustomobject]@{
          slug           = $meta.slug
          label          = $meta.label
          classification = $meta.classification
          count          = 0
        }
      }
      $value = $prop.Value
      try {
        $map[$meta.slug].count += [int]$value
      } catch {
        $map[$meta.slug].count += 0
      }
    }
  }

  return @($map.Values | Sort-Object -Property label, slug)
}

function Get-CountMapKeys {
  param([object]$CountMap)

  if ($null -eq $CountMap) { return @() }

  $keys = New-Object System.Collections.Generic.List[string]
  if ($CountMap -is [System.Collections.IDictionary]) {
    foreach ($key in $CountMap.Keys) {
      if ([string]::IsNullOrWhiteSpace([string]$key)) { continue }
      $keys.Add([string]$key) | Out-Null
    }
  } elseif ($CountMap -and $CountMap.PSObject) {
    foreach ($prop in $CountMap.PSObject.Properties) {
      if (-not $prop) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$prop.Name)) { continue }
      $keys.Add([string]$prop.Name) | Out-Null
    }
  }

  return @($keys | Sort-Object -Unique)
}

$manifestResolved = Resolve-ExistingPath -Path $ManifestPath -Description 'Manifest'
if (-not $HistoryContextPath) {
  $HistoryContextPath = Join-Path (Split-Path -Parent $manifestResolved) 'history-context.json'
}
$contextResolved = Resolve-ExistingPath -Path $HistoryContextPath -Description 'History context' -Optional

if (-not $OutputDir) {
  $OutputDir = Split-Path -Parent $manifestResolved
}
$OutputDir = Resolve-FullPath $OutputDir
$outputResolved = Ensure-Directory -Path $OutputDir

$MarkdownPath = if ($MarkdownPath) { Resolve-FullPath $MarkdownPath } else { Join-Path $outputResolved 'history-report.md' }
$markdownDir = Split-Path -Parent $MarkdownPath
if ($markdownDir) { [void](Ensure-Directory -Path $markdownDir) }

$emitHtml = $EmitHtml.IsPresent -or -not [string]::IsNullOrWhiteSpace($HtmlPath)
if ($emitHtml -and -not $HtmlPath) {
  $HtmlPath = Join-Path $outputResolved 'history-report.html'
}
$HtmlPath = if ($HtmlPath) { Resolve-FullPath $HtmlPath } else { $null }
if ($emitHtml -and $HtmlPath) {
  $htmlDir = Split-Path -Parent $HtmlPath
  if ($htmlDir) { [void](Ensure-Directory -Path $htmlDir) }
}
$SummaryJsonPath = if ($SummaryJsonPath) { Resolve-FullPath $SummaryJsonPath } else { Join-Path $outputResolved 'history-summary.json' }
$summaryJsonDir = Split-Path -Parent $SummaryJsonPath
if ($summaryJsonDir) {
  [void](Ensure-Directory -Path $summaryJsonDir)
}

try {
  $manifest = Get-Content -LiteralPath $manifestResolved -Raw | ConvertFrom-Json -Depth 8
} catch {
  throw ("Failed to parse manifest JSON at {0}: {1}" -f $manifestResolved, $_.Exception.Message)
}

function Build-FallbackHistoryContext {
  param(
    [Parameter(Mandatory = $true)]$Manifest
  )

  $comparisons = New-Object System.Collections.Generic.List[object]
  foreach ($mode in @($Manifest.modes)) {
    $modeLabel = $mode.name
    if ([string]::IsNullOrWhiteSpace($modeLabel)) {
      $modeLabel = $mode.slug
    }
    if ([string]::IsNullOrWhiteSpace($modeLabel)) {
      $modeLabel = 'unknown'
    }
    $modeManifestPath = $mode.manifestPath
    if (-not $modeManifestPath) { continue }
    if (-not (Test-Path -LiteralPath $modeManifestPath -PathType Leaf)) { continue }

    try {
      $modeManifest = Get-Content -LiteralPath $modeManifestPath -Raw | ConvertFrom-Json -Depth 6
    } catch {
      Write-Warning ("Unable to read mode manifest '{0}' while building history context fallback: {1}" -f $modeManifestPath, $_.Exception.Message)
      continue
    }

    $modeComparisons = New-Object System.Collections.Generic.List[object]
    foreach ($comparisonEntry in @($modeManifest.comparisons)) {
      if ($comparisonEntry) {
        $modeComparisons.Add($comparisonEntry) | Out-Null
      }
    }
    foreach ($comparisonEntry in @($modeManifest.collapsedComparisons)) {
      if ($comparisonEntry) {
        $modeComparisons.Add($comparisonEntry) | Out-Null
      }
    }

    foreach ($comparison in @($modeComparisons | Sort-Object { [int](Coalesce $_.index 0) })) {
      if (-not $comparison) { continue }
      $baseNode = $comparison.base
      $headNode = $comparison.head
      $resultNode = $comparison.result
      $modeName = $modeLabel
      $baseMeta = $null
      $headMeta = $null
      if ($baseNode -and $baseNode.ref) {
        $baseMeta = Get-CommitMetadata -Commit $baseNode.ref
      }
      if ($headNode -and $headNode.ref) {
        $headMeta = Get-CommitMetadata -Commit $headNode.ref
      }

      $resultPayload = [ordered]@{}
      if ($resultNode) {
        if ($resultNode.PSObject.Properties['diff']) {
          $resultPayload.diff = [bool]$resultNode.diff
        }
        if ($resultNode.PSObject.Properties['exitCode']) {
          $resultPayload.exitCode = $resultNode.exitCode
        }
        if ($resultNode.PSObject.Properties['duration_s']) {
          $resultPayload.duration_s = $resultNode.duration_s
        }
        if ($resultNode.PSObject.Properties['summaryPath'] -and $resultNode.summaryPath) {
          $resultPayload.summaryPath = $resultNode.summaryPath
        }
        if ($resultNode.PSObject.Properties['reportPath'] -and $resultNode.reportPath) {
          $resultPayload.reportPath = $resultNode.reportPath
        }
        if ($resultNode.PSObject.Properties['status']) {
          $resultPayload.status = $resultNode.status
        }
        if ($resultNode.PSObject.Properties['message']) {
          $resultPayload.message = $resultNode.message
        }
        if ($resultNode.PSObject.Properties['classification'] -and $resultNode.classification) {
          $resultPayload.classification = $resultNode.classification
        }
        if ($resultNode.PSObject.Properties['collapsed']) {
          $resultPayload.collapsed = [bool]$resultNode.collapsed
        }
        if ($resultNode.PSObject.Properties['artifactDir'] -and $resultNode.artifactDir) {
          $resultPayload.artifactDir = $resultNode.artifactDir
        }
        if ($resultNode.PSObject.Properties['execPath'] -and $resultNode.execPath) {
          $resultPayload.execPath = $resultNode.execPath
        }
        if ($resultNode.PSObject.Properties['command'] -and $resultNode.command) {
          $resultPayload.command = $resultNode.command
        }
        if ($resultNode.PSObject.Properties['categories'] -and $resultNode.categories) {
          $resultPayload.categories = @($resultNode.categories)
        }
        if ($resultNode.PSObject.Properties['categoryDetails'] -and $resultNode.categoryDetails) {
          $resultPayload.categoryDetails = @($resultNode.categoryDetails)
        }
        if ($resultNode.PSObject.Properties['categoryBuckets'] -and $resultNode.categoryBuckets) {
          $resultPayload.categoryBuckets = @($resultNode.categoryBuckets)
        }
        if ($resultNode.PSObject.Properties['categoryBucketDetails'] -and $resultNode.categoryBucketDetails) {
          $resultPayload.categoryBucketDetails = @($resultNode.categoryBucketDetails)
        }
        $highlightSet = @()
        if ($resultNode.PSObject.Properties['highlights'] -and $resultNode.highlights) {
          $highlightSet += @($resultNode.highlights | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($highlightSet.Count -eq 0 -and $resultNode.PSObject.Properties['summaryPath'] -and $resultNode.summaryPath -and (Test-Path -LiteralPath $resultNode.summaryPath)) {
          try {
            $summaryProbe = Get-Content -LiteralPath $resultNode.summaryPath -Raw | ConvertFrom-Json -Depth 8
            if ($summaryProbe -and $summaryProbe.cli) {
              if ($summaryProbe.cli.PSObject.Properties['highlights'] -and $summaryProbe.cli.highlights) {
                $highlightSet += @($summaryProbe.cli.highlights | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
              }
              if ($summaryProbe.cli.PSObject.Properties['includedAttributes'] -and $summaryProbe.cli.includedAttributes) {
                $includedList = @()
                foreach ($attrItem in @($summaryProbe.cli.includedAttributes)) {
                  if (-not $attrItem) { continue }
                  $attrName = $attrItem.name
                  if ([string]::IsNullOrWhiteSpace($attrName)) { continue }
                  if (-not $attrItem.PSObject.Properties['included'] -or [bool]$attrItem.included) {
                    $includedList += [string]$attrName
                  }
                }
                if ($includedList.Count -gt 0) {
                  $highlightSet += ("Attributes: {0}" -f ([string]::Join(', ', ($includedList | Select-Object -Unique))))
                }
              }
            }
          } catch {
          }
        }
        if ($highlightSet.Count -gt 0) {
          $resultPayload.highlights = @($highlightSet | Select-Object -Unique)
        }
      }

      $lineageNode = $null
      if ($comparison.PSObject.Properties['lineage']) {
        $lineageNode = $comparison.lineage
      }

      $baseShortRef = if ($baseNode -and $baseNode.PSObject.Properties['short'] -and $baseNode.short) {
        [string]$baseNode.short
      } elseif ($baseNode -and $baseNode.PSObject.Properties['ref'] -and $baseNode.ref) {
        Get-ShortSha -Value ([string]$baseNode.ref) -Length 7
      } else {
        $null
      }
      $headShortRef = if ($headNode -and $headNode.PSObject.Properties['short'] -and $headNode.short) {
        [string]$headNode.short
      } elseif ($headNode -and $headNode.PSObject.Properties['ref'] -and $headNode.ref) {
        Get-ShortSha -Value ([string]$headNode.ref) -Length 7
      } else {
        $null
      }

      $comparisons.Add([pscustomobject]@{
        mode  = [string](Coalesce $modeName 'unknown')
        index = $comparison.index
        report = if ($comparison.PSObject.Properties['outName']) { $comparison.outName } else { $null }
        base  = [pscustomobject]@{
          full    = $baseNode.ref
          short   = $baseShortRef
          author  = if ($baseMeta) { $baseMeta.authorName } else { $null }
          authorEmail = if ($baseMeta) { $baseMeta.authorEmail } else { $null }
          date    = if ($baseMeta) { $baseMeta.authorDate } else { $null }
          subject = if ($baseMeta) { $baseMeta.subject } else { $null }
        }
        head  = [pscustomobject]@{
          full    = $headNode.ref
          short   = $headShortRef
          author  = if ($headMeta) { $headMeta.authorName } else { $null }
          authorEmail = if ($headMeta) { $headMeta.authorEmail } else { $null }
          date    = if ($headMeta) { $headMeta.authorDate } else { $null }
          subject = if ($headMeta) { $headMeta.subject } else { $null }
        }
        result = [pscustomobject]$resultPayload
        highlights = if ($resultPayload.Contains('highlights') -and $resultPayload.highlights) { @($resultPayload.highlights) } else { @() }
        lineage = if ($lineageNode) { [pscustomobject]$lineageNode } else { $null }
        lineageLabel = Get-LineageLabel -Lineage $lineageNode -HeadRef $headNode.ref -BaseRef $baseNode.ref
      })
    }
  }

  return [pscustomobject]@{
    schema            = 'vi-compare/history-context@v1'
    generatedAt       = (Get-Date).ToString('o')
    targetPath        = $Manifest.targetPath
    requestedStartRef = $Manifest.requestedStartRef
    startRef          = $Manifest.startRef
    maxPairs          = $Manifest.maxPairs
    requestedModes    = if ($Manifest.PSObject.Properties['requestedModes']) { @($Manifest.requestedModes) } else { @($Manifest.modes | ForEach-Object { $_.name }) }
    executedModes     = if ($Manifest.PSObject.Properties['executedModes']) { @($Manifest.executedModes) } else { @($Manifest.modes | ForEach-Object { $_.name }) }
    comparisons       = $comparisons.ToArray()
  }
}

$historyContext = $null
if ($contextResolved) {
  try {
    $historyContext = Get-Content -LiteralPath $contextResolved -Raw | ConvertFrom-Json -Depth 6
  } catch {
    Write-Warning ("Failed to parse history context JSON at {0}: {1}" -f $contextResolved, $_.Exception.Message)
  }
}
if (-not $historyContext) {
  Write-Verbose 'History context payload missing; deriving comparisons from mode manifests.'
  $historyContext = Build-FallbackHistoryContext -Manifest $manifest
}
$targetPath = $manifest.targetPath
$startRef = $manifest.startRef
$requestedStart = $manifest.requestedStartRef
$stats = $manifest.stats
$modeEntries = @($manifest.modes)
$requestedModes = @(Get-StringArray -Value $(if ($manifest.PSObject.Properties['requestedModes']) { $manifest.requestedModes } else { $null }))
if ($requestedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $requestedModes = @($modeEntries | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$requestedModesOverrideValues = @(Get-StringArray -Value $RequestedModesOverride)
if ($requestedModesOverrideValues.Count -gt 0) {
  $requestedModes = @($requestedModesOverrideValues)
}
$executedModes = @(Get-StringArray -Value $(if ($manifest.PSObject.Properties['executedModes']) { $manifest.executedModes } else { $null }))
if ($executedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $executedModes = @($modeEntries | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$requestedModeDisplay = if ($requestedModes.Count -gt 0) { [string]::Join(', ', $requestedModes) } else { 'n/a' }
$executedModeDisplay = if ($executedModes.Count -gt 0) { [string]::Join(', ', $executedModes) } else { 'n/a' }
$comparisons = @($historyContext.comparisons)
$branchBudget = Get-ObjectPropertyValue -InputObject $manifest -Name 'branchBudget'
$sourceBranchRef = [string](Coalesce (Get-ObjectPropertyValue -InputObject $branchBudget -Name 'sourceBranchRef') '')
$branchBudgetFacade = New-BranchBudgetFacade -BranchBudget $branchBudget
$branchBudgetDisplay = $null
if ($branchBudgetFacade) {
  $branchBudgetParts = New-Object System.Collections.Generic.List[string]
  if ($null -ne $branchBudgetFacade.commitCount -and $null -ne $branchBudgetFacade.maxCommitCount) {
    [void]$branchBudgetParts.Add(('{0}/{1}' -f $branchBudgetFacade.commitCount, $branchBudgetFacade.maxCommitCount))
  } elseif ($null -ne $branchBudgetFacade.maxCommitCount) {
    [void]$branchBudgetParts.Add(('max {0}' -f $branchBudgetFacade.maxCommitCount))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$branchBudgetFacade.baselineRef)) {
    [void]$branchBudgetParts.Add(('baseline: {0}' -f $branchBudgetFacade.baselineRef))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$branchBudgetFacade.status)) {
    [void]$branchBudgetParts.Add(('status: {0}' -f $branchBudgetFacade.status))
  }
  if ($branchBudgetParts.Count -gt 0) {
    $branchBudgetDisplay = [string]::Join('; ', @($branchBudgetParts.ToArray()))
  }
}

$modeOutcomeClasses = New-Object System.Collections.Generic.List[string]
foreach ($mode in $modeEntries) {
  $modeName = [string](Coalesce $mode.name $mode.slug)
  $modeComparisonClasses = @()
  if (-not [string]::IsNullOrWhiteSpace($modeName)) {
    $modeComparisonClasses = @(
      $comparisons |
        Where-Object {
          $comparisonMode = if ($_.PSObject.Properties['mode']) { [string]$_.mode } else { '' }
          $comparisonMode -eq $modeName
        } |
        ForEach-Object { Resolve-ComparisonOutcomeClass -Comparison $_ }
    )
  }
  $modeOutcomeClasses.Add((Resolve-ModeOutcomeClass -Stats $mode.stats -ComparisonClasses $modeComparisonClasses)) | Out-Null
}

$comparisonOutcomeClasses = @($comparisons | ForEach-Object { Resolve-ComparisonOutcomeClass -Comparison $_ })
$coverageClass = Resolve-CoverageClass -RequestedModes $requestedModes -ExecutedModes $executedModes
$coverageClassDetail = Get-CoverageClassDetail -RequestedModes $requestedModes -ExecutedModes $executedModes
$modeSensitivity = Resolve-ModeSensitivity -ObservedModeCount $modeEntries.Count -ModeOutcomeClasses @($modeOutcomeClasses.ToArray())
$outcomeLabels = @(Get-SortedUniqueStringArray -Value @($comparisonOutcomeClasses + @($modeOutcomeClasses.ToArray())))

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# VI History Report')
$summaryLines.Add('')
$summaryLines.Add(('Target: `{0}`' -f (Coalesce $targetPath 'unknown')))
$summaryLines.Add(('Requested Start Ref: `{0}`' -f (Coalesce $requestedStart 'n/a')))
$summaryLines.Add(('Effective Start Ref: `{0}`' -f (Coalesce $startRef 'n/a')))
if (-not [string]::IsNullOrWhiteSpace($sourceBranchRef)) {
  $summaryLines.Add(('Source Branch: `{0}`' -f $sourceBranchRef))
}
if (-not [string]::IsNullOrWhiteSpace([string]$branchBudgetDisplay)) {
  $summaryLines.Add(('Source Branch Budget: `{0}`' -f $branchBudgetDisplay))
}
$summaryLines.Add(('Requested Modes: `{0}`' -f $requestedModeDisplay))
$summaryLines.Add(('Executed Modes: `{0}`' -f $executedModeDisplay))

if ($stats) {
  $summaryLines.Add('')
  $summaryLines.Add('| Metric | Value |')
  $summaryLines.Add('| --- | --- |')
  $summaryLines.Add(('| Modes | {0} |' -f (Coalesce $stats.modes $modeEntries.Count)))
  $summaryLines.Add(('| Comparisons | {0} |' -f (Coalesce $stats.processed 'n/a')))
  $summaryLines.Add(('| Diffs | {0} |' -f (Coalesce $stats.diffs 'n/a')))
  if ($stats.signalDiffs -ne $null) {
    $summaryLines.Add(('| Signal Diffs | {0} |' -f $stats.signalDiffs))
  }
  if ($stats.noiseCollapsed -ne $null) {
    $summaryLines.Add(('| Collapsed Noise | {0} |' -f $stats.noiseCollapsed))
  }
  $summaryLines.Add(('| Missing | {0} |' -f (Coalesce $stats.missing 'n/a')))
  if ($stats.errors -ne $null) {
    $summaryLines.Add(('| Errors | {0} |' -f $stats.errors))
  }
  $categorySummaryEntries = Get-CategoryCountEntries -CategoryCounts $stats.categoryCounts
  if ($categorySummaryEntries -and $categorySummaryEntries.Count -gt 0) {
    $categoryParts = $categorySummaryEntries | ForEach-Object {
      $labelValue = [string]$_.label
      switch ($_.classification) {
        'noise'   { $labelValue = '{0} _(noise)_' -f $labelValue }
        'neutral' { $labelValue = '{0} _(neutral)_' -f $labelValue }
      }
      '{0} ({1})' -f $labelValue, $_.count
    }
    $summaryLines.Add(('| Categories | {0} |' -f ($categoryParts -join '<br>')))
  }
  $bucketSummaryEntries = Get-BucketCountEntries -BucketCounts $stats.bucketCounts
  if ($bucketSummaryEntries -and $bucketSummaryEntries.Count -gt 0) {
    $bucketParts = $bucketSummaryEntries | ForEach-Object {
      $labelValue = [string]$_.label
      switch ($_.classification) {
        'noise'   { $labelValue = '{0} _(noise)_' -f $labelValue }
        'neutral' { $labelValue = '{0} _(neutral)_' -f $labelValue }
      }
      '{0} ({1})' -f $labelValue, $_.count
    }
    $summaryLines.Add(('| Buckets | {0} |' -f ($bucketParts -join '<br>')))
  }
}

$summaryLines.Add('')
$summaryLines.Add('## Observed interpretation')
$summaryLines.Add('')
$summaryLines.Add('| Signal | Value |')
$summaryLines.Add('| --- | --- |')
$summaryLines.Add(('| Coverage Class | {0} |' -f (Format-MarkdownCodeList -Values @($coverageClass))))
$summaryLines.Add(('| Coverage Detail | {0} |' -f $coverageClassDetail))
$summaryLines.Add(('| Mode Sensitivity | {0} |' -f (Format-MarkdownCodeList -Values @($modeSensitivity))))
$summaryLines.Add(('| Outcome Labels | {0} |' -f (Format-MarkdownCodeList -Values $outcomeLabels)))

if ($modeEntries.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('## Mode overview')
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Processed | Diffs | Signal | Collapsed Noise | Missing | Categories | Buckets | Flags |')
  $summaryLines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
  foreach ($mode in $modeEntries) {
    $flagDisplay = '_none_'
    if ($mode.flags) {
      $flags = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($flags.Count -gt 0) {
        $flagDisplay = ($flags | ForEach-Object { ('`{0}`' -f $_) }) -join '<br>'
      }
    }
    $categoryDisplay = '_none_'
    $categoryEntries = Get-CategoryCountEntries -CategoryCounts $mode.stats.categoryCounts
    if ($categoryEntries -and $categoryEntries.Count -gt 0) {
      $categoryParts = New-Object System.Collections.Generic.List[string]
      foreach ($entry in $categoryEntries) {
        $labelText = [string]$entry.label
        switch ($entry.classification) {
          'noise'      { $labelText = '{0} _(noise)_' -f $labelText }
          'neutral'    { $labelText = '{0} _(neutral)_' -f $labelText }
        }
        $displayValue = if ($entry.count -gt 0) { "$labelText ($($entry.count))" } else { $labelText }
        $categoryParts.Add($displayValue) | Out-Null
      }
      if ($categoryParts.Count -gt 0) {
        $categoryDisplay = $categoryParts -join '<br>'
      }
    }
    $bucketDisplay = '_none_'
    $bucketEntries = Get-BucketCountEntries -BucketCounts $mode.stats.bucketCounts
    if ($bucketEntries -and $bucketEntries.Count -gt 0) {
      $bucketParts = New-Object System.Collections.Generic.List[string]
      foreach ($bucketEntry in $bucketEntries) {
        $bucketLabel = [string]$bucketEntry.label
        switch ($bucketEntry.classification) {
          'noise'   { $bucketLabel = '{0} _(noise)_' -f $bucketLabel }
          'neutral' { $bucketLabel = '{0} _(neutral)_' -f $bucketLabel }
        }
        $bucketDisplayValue = if ($bucketEntry.count -gt 0) { "$bucketLabel ($($bucketEntry.count))" } else { $bucketLabel }
        $bucketParts.Add($bucketDisplayValue) | Out-Null
      }
      if ($bucketParts.Count -gt 0) {
        $bucketDisplay = $bucketParts -join '<br>'
      }
    }
    $summaryLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
        (Coalesce $mode.name 'unknown'),
        (Coalesce $mode.stats.processed 'n/a'),
        (Coalesce $mode.stats.diffs 'n/a'),
        (Coalesce $mode.stats.signalDiffs 'n/a'),
        (Coalesce $mode.stats.noiseCollapsed 'n/a'),
        (Coalesce $mode.stats.missing 'n/a'),
        $categoryDisplay,
        $bucketDisplay,
      $flagDisplay))
  }
}

$stepSummaryLines = @($summaryLines)

$comparisonHtmlRows = New-Object System.Collections.Generic.List[object]
if ($comparisons.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('## Commit pairs')
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Pair | Lineage | Base | Head | Diff | Duration (s) | Categories | Buckets | Report | Highlights |')
  $summaryLines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |')
  $comparisonSubLines = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $comparisons) {
    $lineageNode = if ($entry.PSObject.Properties['lineage']) { $entry.lineage } else { $null }
    $lineageLabel = $null
    if ($entry.PSObject.Properties['lineageLabel'] -and -not [string]::IsNullOrWhiteSpace($entry.lineageLabel)) {
      $lineageLabel = [string]$entry.lineageLabel
    } else {
      $headFullRef = if ($entry.head -and $entry.head.PSObject.Properties['full']) { $entry.head.full } else { $null }
      $baseFullRef = if ($entry.base -and $entry.base.PSObject.Properties['full']) { $entry.base.full } else { $null }
      $lineageLabel = Get-LineageLabel -Lineage $lineageNode -HeadRef $headFullRef -BaseRef $baseFullRef
    }
    if ([string]::IsNullOrWhiteSpace($lineageLabel)) { $lineageLabel = 'Mainline' }

    $baseRef = Coalesce $entry.base.short $entry.base.full
    if ($entry.base.subject) { $baseRef = '{0} ({1})' -f $baseRef, $entry.base.subject }
    $headRef = Coalesce $entry.head.short $entry.head.full
    if ($entry.head.subject) { $headRef = '{0} ({1})' -f $headRef, $entry.head.subject }
    $resultNode = $entry.result
    $hasDiffValue = $resultNode -and $resultNode.PSObject.Properties['diff']
    $diffValue = $hasDiffValue -and ($resultNode.diff -eq $true)
    $statusValue = if ($resultNode -and $resultNode.PSObject.Properties['status']) { [string]$resultNode.status } else { $null }
    $diffCell = if ($hasDiffValue) {
      if ($diffValue) {
        if ($resultNode -and $resultNode.PSObject.Properties['collapsed'] -and [bool]$resultNode.collapsed) {
          '_collapsed noise_'
        } else {
          '**diff**'
        }
      } else { 'clean' }
    } elseif ($statusValue) {
      ('_{0}_' -f $statusValue)
    } else {
      'n/a'
    }
    $durationValue = $null
    if ($resultNode -and $resultNode.PSObject.Properties['duration_s'] -and $resultNode.duration_s -ne $null -and $resultNode.duration_s -is [ValueType]) {
      try { $durationValue = [double]$resultNode.duration_s } catch { $durationValue = $null }
    }
    $duration = if ($durationValue -ne $null) { '{0:N2}' -f $durationValue } else { 'n/a' }
    $reportCell = '_missing_'
    $reportRelativeNormalized = $null
    $reportPath = if ($resultNode -and $resultNode.PSObject.Properties['reportPath']) { $resultNode.reportPath } else { $null }
    if ($reportPath) {
      $reportRelative = $null
      try {
        $reportRelative = [System.IO.Path]::GetRelativePath($outputResolved, $reportPath)
      } catch {
        $reportRelative = $null
      }
      if (-not [string]::IsNullOrWhiteSpace($reportRelative)) {
        $reportRelative = $reportRelative -replace '\\','/'
        if (-not $reportRelative.StartsWith('.')) {
          $reportRelative = "./$reportRelative"
        }
        $reportRelativeNormalized = $reportRelative
        $reportCell = ('[report]({0})' -f $reportRelative)
      } else {
        $reportCell = ('`{0}`' -f $reportPath)
      }
    }
    $categoryText = '_none_'
    $categoryEntries = @()
    if ($resultNode -and $resultNode.PSObject.Properties['categories'] -and $resultNode.categories) {
      $categoryEntries = Get-CategoryLabelEntries -Categories $resultNode.categories
  if ($categoryEntries -and $categoryEntries.Count -gt 0) {
        $categoryParts = New-Object System.Collections.Generic.List[string]
        foreach ($entryInfo in $categoryEntries) {
          $labelValue = [string]$entryInfo.label
          switch ($entryInfo.classification) {
            'noise'   { $labelValue = '{0} _(noise)_' -f $labelValue }
            'neutral' { $labelValue = '{0} _(neutral)_' -f $labelValue }
          }
          $categoryParts.Add($labelValue) | Out-Null
        }
        if ($categoryParts.Count -gt 0) {
          $categoryText = $categoryParts -join '<br />'
        }
      }
    }
    $highlightText = ''
    $highlightCollection = @()
    if ($entry.PSObject.Properties['highlights'] -and $entry.highlights) {
      $highlightCollection = @($entry.highlights)
    }
    $highlightCollection = @($highlightCollection | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($highlightCollection.Count -gt 0) {
      $highlightText = [string]::Join('<br />', $highlightCollection)
    }
    if ([string]::IsNullOrWhiteSpace($highlightText)) { $highlightText = '_none_' }
    $bucketText = '_none_'
    $bucketLabelEntries = @()
    if ($resultNode -and $resultNode.PSObject.Properties['categoryBucketDetails'] -and $resultNode.categoryBucketDetails) {
      $bucketLabelEntries = Get-BucketLabelEntries -Buckets $resultNode.categoryBucketDetails
    } elseif ($resultNode -and $resultNode.PSObject.Properties['categoryBuckets'] -and $resultNode.categoryBuckets) {
      $bucketLabelEntries = Get-BucketLabelEntries -Buckets $resultNode.categoryBuckets
    }
    if ($bucketLabelEntries -and $bucketLabelEntries.Count -gt 0) {
      $bucketParts = New-Object System.Collections.Generic.List[string]
      foreach ($bucketEntry in $bucketLabelEntries) {
        $bucketLabelValue = [string]$bucketEntry.label
        switch ($bucketEntry.classification) {
          'noise'   { $bucketLabelValue = '{0} _(noise)_' -f $bucketLabelValue }
          'neutral' { $bucketLabelValue = '{0} _(neutral)_' -f $bucketLabelValue }
        }
        $bucketParts.Add($bucketLabelValue) | Out-Null
      }
      if ($bucketParts.Count -gt 0) {
        $bucketText = $bucketParts -join '<br />'
      }
    }
    $summaryLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} |' -f (Coalesce $entry.mode 'n/a'), (Coalesce $entry.index 'n/a'), $lineageLabel, $baseRef, $headRef, $diffCell, $duration, $categoryText, $bucketText, $reportCell, $highlightText))
    $comparisonSubLines.Add(('<sub>{0} - {1}</sub>' -f $baseRef, $headRef))
    $comparisonHtmlRows.Add([pscustomobject]@{
      Mode       = Coalesce $entry.mode 'n/a'
      Index      = Coalesce $entry.index 'n/a'
      BaseLabel  = $baseRef
      HeadLabel  = $headRef
      Lineage    = if ($lineageNode) { [pscustomobject]$lineageNode } else { $null }
      LineageLabel = $lineageLabel
      LineageType  = if ($lineageNode -and $lineageNode.PSObject.Properties['type']) { [string]$lineageNode.type } else { 'mainline' }
      Diff       = [bool]$diffValue
      Collapsed  = if ($resultNode -and $resultNode.PSObject.Properties['collapsed']) { [bool]$resultNode.collapsed } else { $false }
      HasDiff    = $hasDiffValue
      Status     = $statusValue
      Duration   = $durationValue
      DurationDisplay = $duration
      ReportPath = $reportPath
      ReportRelative = $reportRelativeNormalized
      ReportDisplay = $reportCell
      ExitCode   = if ($resultNode -and $resultNode.PSObject.Properties['exitCode']) { $resultNode.exitCode } else { $null }
      Highlights = if ($entry.PSObject.Properties['highlights'] -and $entry.highlights) { @($entry.highlights) } else { @() }
      Categories = $categoryEntries
      CategorySlugs = if ($categoryEntries) { @($categoryEntries | ForEach-Object { $_.slug }) } else { @() }
      CategoriesDisplay = $categoryText
      Buckets   = $bucketLabelEntries
      BucketSlugs = if ($bucketLabelEntries) { @($bucketLabelEntries | ForEach-Object { $_.slug }) } elseif ($resultNode -and $resultNode.PSObject.Properties['categoryBuckets']) { @($resultNode.categoryBuckets) } else { @() }
      BucketsDisplay = $bucketText
      HighlightsDisplay = $highlightText
    })
  }
  if ($comparisonSubLines.Count -gt 0) {
    foreach ($subLine in $comparisonSubLines) {
      $summaryLines.Add($subLine)
    }
  }
}

$summaryLines.Add('')
$summaryLines.Add('## Mode filter coverage')
$summaryLines.Add('')
if ($modeEntries.Count -gt 0) {
  foreach ($mode in $modeEntries) {
    $modeTitle = Coalesce $mode.name 'unknown'
    $flagList = @()
    if ($mode.flags) {
      $flagList = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $flagSummary = if ($flagList.Count -gt 0) { $flagList -join ', ' } else { 'none' }
    $summaryLines.Add(('- {0}: {1}' -f $modeTitle, $flagSummary))
  }
} else {
  $summaryLines.Add('_No attribute coverage data available._')
}

$summaryLines.Add('')
$summaryLines.Add('---')
$summaryLines.Add(('History manifest: `{0}`' -f $manifestResolved))
if ($contextResolved) {
  $summaryLines.Add(('History context: `{0}`' -f $contextResolved))
}

$markdownContent = $summaryLines -join [Environment]::NewLine
[System.IO.File]::WriteAllText($MarkdownPath, $markdownContent, [System.Text.Encoding]::UTF8)
$markdownOutPath = (Resolve-Path -LiteralPath $MarkdownPath).Path

$htmlOutPath = $null
if ($emitHtml -and $HtmlPath) {
  $metricsRows = @(
    @{ Label = 'Modes'; Value = Coalesce $stats.modes $modeEntries.Count },
    @{ Label = 'Comparisons'; Value = Coalesce $stats.processed $comparisons.Count },
    @{ Label = 'Diffs'; Value = $stats.diffs },
    @{ Label = 'Signal Diffs'; Value = $stats.signalDiffs },
    @{ Label = 'Collapsed Noise'; Value = $stats.noiseCollapsed },
    @{ Label = 'Missing'; Value = $stats.missing },
    @{ Label = 'Errors'; Value = $stats.errors }
  )

  $htmlBuilder = New-Object System.Text.StringBuilder
  [void]$htmlBuilder.AppendLine('<!DOCTYPE html>')
  [void]$htmlBuilder.AppendLine('<html lang="en">')
  [void]$htmlBuilder.AppendLine('<head>')
  [void]$htmlBuilder.AppendLine('  <meta charset="utf-8" />')
  [void]$htmlBuilder.AppendLine('  <title>VI History Report</title>')
  [void]$htmlBuilder.AppendLine('  <style>')
  [void]$htmlBuilder.AppendLine('    body { font-family: "Segoe UI", Arial, sans-serif; margin: 24px; color: #1b1b1b; background: #fdfdfd; line-height: 1.55; }')
  [void]$htmlBuilder.AppendLine('    h1 { margin-top: 0; }')
  [void]$htmlBuilder.AppendLine('    h2 { margin-top: 2rem; }')
  [void]$htmlBuilder.AppendLine('    code { font-family: "Consolas", "Courier New", monospace; }')
  [void]$htmlBuilder.AppendLine('    table { border-collapse: collapse; width: 100%; margin: 1rem 0; box-shadow: 0 0 0 1px rgba(0,0,0,0.05); background: #fff; }')
  [void]$htmlBuilder.AppendLine('    th, td { border: 1px solid #d9d9d9; padding: 0.45rem 0.6rem; text-align: left; vertical-align: top; }')
  [void]$htmlBuilder.AppendLine('    th { background: #f3f4f6; font-weight: 600; }')
  [void]$htmlBuilder.AppendLine('    tbody tr:nth-child(even) { background: #fafafa; }')
  [void]$htmlBuilder.AppendLine('    dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1rem; margin: 0 0 1.5rem; }')
  [void]$htmlBuilder.AppendLine('    dl.meta dt { font-weight: 600; }')
  [void]$htmlBuilder.AppendLine('    .diff-yes { color: #b00020; font-weight: 600; }')
  [void]$htmlBuilder.AppendLine('    .diff-no { color: #0c7c11; }')
  [void]$htmlBuilder.AppendLine('    .diff-status { color: #92400e; font-weight: 600; }')
  [void]$htmlBuilder.AppendLine('    .muted { color: #6b7280; font-style: italic; }')
  [void]$htmlBuilder.AppendLine('    .report-path code { word-break: break-all; }')
  [void]$htmlBuilder.AppendLine('    .cat { display: inline-block; padding: 0.1rem 0.45rem; border-radius: 999px; background: #e5e7eb; color: #1f2937; font-size: 0.85rem; margin: 0 0.25rem 0.25rem 0; }')
  [void]$htmlBuilder.AppendLine('    .cat-signal { background: #d1fae5; color: #064e3b; }')
  [void]$htmlBuilder.AppendLine('    .cat-noise { background: #fef3c7; color: #92400e; }')
  [void]$htmlBuilder.AppendLine('    .cat-neutral { background: #e0e7ff; color: #312e81; }')
  [void]$htmlBuilder.AppendLine('    footer { margin-top: 2.5rem; font-size: 0.9rem; color: #4b5563; }')
  [void]$htmlBuilder.AppendLine('  </style>')
  [void]$htmlBuilder.AppendLine('</head>')
  [void]$htmlBuilder.AppendLine('<body>')
  [void]$htmlBuilder.AppendLine('<article>')
  [void]$htmlBuilder.AppendLine('  <h1>VI History Report</h1>')
  [void]$htmlBuilder.AppendLine('  <dl class="meta">')
  [void]$htmlBuilder.AppendLine(('    <dt>Target</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe $targetPath)))
  [void]$htmlBuilder.AppendLine(('    <dt>Requested start</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe (Coalesce $requestedStart 'n/a'))))
  [void]$htmlBuilder.AppendLine(('    <dt>Effective start</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe (Coalesce $startRef 'n/a'))))
  if (-not [string]::IsNullOrWhiteSpace($sourceBranchRef)) {
    [void]$htmlBuilder.AppendLine(('    <dt>Source branch</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe $sourceBranchRef)))
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$branchBudgetDisplay)) {
    [void]$htmlBuilder.AppendLine(('    <dt>Source branch budget</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe $branchBudgetDisplay)))
  }
  [void]$htmlBuilder.AppendLine(('    <dt>Requested modes</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe $requestedModeDisplay)))
  [void]$htmlBuilder.AppendLine(('    <dt>Executed modes</dt><dd><code>{0}</code></dd>' -f (ConvertTo-HtmlSafe $executedModeDisplay)))
  if ($manifest.maxPairs) {
    [void]$htmlBuilder.AppendLine(('    <dt>Max pairs</dt><dd>{0}</dd>' -f (ConvertTo-HtmlSafe $manifest.maxPairs)))
  }
  if ($manifest.status) {
    [void]$htmlBuilder.AppendLine(('    <dt>Status</dt><dd>{0}</dd>' -f (ConvertTo-HtmlSafe $manifest.status)))
  }
  [void]$htmlBuilder.AppendLine('  </dl>')

  if ($metricsRows) {
    [void]$htmlBuilder.AppendLine('  <h2>Summary</h2>')
    [void]$htmlBuilder.AppendLine('  <table>')
    [void]$htmlBuilder.AppendLine('    <thead><tr><th>Metric</th><th>Value</th></tr></thead>')
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($row in $metricsRows) {
      if ($null -eq $row.Value) { continue }
      $valueText = ConvertTo-HtmlSafe $row.Value
      if (-not $valueText) {
        $valueText = '<span class="muted">n/a</span>'
      }
      [void]$htmlBuilder.AppendLine(('      <tr><th scope="row">{0}</th><td>{1}</td></tr>' -f (ConvertTo-HtmlSafe $row.Label), $valueText))
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
  }

  [void]$htmlBuilder.AppendLine('  <h2>Observed interpretation</h2>')
  [void]$htmlBuilder.AppendLine('  <table>')
  [void]$htmlBuilder.AppendLine('    <thead><tr><th>Signal</th><th>Value</th></tr></thead>')
  [void]$htmlBuilder.AppendLine('    <tbody>')
  [void]$htmlBuilder.AppendLine(('      <tr><th scope="row">Coverage Class</th><td>{0}</td></tr>' -f (Format-HtmlCodeList -Values @($coverageClass))))
  [void]$htmlBuilder.AppendLine(('      <tr><th scope="row">Coverage Detail</th><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $coverageClassDetail)))
  [void]$htmlBuilder.AppendLine(('      <tr><th scope="row">Mode Sensitivity</th><td>{0}</td></tr>' -f (Format-HtmlCodeList -Values @($modeSensitivity))))
  [void]$htmlBuilder.AppendLine(('      <tr><th scope="row">Outcome Labels</th><td>{0}</td></tr>' -f (Format-HtmlCodeList -Values $outcomeLabels)))
  [void]$htmlBuilder.AppendLine('    </tbody>')
  [void]$htmlBuilder.AppendLine('  </table>')

  if ($modeEntries.Count -gt 0) {
    [void]$htmlBuilder.AppendLine('  <h2>Mode overview</h2>')
    [void]$htmlBuilder.AppendLine('  <table>')
    [void]$htmlBuilder.AppendLine('    <thead><tr><th>Mode</th><th>Processed</th><th>Diffs</th><th>Signal</th><th>Collapsed Noise</th><th>Missing</th><th>Categories</th><th>Buckets</th><th>Flags</th></tr></thead>')
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($mode in $modeEntries) {
      $modeName = ConvertTo-HtmlSafe (Coalesce $mode.name 'unknown')
      $processed = ConvertTo-HtmlSafe (Coalesce $mode.stats.processed 'n/a')
      $diffCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.diffs 'n/a')
      $signalDiffCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.signalDiffs 'n/a')
      $noiseCollapsedCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.noiseCollapsed 'n/a')
      $missingCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.missing 'n/a')
      $categoryHtml = '<span class="muted">none</span>'
      $modeCategoryEntries = Get-CategoryCountEntries -CategoryCounts $mode.stats.categoryCounts
      if ($modeCategoryEntries -and $modeCategoryEntries.Count -gt 0) {
        $categoryRows = New-Object System.Collections.Generic.List[string]
        foreach ($modeCategoryEntry in $modeCategoryEntries) {
          $labelText = [string]$modeCategoryEntry.label
          switch ($modeCategoryEntry.classification) {
            'noise'   { $labelText = '{0} (noise)' -f $labelText }
            'neutral' { $labelText = '{0} (neutral)' -f $labelText }
          }
          $categoryRows.Add(('{0} ({1})' -f (ConvertTo-HtmlSafe $labelText), $modeCategoryEntry.count)) | Out-Null
        }
        if ($categoryRows.Count -gt 0) {
          $categoryHtml = [string]::Join('<br />', $categoryRows)
        }
      }
      $bucketHtml = '<span class="muted">none</span>'
      $modeBucketEntries = Get-BucketCountEntries -BucketCounts $mode.stats.bucketCounts
      if ($modeBucketEntries -and $modeBucketEntries.Count -gt 0) {
        $bucketRows = New-Object System.Collections.Generic.List[string]
        foreach ($modeBucketEntry in $modeBucketEntries) {
          $labelText = [string]$modeBucketEntry.label
          switch ($modeBucketEntry.classification) {
            'noise'   { $labelText = '{0} (noise)' -f $labelText }
            'neutral' { $labelText = '{0} (neutral)' -f $labelText }
          }
          $bucketRows.Add(('{0} ({1})' -f (ConvertTo-HtmlSafe $labelText), $modeBucketEntry.count)) | Out-Null
        }
        if ($bucketRows.Count -gt 0) {
          $bucketHtml = [string]::Join('<br />', $bucketRows)
        }
      }
      $flags = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($flags.Count -gt 0) {
        $flagCells = $flags | ForEach-Object { "<code>{0}</code>" -f (ConvertTo-HtmlSafe $_) }
        $flagHtml = ($flagCells -join '<br />')
      } else {
        $flagHtml = '<span class="muted">none</span>'
      }
      [void]$htmlBuilder.AppendLine(("      <tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td></tr>" -f $modeName, $processed, $diffCount, $signalDiffCount, $noiseCollapsedCount, $missingCount, $categoryHtml, $bucketHtml, $flagHtml))
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
  }

  [void]$htmlBuilder.AppendLine('  <h2>Commit pairs</h2>')
  if ($comparisonHtmlRows.Count -gt 0) {
    [void]$htmlBuilder.AppendLine('  <table>')
    [void]$htmlBuilder.AppendLine('    <thead><tr><th>Mode</th><th>Pair</th><th>Lineage</th><th>Base</th><th>Head</th><th>Diff</th><th>Duration (s)</th><th>Categories</th><th>Buckets</th><th>Report</th><th>Highlights</th></tr></thead>')
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($row in $comparisonHtmlRows) {
      $diffClass = if ($row.Diff) {
        if ($row.Collapsed) { 'diff-collapsed' } else { 'diff-yes' }
      } elseif ($row.Status) { 'diff-status' } else { 'diff-no' }
      $diffLabel = if ($row.Diff) {
        if ($row.Collapsed) { 'Collapsed noise' } else { 'Diff' }
      } elseif ($row.Status) { ConvertTo-HtmlSafe $row.Status } else { 'No' }
      $durationDisplay = '<span class="muted">n/a</span>'
      if ($row.DurationDisplay -and $row.DurationDisplay -ne 'n/a') {
        $durationDisplay = ConvertTo-HtmlSafe $row.DurationDisplay
      } elseif ($row.Duration -ne $null) {
        $durationDisplay = ('{0:N2}' -f $row.Duration)
      }
      $categoryHtml = '<span class="muted">none</span>'
      $categoryAttr = ''
      $categorySource = $row.Categories
      if ($categorySource -and $categorySource.Count -gt 0) {
        $categorySpans = New-Object System.Collections.Generic.List[string]
        foreach ($catEntry in $categorySource) {
          if ($null -eq $catEntry) { continue }
          $catSlug = ConvertTo-HtmlSafe $catEntry.slug
          $catLabel = ConvertTo-HtmlSafe $catEntry.label
          $classList = New-Object System.Collections.Generic.List[string]
          $classList.Add('cat') | Out-Null
          switch ($catEntry.classification) {
            'noise'   { $classList.Add('cat-noise') | Out-Null }
            'neutral' { $classList.Add('cat-neutral') | Out-Null }
            default   { $classList.Add('cat-signal') | Out-Null }
          }
          $classAttr = [string]::Join(' ', $classList)
          $categorySpans.Add("<span class=""$classAttr"" data-cat=""$catSlug"">$catLabel</span>") | Out-Null
        }
        if ($categorySpans.Count -gt 0) {
          $categoryHtml = [string]::Join('<br />', $categorySpans)
        }
      } elseif ($row.CategoriesDisplay -and $row.CategoriesDisplay -ne '_none_') {
        $displayParts = $row.CategoriesDisplay -split '<br\s*/?>'
        $encodedParts = $displayParts | ForEach-Object { ConvertTo-HtmlSafe $_ }
        if ($encodedParts.Count -gt 0) {
          $categoryHtml = [string]::Join('<br />', $encodedParts)
        }
      }
      $categorySlugs = @()
      if ($row.CategorySlugs) {
        $categorySlugs = @($row.CategorySlugs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($categorySlugs.Count -gt 0) {
        $safeSlugs = $categorySlugs | ForEach-Object { ($_ -replace '[^a-z0-9\-\._]', '-') }
        $categoryAttr = ' data-categories="{0}"' -f ([string]::Join(' ', $safeSlugs))
      }

      $bucketHtml = '<span class="muted">none</span>'
      $bucketAttr = ''
      $bucketSource = $row.Buckets
      if (-not $bucketSource -and $row.BucketsDisplay) {
        $bucketSource = @($row.BucketsDisplay)
      }
      if ($bucketSource) {
        if ($bucketSource -isnot [System.Collections.IEnumerable] -or ($bucketSource -is [string])) {
          $bucketSource = @($bucketSource)
        }
      }
      if ($bucketSource -and $bucketSource.Count -gt 0) {
        $bucketSpans = New-Object System.Collections.Generic.List[string]
        foreach ($bucketEntry in $bucketSource) {
          if ($null -eq $bucketEntry) { continue }
          $bucketLabel = $bucketEntry
          $bucketSlugValue = $null
          $bucketClassList = New-Object System.Collections.Generic.List[string]
          $bucketClassList.Add('bucket') | Out-Null
          if ($bucketEntry -is [pscustomobject]) {
            if ($bucketEntry.PSObject.Properties['label']) {
              $bucketLabel = $bucketEntry.label
            }
            if ($bucketEntry.PSObject.Properties['slug']) {
              $bucketSlugValue = $bucketEntry.slug
            }
            if ($bucketEntry.PSObject.Properties['classification']) {
              switch ([string]$bucketEntry.classification) {
                'noise'   { $bucketClassList.Add('bucket-noise') | Out-Null }
                'neutral' { $bucketClassList.Add('bucket-neutral') | Out-Null }
                default   { $bucketClassList.Add('bucket-signal') | Out-Null }
              }
            }
          }
          $bucketLabelEncoded = ConvertTo-HtmlSafe $bucketLabel
          $bucketSlugAttr = ConvertTo-HtmlSafe $bucketSlugValue
          $bucketClassAttr = [string]::Join(' ', $bucketClassList)
          if (-not [string]::IsNullOrWhiteSpace($bucketLabelEncoded)) {
            if ([string]::IsNullOrWhiteSpace($bucketSlugAttr)) {
              $bucketSpans.Add("<span class=""$bucketClassAttr"">$bucketLabelEncoded</span>") | Out-Null
            } else {
              $bucketSpans.Add("<span class=""$bucketClassAttr"" data-bucket=""$bucketSlugAttr"">$bucketLabelEncoded</span>") | Out-Null
            }
          }
        }
        if ($bucketSpans.Count -gt 0) {
          $bucketHtml = [string]::Join('<br />', $bucketSpans)
        } elseif ($row.BucketsDisplay -and $row.BucketsDisplay -ne '_none_') {
          $bucketHtml = ConvertTo-HtmlSafe $row.BucketsDisplay
        }
      } elseif ($row.BucketsDisplay -and $row.BucketsDisplay -ne '_none_') {
        $bucketHtml = ConvertTo-HtmlSafe $row.BucketsDisplay
      }
      $bucketSlugs = @()
      if ($row.BucketSlugs) {
        $bucketSlugs = @($row.BucketSlugs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($bucketSlugs.Count -gt 0) {
        $safeBucketSlugs = $bucketSlugs | ForEach-Object { ($_ -replace '[^a-z0-9\-\._]', '-') }
        $bucketAttr = ' data-buckets="{0}"' -f ([string]::Join(' ', $safeBucketSlugs))
      }

      $reportHtml = '<span class="muted">missing</span>'
      if ($row.ReportRelative) {
        $reportHref = $row.ReportRelative -replace '\\','/'
        $reportHtml = ('<a href="{0}">report</a>' -f (ConvertTo-HtmlSafe $reportHref))
      } elseif ($row.ReportPath) {
        $reportHtml = ('<code>{0}</code>' -f (ConvertTo-HtmlSafe $row.ReportPath))
      }

      $highlightHtml = '<span class="muted">none</span>'
      $highlightSource = $row.Highlights
      if (-not $highlightSource -and $row.HighlightsDisplay) {
        $highlightSource = @($row.HighlightsDisplay)
      }
      $highlightItems = @()
      if ($highlightSource -ne $null) {
        $highlightItems = @($highlightSource)
      }
      $highlightItems = @($highlightItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($highlightItems.Count -gt 0) {
        $highlightHtml = [string]::Join('<br />', ($highlightItems | ForEach-Object { ConvertTo-HtmlSafe $_ }))
      }

      $lineageLabelHtml = if ($row.LineageLabel) { ConvertTo-HtmlSafe $row.LineageLabel } else { 'Mainline' }
      $lineageAttrList = New-Object System.Collections.Generic.List[string]
      $lineageTypeValue = if ($row.LineageType) { [string]$row.LineageType } else { 'mainline' }
      if (-not [string]::IsNullOrWhiteSpace($lineageTypeValue)) {
        $lineageAttrList.Add(('data-lineage-type="{0}"' -f (ConvertTo-HtmlSafe $lineageTypeValue))) | Out-Null
      }
      if ($row.Lineage) {
        if ($row.Lineage.PSObject.Properties['parentIndex'] -and $row.Lineage.parentIndex -ne $null) {
          $lineageAttrList.Add(('data-lineage-parent-index="{0}"' -f (ConvertTo-HtmlSafe $row.Lineage.parentIndex))) | Out-Null
        }
        if ($row.Lineage.PSObject.Properties['parentCount'] -and $row.Lineage.parentCount -ne $null) {
          $lineageAttrList.Add(('data-lineage-parent-count="{0}"' -f (ConvertTo-HtmlSafe $row.Lineage.parentCount))) | Out-Null
        }
        if ($row.Lineage.PSObject.Properties['depth'] -and $row.Lineage.depth -ne $null) {
          $lineageAttrList.Add(('data-lineage-depth="{0}"' -f (ConvertTo-HtmlSafe $row.Lineage.depth))) | Out-Null
        }
        if ($row.Lineage.PSObject.Properties['mergeCommit'] -and -not [string]::IsNullOrWhiteSpace($row.Lineage.mergeCommit)) {
          $lineageAttrList.Add(('data-lineage-merge="{0}"' -f (ConvertTo-HtmlSafe $row.Lineage.mergeCommit))) | Out-Null
        }
        if ($row.Lineage.PSObject.Properties['branchHead'] -and -not [string]::IsNullOrWhiteSpace($row.Lineage.branchHead)) {
          $lineageAttrList.Add(('data-lineage-branch="{0}"' -f (ConvertTo-HtmlSafe $row.Lineage.branchHead))) | Out-Null
        }
      }
      $lineageAttr = if ($lineageAttrList.Count -gt 0) { ' ' + ([string]::Join(' ', $lineageAttrList)) } else { '' }
      $lineageHtml = "<span$lineageAttr>$lineageLabelHtml</span>"

      $rowAttr = "$categoryAttr$bucketAttr"
      $modeCell = ConvertTo-HtmlSafe (Coalesce $row.Mode 'n/a')
      $indexCell = ConvertTo-HtmlSafe (Coalesce $row.Index 'n/a')
      $baseCell = ConvertTo-HtmlSafe $row.BaseLabel
      $headCell = ConvertTo-HtmlSafe $row.HeadLabel
      $line = "      <tr$rowAttr><td>$modeCell</td><td>$indexCell</td><td>$lineageHtml</td><td>$baseCell</td><td>$headCell</td><td class=""$diffClass"">$diffLabel</td><td>$durationDisplay</td><td>$categoryHtml</td><td>$bucketHtml</td><td class=""report-path"">$reportHtml</td><td>$highlightHtml</td></tr>"
      [void]$htmlBuilder.AppendLine($line)
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
  } else {
    [void]$htmlBuilder.AppendLine('  <p class="muted">No commit pairs were captured for the requested history window.</p>')
  }

  [void]$htmlBuilder.AppendLine('  <h2>Mode filter coverage</h2>')
  if ($modeEntries.Count -gt 0) {
    [void]$htmlBuilder.AppendLine('  <ul>')
    foreach ($mode in $modeEntries) {
      $modeTitle = ConvertTo-HtmlSafe (Coalesce $mode.name 'unknown')
      $flagList = @()
      if ($mode.flags) {
        $flagList = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      }
      if ($flagList.Count -gt 0) {
        $flagHtml = $flagList | ForEach-Object { ('<code>{0}</code>' -f (ConvertTo-HtmlSafe $_)) }
        $flagDisplay = [string]::Join(', ', $flagHtml)
      } else {
        $flagDisplay = '<span class="muted">none</span>'
      }
      [void]$htmlBuilder.AppendLine(("    <li>{0}: {1}</li>" -f $modeTitle, $flagDisplay))
    }
    [void]$htmlBuilder.AppendLine('  </ul>')
  } else {
    [void]$htmlBuilder.AppendLine('  <p class="muted">No attribute coverage data available.</p>')
  }

  [void]$htmlBuilder.AppendLine('  <footer>')
  [void]$htmlBuilder.AppendLine(('    <div>History manifest: <code>{0}</code></div>' -f (ConvertTo-HtmlSafe $manifestResolved)))
  if ($contextResolved) {
    [void]$htmlBuilder.AppendLine(('    <div>History context: <code>{0}</code></div>' -f (ConvertTo-HtmlSafe $contextResolved)))
  }
  [void]$htmlBuilder.AppendLine(('    <div>Markdown summary: <code>{0}</code></div>' -f (ConvertTo-HtmlSafe $markdownOutPath)))
  [void]$htmlBuilder.AppendLine('  </footer>')
  [void]$htmlBuilder.AppendLine('</article>')
  [void]$htmlBuilder.AppendLine('</body>')
  [void]$htmlBuilder.AppendLine('</html>')

  $htmlContent = $htmlBuilder.ToString()
  [System.IO.File]::WriteAllText($HtmlPath, $htmlContent, [System.Text.Encoding]::UTF8)
  $htmlOutPath = (Resolve-Path -LiteralPath $HtmlPath).Path
  Write-GitHubOutput -Key 'history-report-html' -Value $htmlOutPath -DestPath $GitHubOutputPath
}

$summaryResultsDir = if ($outputResolved) { $outputResolved } else { Split-Path -Parent $markdownOutPath }
$aggregateCategoryCountSource = if ($stats -and $stats.PSObject.Properties['categoryCounts']) { $stats.categoryCounts } else { $null }
$aggregateBucketCountSource = if ($stats -and $stats.PSObject.Properties['bucketCounts']) { $stats.bucketCounts } else { $null }
$aggregateCategoryEntries = @(Get-CategoryCountEntries -CategoryCounts $aggregateCategoryCountSource)
$aggregateBucketEntries = @(Get-BucketCountEntries -BucketCounts $aggregateBucketCountSource)
$modeFacadeEntries = @(
  foreach ($mode in @($modeEntries)) {
    $modeCategoryEntries = @(Get-CategoryCountEntries -CategoryCounts $mode.stats.categoryCounts)
    $modeBucketEntries = @(Get-BucketCountEntries -BucketCounts $mode.stats.bucketCounts)
    [ordered]@{
      name = [string](Coalesce $mode.name $mode.slug)
      slug = [string](Coalesce $mode.slug $mode.name)
      status = [string](Coalesce $mode.status 'unknown')
      processed = Get-IntPropertyValue -InputObject $mode.stats -Name 'processed'
      diffs = Get-IntPropertyValue -InputObject $mode.stats -Name 'diffs'
      signalDiffs = Get-IntPropertyValue -InputObject $mode.stats -Name 'signalDiffs'
      noiseCollapsed = Get-IntPropertyValue -InputObject $mode.stats -Name 'noiseCollapsed'
      missing = Get-IntPropertyValue -InputObject $mode.stats -Name 'missing'
      errors = Get-IntPropertyValue -InputObject $mode.stats -Name 'errors'
      categories = @($modeCategoryEntries | ForEach-Object { [string]$_.label })
      bucketProfile = @($modeBucketEntries | ForEach-Object { [string]$_.slug })
      flags = @(Get-StringArray -Value $mode.flags)
      manifestPath = [string](Coalesce $mode.manifestPath '')
      resultsDir = [string](Coalesce $mode.resultsDir '')
    }
  }
)
$historySummaryTarget = [ordered]@{
  path = [string](Coalesce $targetPath '')
  requestedStartRef = [string](Coalesce $requestedStart '')
  effectiveStartRef = [string](Coalesce $startRef '')
}
if (-not [string]::IsNullOrWhiteSpace($sourceBranchRef)) {
  $historySummaryTarget.sourceBranchRef = [string]$sourceBranchRef
}
if ($branchBudgetFacade) {
  $historySummaryTarget.branchBudget = $branchBudgetFacade
}

$historySummary = [ordered]@{
  schema = 'comparevi-tools/history-facade@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  target = $historySummaryTarget
  execution = [ordered]@{
    status = [string](Coalesce (Get-ObjectPropertyValue -InputObject $manifest -Name 'status') 'unknown')
    reportFormat = [string](Coalesce (Get-ObjectPropertyValue -InputObject $manifest -Name 'reportFormat') '')
    resultsDir = [string](Coalesce $summaryResultsDir '')
    manifestPath = [string]$manifestResolved
    requestedModes = @(Get-StringArray -Value $requestedModes)
    executedModes = @(Get-StringArray -Value $executedModes)
  }
  observedInterpretation = [ordered]@{
    coverageClass = [string]$coverageClass
    coverageDetail = [string]$coverageClassDetail
    modeSensitivity = [string]$modeSensitivity
    outcomeLabels = @(Get-SortedUniqueStringArray -Value $outcomeLabels)
  }
  summary = [ordered]@{
    modes = if ($stats -and $stats.PSObject.Properties['modes']) { [int]$stats.modes } else { [int]$modeEntries.Count }
    comparisons = Get-IntPropertyValue -InputObject $stats -Name 'processed'
    diffs = Get-IntPropertyValue -InputObject $stats -Name 'diffs'
    signalDiffs = Get-IntPropertyValue -InputObject $stats -Name 'signalDiffs'
    noiseCollapsed = Get-IntPropertyValue -InputObject $stats -Name 'noiseCollapsed'
    missing = Get-IntPropertyValue -InputObject $stats -Name 'missing'
    errors = Get-IntPropertyValue -InputObject $stats -Name 'errors'
    categories = @($aggregateCategoryEntries | ForEach-Object { [string]$_.label })
    bucketProfile = @($aggregateBucketEntries | ForEach-Object { [string]$_.slug })
    categoryCountKeys = @(Get-CountMapKeys -CountMap $aggregateCategoryCountSource)
    bucketCountKeys = @(Get-CountMapKeys -CountMap $aggregateBucketCountSource)
  }
  reports = [ordered]@{
    markdownPath = [string]$markdownOutPath
    htmlPath = if ($htmlOutPath) { [string]$htmlOutPath } else { '' }
  }
  modes = @($modeFacadeEntries)
}
$historySummary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryJsonPath -Encoding utf8
$summaryJsonOutPath = (Resolve-Path -LiteralPath $SummaryJsonPath).Path

Write-GitHubOutput -Key 'history-report-md' -Value $markdownOutPath -DestPath $GitHubOutputPath
Write-GitHubOutput -Key 'history-summary-json' -Value $summaryJsonOutPath -DestPath $GitHubOutputPath

$stepLines = New-Object System.Collections.Generic.List[string]
foreach ($line in @($stepSummaryLines)) {
  $stepLines.Add([string]$line) | Out-Null
}
$stepLines.Add('') | Out-Null
$stepLines.Add('## Artifacts') | Out-Null
$stepLines.Add('') | Out-Null
$stepLines.Add(('- History facade JSON: `{0}`' -f $summaryJsonOutPath)) | Out-Null
$stepLines.Add(('- Markdown report: `{0}`' -f $markdownOutPath)) | Out-Null
if ($htmlOutPath) {
  $stepLines.Add(('- HTML report: `{0}`' -f $htmlOutPath)) | Out-Null
}
Write-StepSummary -Lines @($stepLines) -DestPath $StepSummaryPath

Write-Host ("History report generated at {0}" -f $markdownOutPath)
