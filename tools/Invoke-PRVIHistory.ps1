#Requires -Version 7.0
<#
.SYNOPSIS
  Runs Compare-VIHistory for each VI referenced in a diff manifest.

.DESCRIPTION
  Loads a `vi-diff-manifest@v1` payload (typically produced by
  `tools/Get-PRVIDiffManifest.ps1`), deduplicates the referenced VI paths, and
  invokes `tools/Compare-VIHistory.ps1` for each unique target. Summary
  metadata and report locations are captured in `pr-vi-history-summary@v1`
  format so PR workflows can surface Markdown tables and artifact links.

.PARAMETER ManifestPath
  Path to the diff manifest JSON file.

.PARAMETER ResultsRoot
  Directory where Compare-VIHistory outputs should be written (one subdirectory
  per VI). Defaults to `tests/results/pr-vi-history`.

.PARAMETER MaxPairs
  Optional cap on commit pairs to evaluate per VI. When omitted or set to 0,
  the helper compares every available revision pair.

.PARAMETER Mode
  Optional Compare-VIHistory mode list (for example `default`, `attributes`).
  Forwarded directly to the history helper.

.PARAMETER SkipRenderReport
  When present, do not request the Markdown/HTML report from Compare-VIHistory.

.PARAMETER DryRun
  Emit the planned targets without invoking Compare-VIHistory.

.PARAMETER CompareInvoker
  Internal testing hook allowing callers to supply a custom script block. The
  block receives a hashtable of parameters compatible with Compare-VIHistory.

.PARAMETER SummaryPath
  Optional override for the summary JSON path. Defaults to
  `<ResultsRoot>/vi-history-summary.json`.

.PARAMETER StartRef
  Optional Compare-VIHistory `-StartRef` override.

.PARAMETER EndRef
  Optional Compare-VIHistory `-EndRef` override.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [string]$ResultsRoot = 'tests/results/pr-vi-history',

    [Nullable[int]]$MaxPairs,
    [Nullable[int]]$CompareTimeoutSeconds,

    [string[]]$Mode,

    [switch]$SkipRenderReport,

    [switch]$DryRun,

    [scriptblock]$CompareInvoker,

    [string]$SummaryPath,

    [string]$StartRef,

    [string]$EndRef,

    [switch]$IncludeMergeParents
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$maxPairsValue = if ($PSBoundParameters.ContainsKey('MaxPairs')) { $MaxPairs } else { $null }
$maxPairsRequested = ($null -ne $maxPairsValue) -and ($maxPairsValue -gt 0)
$compareTimeoutValue = if ($PSBoundParameters.ContainsKey('CompareTimeoutSeconds')) { $CompareTimeoutSeconds } else { $null }
if ($null -eq $compareTimeoutValue -or $compareTimeoutValue -le 0) {
    $timeoutSources = @(
        [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_TIMEOUT_SECONDS', 'Process'),
        [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_TIMEOUT_SECONDS', 'Process'),
        [System.Environment]::GetEnvironmentVariable('COMPAREVI_TIMEOUT_SECONDS', 'Process')
    )
    foreach ($rawTimeout in $timeoutSources) {
        if ([string]::IsNullOrWhiteSpace($rawTimeout)) { continue }
        $parsedTimeout = 0
        if ([int]::TryParse($rawTimeout.Trim(), [ref]$parsedTimeout) -and $parsedTimeout -gt 0) {
            $compareTimeoutValue = [int]$parsedTimeout
            break
        }
    }
}
$compareTimeoutRequested = ($null -ne $compareTimeoutValue) -and ($compareTimeoutValue -gt 0)

function Resolve-ExistingFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description path not provided."
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Get-GitRepoRoot {
    $output = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) {
        throw 'Unable to determine git repository root.'
    }
    return $output.Trim()
}

function Resolve-ViPath {
    param(
        [string]$Path,
        [string]$ParameterName,
        [switch]$AllowMissing,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Path)) {
        try {
            return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } catch {
            if ($AllowMissing) {
                Write-Verbose ("Path not found for {0}: {1}" -f $ParameterName, $Path)
                return $null
            }
            throw ("Unable to resolve {0} path: {1}" -f $ParameterName, $Path)
        }
    }

    $normalized = $Path.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $candidate = Join-Path $RepoRoot $normalized
    try {
        return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    } catch {
        if ($AllowMissing) {
            Write-Verbose ("Path not found for {0}: {1}" -f $ParameterName, $candidate)
            return $null
        }
        throw ("Unable to resolve {0} path: {1}" -f $ParameterName, $candidate)
    }
}

function Get-HistoryFlagList {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $segments = $Raw -split "(\r\n|\n|\r)"
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($segment in $segments) {
        $candidate = $segment.Trim()
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $result.Add($candidate)
    }
    return $result.ToArray()
}

function ConvertTo-NullableBool {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $normalized = $Value.Trim().ToLowerInvariant()
    $truthy = @('1','true','yes','on','replace')
    $falsy  = @('0','false','no','off','append')
    if ($truthy -contains $normalized) { return $true }
    if ($falsy -contains $normalized) { return $false }
    return $null
}

$historyFlagList = $null
$historyFlagSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_FLAGS', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_FLAGS', 'Process')
)
foreach ($rawFlags in $historyFlagSources) {
    if ([string]::IsNullOrWhiteSpace($rawFlags)) { continue }
    $parsedFlags = [string[]](Get-HistoryFlagList -Raw $rawFlags)
    if ($parsedFlags -and $parsedFlags.Length -gt 0) {
        $historyFlagList = $parsedFlags
        break
    }
}

$historyFlagMode = $null
$historyModeSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_FLAGS_MODE', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_FLAGS_MODE', 'Process')
)
foreach ($rawMode in $historyModeSources) {
    if ([string]::IsNullOrWhiteSpace($rawMode)) { continue }
    $normalized = $rawMode.Trim().ToLowerInvariant()
    if ($normalized -eq 'replace' -or $normalized -eq 'append') {
        $historyFlagMode = $normalized
        break
    }
}

$historyReplaceOverride = $null
$historyReplaceSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_COMPARE_REPLACE_FLAGS', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_COMPARE_REPLACE_FLAGS', 'Process')
)
foreach ($rawReplace in $historyReplaceSources) {
    if ([string]::IsNullOrWhiteSpace($rawReplace)) { continue }
    $converted = ConvertTo-NullableBool -Value $rawReplace
    if ($converted -ne $null) {
        $historyReplaceOverride = $converted
        break
    }
}

$historyReplaceFlags = $null
if ($historyReplaceOverride -ne $null) {
    $historyReplaceFlags = $historyReplaceOverride
} elseif ($historyFlagMode) {
    $historyReplaceFlags = ($historyFlagMode -eq 'replace')
}

$extractReportImagesEnabled = $true
$extractImageSources = @(
    [System.Environment]::GetEnvironmentVariable('PR_VI_HISTORY_EXTRACT_REPORT_IMAGES', 'Process'),
    [System.Environment]::GetEnvironmentVariable('VI_HISTORY_EXTRACT_REPORT_IMAGES', 'Process')
)
foreach ($rawExtract in $extractImageSources) {
    if ([string]::IsNullOrWhiteSpace($rawExtract)) { continue }
    $converted = ConvertTo-NullableBool -Value $rawExtract
    if ($converted -ne $null) {
        $extractReportImagesEnabled = [bool]$converted
        break
    }
}

$historyFlagString = $null
if ($historyFlagList -and $historyFlagList.Length -gt 0) {
    $historyFlagString = ($historyFlagList -join ' ')
}

function Get-RepoRelativePath {
    param(
        [string]$FullPath,
        [string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $null
    }

    try {
        $full = [System.IO.Path]::GetFullPath($FullPath)
        $root = [System.IO.Path]::GetFullPath($RepoRoot)
    } catch {
        return $null
    }

    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    $relative = $full.Substring($root.Length).TrimStart('\','/')
    if (-not $relative) {
        return $null
    }
    return $relative.Replace('\','/')
}

function Sanitize-Token {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'vi-history'
    }
    $token = ($Value -replace '[^A-Za-z0-9._-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($token)) {
        return 'vi-history'
    }
    if ($token.Length -gt 60) {
        return $token.Substring(0, 60)
    }
    return $token
}

function Convert-ToNullableDouble {
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return $null }
    try {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            return $null
        }
        return $number
    } catch {
        return $null
    }
}

function Get-PercentileSeconds {
    param(
        [double[]]$SortedValues,
        [ValidateRange(0.0, 1.0)][double]$Percentile
    )

    if (-not $SortedValues -or $SortedValues.Count -eq 0) {
        return $null
    }

    $index = [Math]::Ceiling($SortedValues.Count * $Percentile) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $SortedValues.Count) { $index = $SortedValues.Count - 1 }
    return [Math]::Round([double]$SortedValues[$index], 3)
}

function New-TimingSummary {
    param(
        [double[]]$DurationsSeconds
    )

    $durations = @()
    if ($DurationsSeconds) {
        foreach ($duration in $DurationsSeconds) {
            $candidate = Convert-ToNullableDouble -Value $duration
            if ($candidate -eq $null) { continue }
            if ($candidate -lt 0) { continue }
            $durations += [double]$candidate
        }
    }

    if (-not $durations -or $durations.Count -eq 0) {
        return [pscustomobject]@{
            comparisonCount = 0
            minSeconds      = $null
            medianSeconds   = $null
            p95Seconds      = $null
            totalSeconds    = 0.0
            estimatedCompareTime = [pscustomobject]@{
                seconds     = $null
                source      = 'insufficient-data'
                confidence  = 'low'
                note        = 'No observed compare durations were available.'
            }
        }
    }

    $sorted = @($durations | Sort-Object)
    $mid = [Math]::Floor(($sorted.Count - 1) / 2)
    $median = if (($sorted.Count % 2) -eq 1) {
        [double]$sorted[$mid]
    } else {
        ([double]$sorted[$mid] + [double]$sorted[$mid + 1]) / 2.0
    }
    $total = 0.0
    foreach ($duration in $sorted) {
        $total += [double]$duration
    }

    $estimateSeconds = if ($sorted.Count -ge 5) {
        Get-PercentileSeconds -SortedValues $sorted -Percentile 0.95
    } elseif ($sorted.Count -ge 2) {
        [Math]::Round($median, 3)
    } else {
        [Math]::Round([double]$sorted[0], 3)
    }
    $estimateConfidence = if ($sorted.Count -ge 8) {
        'medium'
    } elseif ($sorted.Count -ge 3) {
        'low'
    } else {
        'very-low'
    }

    return [pscustomobject]@{
        comparisonCount = $sorted.Count
        minSeconds      = [Math]::Round([double]$sorted[0], 3)
        medianSeconds   = [Math]::Round([double]$median, 3)
        p95Seconds      = Get-PercentileSeconds -SortedValues $sorted -Percentile 0.95
        totalSeconds    = [Math]::Round([double]$total, 3)
        estimatedCompareTime = [pscustomobject]@{
            seconds     = $estimateSeconds
            source      = 'observed-durations'
            confidence  = $estimateConfidence
            note        = 'Heuristic seed based on observed per-comparison durations.'
        }
    }
}

function Get-PairKpiEnvelope {
    param(
        [AllowNull()]
        [object[]]$Pairs,
        [AllowNull()]
        [object]$TimingSummary,
        [bool]$CommentTruncated = $false,
        [string]$TruncationReason = 'none'
    )

    $pairRows = @($Pairs)
    $diffPairs = 0
    $signalDiffPairs = 0
    $noiseMasscompileDiffPairs = 0
    $noiseCosmeticDiffPairs = 0
    $previewPresentPairs = 0
    $durations = New-Object System.Collections.Generic.List[double]

    foreach ($pair in $pairRows) {
        if (-not $pair) { continue }

        $diffDetected = $false
        if ($pair.PSObject.Properties['diff']) {
            $diffDetected = [bool]$pair.diff
        }

        $classification = 'unknown'
        if ($pair.PSObject.Properties['classification'] -and $pair.classification) {
            $classification = [string]$pair.classification
        }
        $classificationKey = $classification.Trim().ToLowerInvariant()

        if ($diffDetected) {
            $diffPairs++
            switch ($classificationKey) {
                'signal'            { $signalDiffPairs++ }
                'noise-masscompile' { $noiseMasscompileDiffPairs++ }
                'noise-cosmetic'    { $noiseCosmeticDiffPairs++ }
            }
        }

        $previewStatus = if ($pair.PSObject.Properties['previewStatus'] -and $pair.previewStatus) {
            [string]$pair.previewStatus
        } else {
            'unknown'
        }
        if ($previewStatus.Trim().ToLowerInvariant() -eq 'present') {
            $previewPresentPairs++
        }

        if ($pair.PSObject.Properties['durationSeconds']) {
            $durationSeconds = Convert-ToNullableDouble -Value $pair.durationSeconds
            if ($durationSeconds -ne $null -and $durationSeconds -ge 0) {
                $durations.Add([double]$durationSeconds) | Out-Null
            }
        }
    }

    $signalRecall = $null
    if ($diffPairs -gt 0) {
        $signalRecall = [Math]::Round(($signalDiffPairs / [double]$diffPairs), 6)
    }

    $noisePrecisionMasscompile = $null
    $noiseDiffPairs = $noiseMasscompileDiffPairs + $noiseCosmeticDiffPairs
    if ($noiseDiffPairs -gt 0) {
        $noisePrecisionMasscompile = [Math]::Round(($noiseMasscompileDiffPairs / [double]$noiseDiffPairs), 6)
    }

    $previewCoverage = $null
    if ($pairRows.Count -gt 0) {
        $previewCoverage = [Math]::Round(($previewPresentPairs / [double]$pairRows.Count), 6)
    }

    $timingP50Seconds = $null
    $timingP95Seconds = $null
    $sortedDurations = @($durations | Sort-Object)
    if ($sortedDurations.Count -gt 0) {
        $timingP50Seconds = Get-PercentileSeconds -SortedValues $sortedDurations -Percentile 0.5
        $timingP95Seconds = Get-PercentileSeconds -SortedValues $sortedDurations -Percentile 0.95
    } elseif ($TimingSummary) {
        if ($TimingSummary.PSObject.Properties['medianSeconds']) {
            $timingP50Seconds = Convert-ToNullableDouble -Value $TimingSummary.medianSeconds
        }
        if ($TimingSummary.PSObject.Properties['p95Seconds']) {
            $timingP95Seconds = Convert-ToNullableDouble -Value $TimingSummary.p95Seconds
        }
    }

    $normalizedReason = if ([string]::IsNullOrWhiteSpace($TruncationReason)) {
        if ($CommentTruncated) { 'unspecified' } else { 'none' }
    } else {
        $TruncationReason
    }

    return [pscustomobject]@{
        signalRecall             = $signalRecall
        noisePrecisionMasscompile= $noisePrecisionMasscompile
        previewCoverage          = $previewCoverage
        timingP50Seconds         = $timingP50Seconds
        timingP95Seconds         = $timingP95Seconds
        commentTruncated         = [bool]$CommentTruncated
        truncationReason         = $normalizedReason
    }
}

function Resolve-PathBestEffort {
    param(
        [string]$PathValue,
        [string]$PrimaryBase,
        [string]$SecondaryBase
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        $candidates.Add([System.IO.Path]::GetFullPath($PathValue)) | Out-Null
    } else {
        if (-not [string]::IsNullOrWhiteSpace($PrimaryBase)) {
            $candidates.Add([System.IO.Path]::GetFullPath((Join-Path $PrimaryBase $PathValue))) | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($SecondaryBase)) {
            $candidates.Add([System.IO.Path]::GetFullPath((Join-Path $SecondaryBase $PathValue))) | Out-Null
        }
    }

    if ($candidates.Count -eq 0) {
        return $PathValue
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $candidates[0]
}

function Get-ComparisonRefValue {
    param(
        [AllowNull()]$Comparison,
        [ValidateSet('base','head')]
        [string]$Side
    )

    if (-not $Comparison) { return $null }
    if (-not $Comparison.PSObject.Properties[$Side]) { return $null }

    $node = $Comparison.$Side
    if ($node -is [string]) {
        return [string]$node
    }
    if ($node -and $node.PSObject.Properties['ref']) {
        return [string]$node.ref
    }
    return $null
}

function Resolve-PairClassification {
    param(
        [AllowNull()]$ResultNode,
        [bool]$DiffDetected
    )

    $rawClassification = $null
    if ($ResultNode -and $ResultNode.PSObject.Properties['classification']) {
        $rawClassification = [string]$ResultNode.classification
    }
    $normalizedRaw = if ([string]::IsNullOrWhiteSpace($rawClassification)) {
        $null
    } else {
        $rawClassification.Trim().ToLowerInvariant()
    }

    $bucketTokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $categoryTokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if ($ResultNode) {
        if ($ResultNode.PSObject.Properties['bucket'] -and $ResultNode.bucket) {
            [void]$bucketTokens.Add([string]$ResultNode.bucket)
        }
        if ($ResultNode.PSObject.Properties['categoryBuckets'] -and $ResultNode.categoryBuckets -is [System.Collections.IEnumerable]) {
            foreach ($bucket in @($ResultNode.categoryBuckets)) {
                if ([string]::IsNullOrWhiteSpace([string]$bucket)) { continue }
                [void]$bucketTokens.Add([string]$bucket)
            }
        }
        if ($ResultNode.PSObject.Properties['categoryBucketDetails'] -and $ResultNode.categoryBucketDetails -is [System.Collections.IEnumerable]) {
            foreach ($detail in @($ResultNode.categoryBucketDetails)) {
                if (-not $detail) { continue }
                if ($detail.PSObject.Properties['slug'] -and $detail.slug) {
                    [void]$bucketTokens.Add([string]$detail.slug)
                }
            }
        }
        if ($ResultNode.PSObject.Properties['categoryDetails'] -and $ResultNode.categoryDetails -is [System.Collections.IEnumerable]) {
            foreach ($detail in @($ResultNode.categoryDetails)) {
                if (-not $detail) { continue }
                if ($detail.PSObject.Properties['slug'] -and $detail.slug) {
                    [void]$categoryTokens.Add([string]$detail.slug)
                }
                if ($detail.PSObject.Properties['bucketSlug'] -and $detail.bucketSlug) {
                    [void]$bucketTokens.Add([string]$detail.bucketSlug)
                }
                if ($detail.PSObject.Properties['label'] -and $detail.label) {
                    [void]$categoryTokens.Add([string]$detail.label)
                }
            }
        }
        if ($ResultNode.PSObject.Properties['categories'] -and $ResultNode.categories -is [System.Collections.IEnumerable]) {
            foreach ($category in @($ResultNode.categories)) {
                if ([string]::IsNullOrWhiteSpace([string]$category)) { continue }
                [void]$categoryTokens.Add([string]$category)
            }
        }
    }

    $metadataNoise = $false
    if ($bucketTokens.Contains('metadata')) {
        $metadataNoise = $true
    }
    foreach ($token in $categoryTokens) {
        $lower = $token.ToLowerInvariant()
        if ($lower -match 'vi attribute' -or $lower -match 'metadata' -or $lower -match 'masscompile' -or $lower -match 'compile') {
            $metadataNoise = $true
            break
        }
    }

    $cosmeticNoise = $false
    if ($bucketTokens.Contains('ui-visual')) {
        $cosmeticNoise = $true
    }
    foreach ($token in $categoryTokens) {
        $lower = $token.ToLowerInvariant()
        if ($lower -match 'cosmetic' -or $lower -match 'front panel' -or $lower -match 'icon' -or $lower -match 'block diagram cosmetic') {
            $cosmeticNoise = $true
            break
        }
    }

    switch ($normalizedRaw) {
        'signal' { return 'signal' }
        'noise' {
            if ($metadataNoise) { return 'noise-masscompile' }
            if ($cosmeticNoise) { return 'noise-cosmetic' }
            return 'noise-cosmetic'
        }
        'neutral' {
            if ($metadataNoise) { return 'noise-masscompile' }
            if ($cosmeticNoise) { return 'noise-cosmetic' }
            return 'unknown'
        }
    }

    if ($DiffDetected) {
        if ($metadataNoise) { return 'noise-masscompile' }
        if ($cosmeticNoise) { return 'noise-cosmetic' }
    }

    return 'unknown'
}

function Resolve-PreviewStatus {
    param([AllowNull()]$ReportImages)

    if (-not $ReportImages) { return 'skipped' }
    $status = if ($ReportImages.PSObject.Properties['status']) { [string]$ReportImages.status } else { '' }
    switch ($status) {
        'completed' {
            $exported = if ($ReportImages.PSObject.Properties['exportedImageCount']) { [int]$ReportImages.exportedImageCount } else { 0 }
            if ($exported -gt 0) { return 'present' }
            return 'missing'
        }
        'error' { return 'error' }
        'disabled' { return 'skipped' }
        'no-html-report' { return 'skipped' }
        'unavailable' { return 'skipped' }
        default { return 'missing' }
    }
}

function Get-TargetPairTimeline {
    param(
        [AllowNull()]$AggregateManifest,
        [string]$TargetRepoPath,
        [string]$TargetResultsDir,
        [string]$RepoRoot,
        [AllowNull()]$ReportImages
    )

    $pairRows = [System.Collections.Generic.List[object]]::new()
    $durations = [System.Collections.Generic.List[double]]::new()
    if (-not $AggregateManifest) {
        return [pscustomobject]@{
            Pairs     = @()
            Durations = @()
        }
    }

    $modes = @()
    if ($AggregateManifest.PSObject.Properties['modes'] -and $AggregateManifest.modes -is [System.Collections.IEnumerable]) {
        $modes = @($AggregateManifest.modes)
    }
    if ($modes.Count -eq 0) {
        return [pscustomobject]@{
            Pairs     = @()
            Durations = @()
        }
    }

    $previewStatus = Resolve-PreviewStatus -ReportImages $ReportImages
    $imageIndexPath = $null
    if ($ReportImages -and $ReportImages.PSObject.Properties['indexPath']) {
        $imageIndexPath = Resolve-PathBestEffort -PathValue ([string]$ReportImages.indexPath) -PrimaryBase $TargetResultsDir -SecondaryBase $RepoRoot
    }

    foreach ($modeEntry in $modes) {
        if (-not $modeEntry) { continue }

        $modeName = if ($modeEntry.PSObject.Properties['name']) { [string]$modeEntry.name } else { 'default' }
        if ([string]::IsNullOrWhiteSpace($modeName) -and $modeEntry.PSObject.Properties['slug']) {
            $modeName = [string]$modeEntry.slug
        }
        if ([string]::IsNullOrWhiteSpace($modeName)) {
            $modeName = 'default'
        }

        $modeManifestPath = $null
        if ($modeEntry.PSObject.Properties['manifestPath']) {
            $modeManifestPath = Resolve-PathBestEffort -PathValue ([string]$modeEntry.manifestPath) -PrimaryBase $TargetResultsDir -SecondaryBase $RepoRoot
        }
        if ([string]::IsNullOrWhiteSpace($modeManifestPath) -or -not (Test-Path -LiteralPath $modeManifestPath -PathType Leaf)) {
            continue
        }

        $modeManifest = $null
        try {
            $modeManifest = Get-Content -LiteralPath $modeManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if (-not $modeManifest) { continue }

        $comparisons = @()
        if ($modeManifest.PSObject.Properties['comparisons'] -and $modeManifest.comparisons -is [System.Collections.IEnumerable]) {
            $comparisons = @($modeManifest.comparisons)
        }
        if ($comparisons.Count -eq 0) { continue }

        $pairCounter = 0
        foreach ($comparison in $comparisons) {
            if (-not $comparison) { continue }
            $pairCounter++

            $resultNode = if ($comparison.PSObject.Properties['result']) { $comparison.result } else { $null }
            $diffDetected = $false
            if ($resultNode -and $resultNode.PSObject.Properties['diff']) {
                $diffDetected = [bool]$resultNode.diff
            }

            $durationSeconds = $null
            if ($resultNode -and $resultNode.PSObject.Properties['duration_s']) {
                $durationSeconds = Convert-ToNullableDouble -Value $resultNode.duration_s
            }
            if ($durationSeconds -ne $null -and $durationSeconds -ge 0) {
                $durations.Add([double]$durationSeconds) | Out-Null
            }

            $reportPath = $null
            if ($resultNode) {
                if ($resultNode.PSObject.Properties['reportPath'] -and $resultNode.reportPath) {
                    $reportPath = Resolve-PathBestEffort -PathValue ([string]$resultNode.reportPath) -PrimaryBase $TargetResultsDir -SecondaryBase $RepoRoot
                } elseif ($resultNode.PSObject.Properties['reportHtml'] -and $resultNode.reportHtml) {
                    $reportPath = Resolve-PathBestEffort -PathValue ([string]$resultNode.reportHtml) -PrimaryBase $TargetResultsDir -SecondaryBase $RepoRoot
                }
            }

            $pairIndex = if ($comparison.PSObject.Properties['index']) { [int]$comparison.index } else { $pairCounter }
            $pairRows.Add([pscustomobject]@{
                targetPath     = $TargetRepoPath
                mode           = $modeName
                pairIndex      = $pairIndex
                baseRef        = Get-ComparisonRefValue -Comparison $comparison -Side base
                headRef        = Get-ComparisonRefValue -Comparison $comparison -Side head
                diff           = [bool]$diffDetected
                classification = Resolve-PairClassification -ResultNode $resultNode -DiffDetected:$diffDetected
                durationSeconds= $durationSeconds
                previewStatus  = $previewStatus
                reportPath     = $reportPath
                imageIndexPath = $imageIndexPath
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        Pairs     = @($pairRows)
        Durations = @($durations)
    }
}

$resolvedManifest = Resolve-ExistingFile -Path $ManifestPath -Description 'Manifest'
$manifestRaw = Get-Content -LiteralPath $resolvedManifest -Raw -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($manifestRaw)) {
    throw "Manifest file is empty: $resolvedManifest"
}

try {
    $manifest = $manifestRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw ("Manifest is not valid JSON: {0}" -f $_.Exception.Message)
}

if ($manifest.schema -ne 'vi-diff-manifest@v1') {
    throw ("Unexpected manifest schema '{0}'. Expected 'vi-diff-manifest@v1'." -f $manifest.schema)
}

$repoRoot = Get-GitRepoRoot
$pairs = @()
if ($manifest.pairs -is [System.Collections.IEnumerable]) {
    $pairs = @($manifest.pairs)
}

$targetMap = [ordered]@{}
$skippedPairs = [System.Collections.Generic.List[object]]::new()

foreach ($pair in $pairs) {
    if (-not $pair) { continue }
    $basePathRaw = if ($pair.PSObject.Properties['basePath']) { [string]$pair.basePath } else { $null }
    $headPathRaw = if ($pair.PSObject.Properties['headPath']) { [string]$pair.headPath } else { $null }
    $changeType = if ($pair.PSObject.Properties['changeType']) { [string]$pair.changeType } else { 'unknown' }

    $headResolved = Resolve-ViPath -Path $headPathRaw -ParameterName 'headPath' -AllowMissing -RepoRoot $repoRoot
    $baseResolved = Resolve-ViPath -Path $basePathRaw -ParameterName 'basePath' -AllowMissing -RepoRoot $repoRoot

    $chosenResolved = $headResolved
    $chosenLabel = $headPathRaw
    $chosenOrigin = 'head'

    if (-not $chosenResolved) {
        $chosenResolved = $baseResolved
        $chosenLabel = $basePathRaw
        $chosenOrigin = 'base'
    }

    if (-not $chosenResolved) {
        [void]$skippedPairs.Add([pscustomobject]@{
            changeType = $changeType
            basePath   = $basePathRaw
            headPath   = $headPathRaw
            reason     = 'missing-path'
        }) | Out-Null
        continue
    }

    $repoRelative = Get-RepoRelativePath -FullPath $chosenResolved -RepoRoot $repoRoot
    if (-not $repoRelative) {
        $repoRelative = $chosenLabel
    }
    if ([string]::IsNullOrWhiteSpace($repoRelative)) {
        $repoRelative = $chosenResolved
    }

    $key = $repoRelative.ToLowerInvariant()
    if (-not $targetMap.Contains($key)) {
        $entry = [ordered]@{
            repoPath     = $repoRelative
            fullPath     = $chosenResolved
            changeTypes  = [System.Collections.Generic.List[string]]::new()
            basePaths    = [System.Collections.Generic.List[string]]::new()
            headPaths    = [System.Collections.Generic.List[string]]::new()
            pairs        = [System.Collections.Generic.List[object]]::new()
            origin       = $chosenOrigin
        }
        $targetMap[$key] = $entry
    } else {
        $entry = $targetMap[$key]
        if ($entry.origin -ne 'head' -and $chosenOrigin -eq 'head') {
            $entry.origin = 'head'
            $entry.fullPath = $chosenResolved
            $entry.repoPath = $repoRelative
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($changeType) -and -not $entry.changeTypes.Contains($changeType)) {
        [void]$entry.changeTypes.Add($changeType)
    }
    if ($basePathRaw -and -not $entry.basePaths.Contains($basePathRaw)) {
        [void]$entry.basePaths.Add($basePathRaw)
    }
    if ($headPathRaw -and -not $entry.headPaths.Contains($headPathRaw)) {
        [void]$entry.headPaths.Add($headPathRaw)
    }
    [void]$entry.pairs.Add([pscustomobject]@{
        changeType = $changeType
        basePath   = $basePathRaw
        headPath   = $headPathRaw
    }) | Out-Null
}

$targets = @($targetMap.Values)

if ($DryRun.IsPresent) {
    if ($targets.Count -eq 0) {
        Write-Host 'No VI targets resolved from manifest.'
    } else {
        Write-Host 'VI history plan:'
        $rows = $targets | ForEach-Object {
            [pscustomobject]@{
                RepoPath   = $_.repoPath
                ChangeType = [string]::Join(', ', $_.changeTypes)
                Source     = $_.origin
            }
        }
        $rows | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
    }
    return
}

if ($targets.Count -eq 0 -and $skippedPairs.Count -eq 0) {
    Write-Host 'No VI targets to process; exiting.'
    return
}

$resultsRootResolved = if ([System.IO.Path]::IsPathRooted($ResultsRoot)) {
    $ResultsRoot
} else {
    Join-Path $repoRoot $ResultsRoot
}
New-Item -ItemType Directory -Force -Path $resultsRootResolved | Out-Null
$resultsRootResolved = (Resolve-Path -LiteralPath $resultsRootResolved).Path

$effectiveSummaryPath = if ($SummaryPath) {
    if ([System.IO.Path]::IsPathRooted($SummaryPath)) { $SummaryPath } else { Join-Path $repoRoot $SummaryPath }
} else {
    Join-Path $resultsRootResolved 'vi-history-summary.json'
}

$compareScriptPathCandidate = Join-Path (Split-Path -Parent $PSCommandPath) 'Compare-VIHistory.ps1'
try {
    $compareScriptPathResolved = (Resolve-Path -LiteralPath $compareScriptPathCandidate -ErrorAction Stop).ProviderPath
} catch {
    throw ("Unable to locate Compare-VIHistory.ps1 at expected path: {0}" -f $compareScriptPathCandidate)
}
Write-Verbose ("Compare-VIHistory resolved to: {0}" -f $compareScriptPathResolved)

if (-not $CompareInvoker) {
    $compareScriptLiteral = $compareScriptPathResolved.Replace("'", "''")
    $compareInvokerSource = @"
param([hashtable]`$Arguments)
& '$compareScriptLiteral' @Arguments
"@
    $CompareInvoker = [scriptblock]::Create($compareInvokerSource)
}

$extractReportImagesScriptPath = $null
if ($extractReportImagesEnabled) {
    $extractScriptCandidate = Join-Path (Split-Path -Parent $PSCommandPath) 'Extract-VIHistoryReportImages.ps1'
    if (Test-Path -LiteralPath $extractScriptCandidate -PathType Leaf) {
        try {
            $extractReportImagesScriptPath = (Resolve-Path -LiteralPath $extractScriptCandidate -ErrorAction Stop).ProviderPath
        } catch {
            Write-Warning ("Failed to resolve Extract-VIHistoryReportImages helper: {0}" -f $_.Exception.Message)
            $extractReportImagesEnabled = $false
        }
    } else {
        Write-Warning ("Extract-VIHistoryReportImages helper not found at expected path; report image extraction disabled: {0}" -f $extractScriptCandidate)
        $extractReportImagesEnabled = $false
    }
}

$summaryTargets = [System.Collections.Generic.List[object]]::new()
$summaryPairTimeline = [System.Collections.Generic.List[object]]::new()
$errorTargets = [System.Collections.Generic.List[object]]::new()
$totalComparisons = 0
$totalDiffs = 0
$completedCount = 0
$diffTargetCount = 0
$totalPairRows = 0
$diffPairRows = 0
$pairDurations = [System.Collections.Generic.List[double]]::new()
$reportImageTargetCount = 0
$reportImageExportedCount = 0
$reportImageExtractionErrors = 0

for ($i = 0; $i -lt $targets.Count; $i++) {
    $target = $targets[$i]
    $targetFullPath = $target.fullPath
    $repoPath = $target.repoPath
    $sanitized = Sanitize-Token -Value $repoPath
    $targetDirName = ('{0:D2}-{1}' -f ($i + 1), $sanitized)
    $targetResultsDir = Join-Path $resultsRootResolved $targetDirName
    New-Item -ItemType Directory -Force -Path $targetResultsDir | Out-Null

    $effectiveTargetPath = $targetFullPath
    if (-not [string]::IsNullOrWhiteSpace($repoPath) -and -not [System.IO.Path]::IsPathRooted($repoPath)) {
        $effectiveTargetPath = $repoPath
    }

    $compareArgs = @{
        TargetPath = $effectiveTargetPath
        ResultsDir = $targetResultsDir
        OutPrefix  = $sanitized
    }
    Write-Verbose ("[{0}/{1}] Target '{2}' (origin: {3}) -> compare path '{4}'" -f ($i + 1), $targets.Count, $repoPath, $target.origin, $effectiveTargetPath)
    if ($maxPairsRequested) { $compareArgs.MaxPairs = $maxPairsValue }
    if ($compareTimeoutRequested) { $compareArgs.CompareTimeoutSeconds = [int]$compareTimeoutValue }
    if ($Mode) { $compareArgs.Mode = $Mode }
    if (-not [string]::IsNullOrWhiteSpace($StartRef)) { $compareArgs.StartRef = $StartRef }
    if (-not [string]::IsNullOrWhiteSpace($EndRef)) { $compareArgs.EndRef = $EndRef }
    if (-not $SkipRenderReport.IsPresent) { $compareArgs.RenderReport = $true }
    if ($IncludeMergeParents.IsPresent) { $compareArgs.IncludeMergeParents = $true }

    $compareArgs.FlagNoAttr = $false
    $compareArgs.FlagNoFp = $false
    $compareArgs.FlagNoFpPos = $false
    $compareArgs.FlagNoBdCosm = $false
    $compareArgs.ForceNoBd = $false

    if ($historyReplaceFlags -eq $true) {
        $compareArgs.ReplaceFlags = $true
        if ($historyFlagString) {
            $compareArgs.LvCompareArgs = $historyFlagString
        }
    } elseif ($historyReplaceFlags -eq $false) {
        if ($historyFlagString) {
            $compareArgs.AdditionalFlags = $historyFlagString
        }
    } elseif ($historyFlagString) {
        $compareArgs.ReplaceFlags = $true
        $compareArgs.LvCompareArgs = $historyFlagString
    }

    try {
        & $CompareInvoker $compareArgs | Out-Null
    } catch {
        $caughtError = $_
        $errorTiming = New-TimingSummary -DurationsSeconds @()
        [void]$errorTargets.Add([pscustomobject]@{
            repoPath = $repoPath
            message  = $caughtError.Exception.Message
        }) | Out-Null
        [void]$summaryTargets.Add([pscustomobject]@{
            repoPath    = $repoPath
            status      = 'error'
            message     = $caughtError.Exception.Message
            changeTypes = $target.changeTypes.ToArray()
            basePaths   = $target.basePaths.ToArray()
            headPaths   = $target.headPaths.ToArray()
            resultsDir  = $targetResultsDir
            commitPairs = @()
            timing      = $errorTiming
            estimatedCompareTime = $errorTiming.estimatedCompareTime
        }) | Out-Null
        continue
    }

    $manifestPath = Join-Path $targetResultsDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $errorMessage = "manifest.json not produced for $repoPath"
        $errorTiming = New-TimingSummary -DurationsSeconds @()
        [void]$errorTargets.Add([pscustomobject]@{
            repoPath = $repoPath
            message  = $errorMessage
        }) | Out-Null
        [void]$summaryTargets.Add([pscustomobject]@{
            repoPath    = $repoPath
            status      = 'error'
            message     = $errorMessage
            changeTypes = $target.changeTypes.ToArray()
            basePaths   = $target.basePaths.ToArray()
            headPaths   = $target.headPaths.ToArray()
            resultsDir  = $targetResultsDir
            commitPairs = @()
            timing      = $errorTiming
            estimatedCompareTime = $errorTiming.estimatedCompareTime
        }) | Out-Null
        continue
    }

    $aggregateRaw = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
    $aggregate = $null
    try {
        $aggregate = $aggregateRaw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $aggregate = $null
    }

    $stats = $null
    if ($aggregate -and $aggregate.PSObject.Properties['stats']) {
        $stats = $aggregate.stats
    }
    $processed = if ($stats -and $stats.PSObject.Properties['processed']) { [int]$stats.processed } else { 0 }
    $diffs = if ($stats -and $stats.PSObject.Properties['diffs']) { [int]$stats.diffs } else { 0 }
    $missing = if ($stats -and $stats.PSObject.Properties['missing']) { [int]$stats.missing } else { 0 }

    $totalComparisons += $processed
    $totalDiffs += $diffs
    $completedCount++
    if ($diffs -gt 0) { $diffTargetCount++ }

    $reportMarkdown = Join-Path $targetResultsDir 'history-report.md'
    if (-not (Test-Path -LiteralPath $reportMarkdown -PathType Leaf)) {
        $reportMarkdown = $null
    }
    $reportHtml = Join-Path $targetResultsDir 'history-report.html'
    if (-not (Test-Path -LiteralPath $reportHtml -PathType Leaf)) {
        $reportHtml = $null
    }

    $reportImages = [ordered]@{
        status             = if ($reportHtml) { 'not-run' } else { 'no-html-report' }
        indexPath          = $null
        outputDir          = $null
        sourceImageCount   = 0
        exportedImageCount = 0
        error              = $null
    }

    if ($reportHtml) {
        if (-not $extractReportImagesEnabled) {
            $reportImages.status = 'disabled'
        } elseif ([string]::IsNullOrWhiteSpace($extractReportImagesScriptPath)) {
            $reportImages.status = 'unavailable'
            $reportImages.error = 'Extractor script path not resolved.'
            $reportImageExtractionErrors++
        } else {
            try {
                $imageOutputDir = Join-Path $targetResultsDir 'previews'
                $imageIndexPath = Join-Path $targetResultsDir 'vi-history-image-index.json'
                $extractResult = & $extractReportImagesScriptPath `
                    -ReportPath $reportHtml `
                    -OutputDir $imageOutputDir `
                    -IndexPath $imageIndexPath

                $reportImages.status = 'completed'
                if ($extractResult -and $extractResult.PSObject.Properties['sourceImageCount']) {
                    $reportImages.sourceImageCount = [int]$extractResult.sourceImageCount
                }
                if ($extractResult -and $extractResult.PSObject.Properties['exportedImageCount']) {
                    $reportImages.exportedImageCount = [int]$extractResult.exportedImageCount
                }

                if (Test-Path -LiteralPath $imageIndexPath -PathType Leaf) {
                    $reportImages.indexPath = (Resolve-Path -LiteralPath $imageIndexPath).Path
                }
                if (Test-Path -LiteralPath $imageOutputDir -PathType Container) {
                    $reportImages.outputDir = (Resolve-Path -LiteralPath $imageOutputDir).Path
                }

                $reportImageExportedCount += [int]$reportImages.exportedImageCount
                if ([int]$reportImages.exportedImageCount -gt 0) {
                    $reportImageTargetCount++
                }
            } catch {
                $reportImages.status = 'error'
                $reportImages.error = $_.Exception.Message
                $reportImageExtractionErrors++
                Write-Warning ("Failed to extract report images for '{0}': {1}" -f $repoPath, $_.Exception.Message)
            }
        }

        if ($reportImages.status -eq 'completed' -and [int]$reportImages.exportedImageCount -le 0) {
            try {
                $cliImageCandidates = @(Get-ChildItem -LiteralPath $targetResultsDir -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'cli-image-*' -and $_.FullName -match '[\\/]+cli-images[\\/]' } |
                    Sort-Object FullName)
                Write-Host ("[report-images] fallback scan for '{0}' found {1} CLI image candidate(s)." -f $repoPath, $cliImageCandidates.Count)
                if ($cliImageCandidates.Count -gt 0) {
                    $imageOutputDir = Join-Path $targetResultsDir 'previews'
                    $imageIndexPath = Join-Path $targetResultsDir 'vi-history-image-index.json'
                    New-Item -ItemType Directory -Path $imageOutputDir -Force | Out-Null

                    $fallbackImages = New-Object System.Collections.Generic.List[object]
                    $copiedCount = 0
                    foreach ($candidate in $cliImageCandidates) {
                        if (-not $candidate) { continue }
                        $extension = $candidate.Extension
                        if ([string]::IsNullOrWhiteSpace($extension)) {
                            $extension = '.png'
                        }
                        $extension = $extension.Trim().TrimStart('.').ToLowerInvariant()
                        if ([string]::IsNullOrWhiteSpace($extension)) {
                            $extension = 'png'
                        }

                        $fileName = ('history-image-{0:D3}.{1}' -f $copiedCount, $extension)
                        $destinationPath = Join-Path $imageOutputDir $fileName
                        Copy-Item -LiteralPath $candidate.FullName -Destination $destinationPath -Force
                        $resolvedSavedPath = (Resolve-Path -LiteralPath $destinationPath).Path
                        $fallbackImages.Add([pscustomobject]@{
                            index      = $copiedCount
                            source     = $candidate.FullName
                            sourceType = 'cli-images'
                            alt        = 'VI diff preview'
                            fileName   = $fileName
                            savedPath  = $resolvedSavedPath
                            byteLength = [int64]$candidate.Length
                            status     = 'saved'
                        }) | Out-Null
                        $copiedCount++
                    }

                    $resolvedOutputDir = (Resolve-Path -LiteralPath $imageOutputDir).Path
                    $fallbackIndex = [pscustomobject]@{
                        schema             = 'pr-vi-history-image-index@v1'
                        generatedAt        = (Get-Date).ToString('o')
                        reportPath         = $reportHtml
                        outputDir          = $resolvedOutputDir
                        sourceImageCount   = $cliImageCandidates.Count
                        exportedImageCount = $copiedCount
                        images             = @($fallbackImages.ToArray())
                    }
                    $fallbackIndex | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $imageIndexPath -Encoding utf8

                    $reportImages.sourceImageCount = [int]$cliImageCandidates.Count
                    $reportImages.exportedImageCount = [int]$copiedCount
                    $reportImages.indexPath = (Resolve-Path -LiteralPath $imageIndexPath).Path
                    $reportImages.outputDir = $resolvedOutputDir
                    $reportImages.source = 'cli-images-fallback'

                    $reportImageExportedCount += [int]$copiedCount
                    if ($copiedCount -gt 0) {
                        $reportImageTargetCount++
                    }
                    Write-Host ("[report-images] fallback exported {0} preview image(s) for '{1}'." -f $copiedCount, $repoPath)
                }
            } catch {
                Write-Warning ("Failed CLI-image fallback extraction for '{0}': {1}" -f $repoPath, $_.Exception.Message)
            }
        }
    }

    $targetTimeline = Get-TargetPairTimeline `
        -AggregateManifest $aggregate `
        -TargetRepoPath $repoPath `
        -TargetResultsDir $targetResultsDir `
        -RepoRoot $repoRoot `
        -ReportImages ([pscustomobject]$reportImages)
    $targetPairs = @($targetTimeline.Pairs)
    $targetDurations = @($targetTimeline.Durations)
    $targetTiming = New-TimingSummary -DurationsSeconds $targetDurations

    $totalPairRows += $targetPairs.Count
    foreach ($pairRow in $targetPairs) {
        if (-not $pairRow) { continue }
        $summaryPairTimeline.Add($pairRow) | Out-Null
        if ($pairRow.PSObject.Properties['diff'] -and [bool]$pairRow.diff) {
            $diffPairRows++
        }
    }
    foreach ($durationValue in $targetDurations) {
        $candidateDuration = Convert-ToNullableDouble -Value $durationValue
        if ($candidateDuration -eq $null) { continue }
        if ($candidateDuration -lt 0) { continue }
        $pairDurations.Add([double]$candidateDuration) | Out-Null
    }

    [void]$summaryTargets.Add([pscustomobject]@{
        repoPath    = $repoPath
        status      = 'completed'
        changeTypes = $target.changeTypes.ToArray()
        basePaths   = $target.basePaths.ToArray()
        headPaths   = $target.headPaths.ToArray()
        resultsDir  = $targetResultsDir
        manifest    = $manifestPath
        reportMd    = $reportMarkdown
        reportHtml  = $reportHtml
        reportImages= [pscustomobject]$reportImages
        commitPairs = $targetPairs
        timing      = $targetTiming
        estimatedCompareTime = $targetTiming.estimatedCompareTime
        stats       = [pscustomobject]@{
            processed = $processed
            diffs     = $diffs
            missing   = $missing
        }
    }) | Out-Null
}

foreach ($skipped in $skippedPairs) {
    $skippedTiming = New-TimingSummary -DurationsSeconds @()
    [void]$summaryTargets.Add([pscustomobject]@{
        repoPath    = if ($skipped.headPath) { $skipped.headPath } elseif ($skipped.basePath) { $skipped.basePath } else { '(unknown)' }
        status      = 'skipped'
        message     = 'Manifest entry missing base/head path on disk.'
        changeTypes = @($skipped.changeType)
        basePaths   = @($skipped.basePath)
        headPaths   = @($skipped.headPath)
        commitPairs = @()
        timing      = $skippedTiming
        estimatedCompareTime = $skippedTiming.estimatedCompareTime
    }) | Out-Null
}

$pairTimelineRows = @($summaryPairTimeline)
$overallTiming = New-TimingSummary -DurationsSeconds @($pairDurations)
$kpiEnvelope = Get-PairKpiEnvelope -Pairs $pairTimelineRows -TimingSummary $overallTiming -CommentTruncated:$false -TruncationReason 'none'

$summary = [pscustomobject]@{
    schema      = 'pr-vi-history-summary@v1'
    generatedAt = (Get-Date).ToString('o')
    manifest    = $resolvedManifest
    resultsRoot = $resultsRootResolved
    maxPairs    = if ($maxPairsRequested) { $maxPairsValue } else { $null }
    modes       = if ($Mode) { @($Mode) } else { $null }
    totals      = [pscustomobject]@{
        targets          = $summaryTargets.Count
        completed        = $completedCount
        diffTargets      = $diffTargetCount
        comparisons      = $totalComparisons
        diffs            = $totalDiffs
        errors           = $errorTargets.Count
        skippedEntries   = $skippedPairs.Count
        imageTargets     = $reportImageTargetCount
        extractedImages  = $reportImageExportedCount
        imageErrors      = $reportImageExtractionErrors
        pairRows         = $totalPairRows
        diffPairRows     = $diffPairRows
        timing           = $overallTiming
        estimatedCompareTime = $overallTiming.estimatedCompareTime
    }
    targets     = $summaryTargets
    pairTimeline= $pairTimelineRows
    timing      = $overallTiming
    estimatedCompareTime = $overallTiming.estimatedCompareTime
    kpi         = $kpiEnvelope
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $effectiveSummaryPath -Encoding utf8

if ($Env:GITHUB_OUTPUT) {
    "summary_path=$effectiveSummaryPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "results_root=$resultsRootResolved"  | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "target_count=$($summary.totals.targets)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "completed_count=$completedCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_target_count=$diffTargetCount" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "comparison_count=$totalComparisons" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_count=$totalDiffs" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "error_count=$($errorTargets.Count)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "pair_row_count=$totalPairRows" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_pair_count=$diffPairRows" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

if ($errorTargets.Count -gt 0) {
    $messages = $errorTargets | ForEach-Object { "{0}: {1}" -f $_.repoPath, $_.message }
    $message = "VI history execution failed for {0} target(s): {1}" -f $errorTargets.Count, ($messages -join '; ')
    throw $message
}

return $summary
