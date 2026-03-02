#Requires -Version 7.0
<#
.SYNOPSIS
  Builds KPI benchmark + delta artifacts from a VI history smoke summary.

.DESCRIPTION
  Reads `vi-history-smoke-*.json` output from `tools/Test-PRVIHistorySmoke.ps1`,
  emits a benchmark artifact (`vi-history-benchmark@v1`), computes deltas
  against a rolling baseline for the same scenario, and writes a markdown block
  that can be posted to PR/issue evidence comments.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SmokeSummaryPath,

    [string]$BenchmarksDir = 'tests/results/_agent/smoke/vi-history/benchmarks',

    [ValidateRange(1, 50)]
    [int]$BaselineWindow = 5,

    [string]$BenchmarkPath,

    [string]$DeltaPath,

    [string]$CommentPath,

    [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Convert-ToNullableInt {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    try {
        return [int]$Value
    } catch {
        return $null
    }
}

function Get-MapIntValue {
    param(
        [AllowNull()]$Map,
        [string]$Key
    )

    if (-not $Map -or [string]::IsNullOrWhiteSpace($Key)) { return 0 }

    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($entry in $Map.GetEnumerator()) {
            if ([string]::Equals([string]$entry.Key, $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = Convert-ToNullableInt -Value $entry.Value
                if ($null -ne $value) { return $value }
                return 0
            }
        }
        return 0
    }

    foreach ($property in $Map.PSObject.Properties) {
        if ([string]::Equals([string]$property.Name, $Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = Convert-ToNullableInt -Value $property.Value
            if ($null -ne $value) { return $value }
            return 0
        }
    }

    return 0
}

function Get-Percent {
    param(
        [int]$Numerator,
        [int]$Denominator
    )

    if ($Denominator -le 0) { return $null }
    return [Math]::Round(($Numerator / [double]$Denominator), 6)
}

function Get-AverageNullable {
    param(
        [AllowNull()]
        [double[]]$Values
    )

    $clean = @()
    if ($Values) {
        foreach ($value in $Values) {
            if ($null -eq $value) { continue }
            if ([double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value)) { continue }
            $clean += [double]$value
        }
    }
    if ($clean.Count -eq 0) { return $null }

    $sum = 0.0
    foreach ($value in $clean) { $sum += $value }
    return [Math]::Round(($sum / [double]$clean.Count), 6)
}

function Format-Delta {
    param([AllowNull()][double]$Value)
    if ($null -eq $Value) { return '_n/a_' }
    if ($Value -gt 0) { return ("+{0}" -f ([Math]::Round($Value, 6))) }
    return ([Math]::Round($Value, 6)).ToString()
}

$resolvedSummaryPath = Resolve-ExistingFile -Path $SmokeSummaryPath -Description 'Smoke summary'
$summary = Get-Content -LiteralPath $resolvedSummaryPath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 -ErrorAction Stop

$summaryDir = Split-Path -Parent $resolvedSummaryPath
if ([string]::IsNullOrWhiteSpace($BenchmarksDir)) {
    $BenchmarksDir = Join-Path $summaryDir 'benchmarks'
}
if (-not [System.IO.Path]::IsPathRooted($BenchmarksDir)) {
    $BenchmarksDir = Join-Path $summaryDir $BenchmarksDir
}
if (-not (Test-Path -LiteralPath $BenchmarksDir -PathType Container)) {
    New-Item -ItemType Directory -Path $BenchmarksDir -Force | Out-Null
}
$BenchmarksDir = (Resolve-Path -LiteralPath $BenchmarksDir).Path

$timestamp = (Get-Date).ToString('yyyyMMddHHmmss')
if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) {
    $BenchmarkPath = Join-Path $BenchmarksDir ("vi-history-benchmark-{0}.json" -f $timestamp)
}
if ([string]::IsNullOrWhiteSpace($DeltaPath)) {
    $DeltaPath = Join-Path $BenchmarksDir ("vi-history-benchmark-delta-{0}.json" -f $timestamp)
}
if ([string]::IsNullOrWhiteSpace($CommentPath)) {
    $CommentPath = Join-Path $BenchmarksDir ("vi-history-benchmark-delta-{0}.md" -f $timestamp)
}

$pairTimeline = @()
if ($summary.PSObject.Properties['PairTimeline'] -and $summary.PairTimeline -is [System.Collections.IEnumerable]) {
    $pairTimeline = @($summary.PairTimeline)
}

$pairClassification = if ($summary.PSObject.Properties['PairClassification']) { $summary.PairClassification } else { $null }
$pairTiming = if ($summary.PSObject.Properties['PairTiming']) { $summary.PairTiming } else { $null }

$signalPairs = Get-MapIntValue -Map $pairClassification -Key 'signal'
$noiseMasscompilePairs = Get-MapIntValue -Map $pairClassification -Key 'noise-masscompile'
$noiseCosmeticPairs = Get-MapIntValue -Map $pairClassification -Key 'noise-cosmetic'
$unknownPairs = Get-MapIntValue -Map $pairClassification -Key 'unknown'

$pairTotal = if ($pairTiming -and $pairTiming.PSObject.Properties['comparisonCount']) {
    [Math]::Max(0, (Convert-ToNullableInt -Value $pairTiming.comparisonCount))
} else {
    $pairTimeline.Count
}
$diffs = if ($summary.PSObject.Properties['Diffs']) { [Math]::Max(0, (Convert-ToNullableInt -Value $summary.Diffs)) } else { 0 }
$comparisons = if ($summary.PSObject.Properties['Comparisons']) { [Math]::Max(0, (Convert-ToNullableInt -Value $summary.Comparisons)) } else { $pairTotal }

$previewPresentPairs = 0
foreach ($pair in $pairTimeline) {
    if (-not $pair) { continue }
    if ($pair.PSObject.Properties['previewStatus'] -and [string]$pair.previewStatus -eq 'present') {
        $previewPresentPairs++
    }
}
$previewCoverage = Get-Percent -Numerator $previewPresentPairs -Denominator $pairTotal

$timingTotalSeconds = if ($pairTiming -and $pairTiming.PSObject.Properties['totalSeconds']) { Convert-ToNullableDouble -Value $pairTiming.totalSeconds } else { $null }
$timingP50Seconds = if ($pairTiming -and $pairTiming.PSObject.Properties['p50Seconds']) { Convert-ToNullableDouble -Value $pairTiming.p50Seconds } else { $null }
$timingP95Seconds = if ($pairTiming -and $pairTiming.PSObject.Properties['p95Seconds']) { Convert-ToNullableDouble -Value $pairTiming.p95Seconds } else { $null }

$commentTruncated = if ($summary.PSObject.Properties['CommentTruncated']) { [bool]$summary.CommentTruncated } else { $false }
$truncationReason = if ($summary.PSObject.Properties['TruncationReason'] -and $summary.TruncationReason) { [string]$summary.TruncationReason } else { 'none' }

$benchmark = [ordered]@{
    schema           = 'vi-history-benchmark@v1'
    generatedAt      = (Get-Date).ToString('o')
    sourceSummaryPath= $resolvedSummaryPath
    scenario         = if ($summary.PSObject.Properties['Scenario']) { [string]$summary.Scenario } else { 'unknown' }
    runId            = if ($summary.PSObject.Properties['RunId']) { Convert-ToNullableInt -Value $summary.RunId } else { $null }
    prNumber         = if ($summary.PSObject.Properties['PrNumber']) { Convert-ToNullableInt -Value $summary.PrNumber } else { $null }
    success          = if ($summary.PSObject.Properties['Success']) { [bool]$summary.Success } else { $false }
    metrics          = [ordered]@{
        pairCounts = [ordered]@{
            total            = $pairTotal
            signal           = $signalPairs
            noiseMasscompile = $noiseMasscompilePairs
            noiseCosmetic    = $noiseCosmeticPairs
            unknown          = $unknownPairs
            comparisons      = $comparisons
            diffs            = $diffs
        }
        timing = [ordered]@{
            totalSeconds = $timingTotalSeconds
            p50Seconds   = $timingP50Seconds
            p95Seconds   = $timingP95Seconds
        }
        previewCoverage = $previewCoverage
        truncation = [ordered]@{
            commentTruncated = $commentTruncated
            reason           = $truncationReason
        }
    }
}

$benchmark | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $BenchmarkPath -Encoding utf8
$resolvedBenchmarkPath = (Resolve-Path -LiteralPath $BenchmarkPath).Path

$allBenchmarkFiles = @(Get-ChildItem -LiteralPath $BenchmarksDir -Filter 'vi-history-benchmark-*.json' -File |
    Sort-Object LastWriteTimeUtc -Descending)

$baselineBenchmarks = New-Object System.Collections.Generic.List[object]
foreach ($file in $allBenchmarkFiles) {
    if ([System.StringComparer]::OrdinalIgnoreCase.Equals($file.FullName, $resolvedBenchmarkPath)) { continue }
    try {
        $candidate = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12 -ErrorAction Stop
    } catch {
        continue
    }
    if (-not $candidate) { continue }
    if (-not $candidate.PSObject.Properties['scenario']) { continue }
    if (-not [string]::Equals([string]$candidate.scenario, [string]$benchmark.scenario, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not ($candidate.PSObject.Properties['success'] -and [bool]$candidate.success)) { continue }
    $baselineBenchmarks.Add($candidate) | Out-Null
    if ($baselineBenchmarks.Count -ge $BaselineWindow) { break }
}

$baselineCount = $baselineBenchmarks.Count
$baselinePairTotal = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.pairCounts.total })
$baselineSignal = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.pairCounts.signal })
$baselineNoiseMasscompile = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.pairCounts.noiseMasscompile })
$baselinePreviewCoverage = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.previewCoverage })
$baselineP50 = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.timing.p50Seconds })
$baselineP95 = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.timing.p95Seconds })
$baselineTotalSeconds = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object { Convert-ToNullableDouble -Value $_.metrics.timing.totalSeconds })
$baselineTruncationRate = Get-AverageNullable -Values @($baselineBenchmarks | ForEach-Object {
        if ($_.metrics.truncation.commentTruncated) { 1.0 } else { 0.0 }
    })

$currentPairTotal = Convert-ToNullableDouble -Value $benchmark.metrics.pairCounts.total
$currentSignal = Convert-ToNullableDouble -Value $benchmark.metrics.pairCounts.signal
$currentNoiseMasscompile = Convert-ToNullableDouble -Value $benchmark.metrics.pairCounts.noiseMasscompile
$currentPreviewCoverage = Convert-ToNullableDouble -Value $benchmark.metrics.previewCoverage
$currentP50 = Convert-ToNullableDouble -Value $benchmark.metrics.timing.p50Seconds
$currentP95 = Convert-ToNullableDouble -Value $benchmark.metrics.timing.p95Seconds
$currentTotalSeconds = Convert-ToNullableDouble -Value $benchmark.metrics.timing.totalSeconds
$currentTruncationRate = if ($benchmark.metrics.truncation.commentTruncated) { 1.0 } else { 0.0 }

$delta = [ordered]@{
    schema       = 'vi-history-benchmark-delta@v1'
    generatedAt  = (Get-Date).ToString('o')
    currentPath  = $resolvedBenchmarkPath
    baselineWindow = $BaselineWindow
    baselineCount  = $baselineCount
    status       = if ($baselineCount -gt 0) { 'ready' } else { 'insufficient-baseline' }
    current      = [ordered]@{
        pairTotal            = $currentPairTotal
        signalPairs          = $currentSignal
        noiseMasscompilePairs= $currentNoiseMasscompile
        previewCoverage      = $currentPreviewCoverage
        timingP50Seconds     = $currentP50
        timingP95Seconds     = $currentP95
        timingTotalSeconds   = $currentTotalSeconds
        truncationRate       = $currentTruncationRate
    }
    baseline     = [ordered]@{
        pairTotal            = $baselinePairTotal
        signalPairs          = $baselineSignal
        noiseMasscompilePairs= $baselineNoiseMasscompile
        previewCoverage      = $baselinePreviewCoverage
        timingP50Seconds     = $baselineP50
        timingP95Seconds     = $baselineP95
        timingTotalSeconds   = $baselineTotalSeconds
        truncationRate       = $baselineTruncationRate
    }
    delta        = [ordered]@{
        pairTotal            = if ($baselineCount -gt 0 -and $null -ne $currentPairTotal -and $null -ne $baselinePairTotal) { [Math]::Round($currentPairTotal - $baselinePairTotal, 6) } else { $null }
        signalPairs          = if ($baselineCount -gt 0 -and $null -ne $currentSignal -and $null -ne $baselineSignal) { [Math]::Round($currentSignal - $baselineSignal, 6) } else { $null }
        noiseMasscompilePairs= if ($baselineCount -gt 0 -and $null -ne $currentNoiseMasscompile -and $null -ne $baselineNoiseMasscompile) { [Math]::Round($currentNoiseMasscompile - $baselineNoiseMasscompile, 6) } else { $null }
        previewCoverage      = if ($baselineCount -gt 0 -and $null -ne $currentPreviewCoverage -and $null -ne $baselinePreviewCoverage) { [Math]::Round($currentPreviewCoverage - $baselinePreviewCoverage, 6) } else { $null }
        timingP50Seconds     = if ($baselineCount -gt 0 -and $null -ne $currentP50 -and $null -ne $baselineP50) { [Math]::Round($currentP50 - $baselineP50, 6) } else { $null }
        timingP95Seconds     = if ($baselineCount -gt 0 -and $null -ne $currentP95 -and $null -ne $baselineP95) { [Math]::Round($currentP95 - $baselineP95, 6) } else { $null }
        timingTotalSeconds   = if ($baselineCount -gt 0 -and $null -ne $currentTotalSeconds -and $null -ne $baselineTotalSeconds) { [Math]::Round($currentTotalSeconds - $baselineTotalSeconds, 6) } else { $null }
        truncationRate       = if ($baselineCount -gt 0 -and $null -ne $baselineTruncationRate) { [Math]::Round($currentTruncationRate - $baselineTruncationRate, 6) } else { $null }
    }
}

$delta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $DeltaPath -Encoding utf8
$resolvedDeltaPath = (Resolve-Path -LiteralPath $DeltaPath).Path

$commentLines = New-Object System.Collections.Generic.List[string]
$commentLines.Add('### VI History KPI Delta') | Out-Null
$commentLines.Add('') | Out-Null
if ($baselineCount -gt 0) {
    $commentLines.Add(('- Scenario: `{0}` | Baseline window: {1} run(s)' -f $benchmark.scenario, $baselineCount)) | Out-Null
    $commentLines.Add('') | Out-Null
    $commentLines.Add('| Metric | Current | Baseline | Delta |') | Out-Null
    $commentLines.Add('| --- | --- | --- | --- |') | Out-Null
    $commentLines.Add(('| Pair Total | {0} | {1} | {2} |' -f $currentPairTotal, $baselinePairTotal, (Format-Delta -Value $delta.delta.pairTotal))) | Out-Null
    $commentLines.Add(('| Signal Pairs | {0} | {1} | {2} |' -f $currentSignal, $baselineSignal, (Format-Delta -Value $delta.delta.signalPairs))) | Out-Null
    $commentLines.Add(('| Noise-Masscompile Pairs | {0} | {1} | {2} |' -f $currentNoiseMasscompile, $baselineNoiseMasscompile, (Format-Delta -Value $delta.delta.noiseMasscompilePairs))) | Out-Null
    $commentLines.Add(('| Preview Coverage | {0} | {1} | {2} |' -f $currentPreviewCoverage, $baselinePreviewCoverage, (Format-Delta -Value $delta.delta.previewCoverage))) | Out-Null
    $commentLines.Add(('| Timing P50 (s) | {0} | {1} | {2} |' -f $currentP50, $baselineP50, (Format-Delta -Value $delta.delta.timingP50Seconds))) | Out-Null
    $commentLines.Add(('| Timing P95 (s) | {0} | {1} | {2} |' -f $currentP95, $baselineP95, (Format-Delta -Value $delta.delta.timingP95Seconds))) | Out-Null
    $commentLines.Add(('| Timing Total (s) | {0} | {1} | {2} |' -f $currentTotalSeconds, $baselineTotalSeconds, (Format-Delta -Value $delta.delta.timingTotalSeconds))) | Out-Null
    $commentLines.Add(('| Truncation Rate | {0} | {1} | {2} |' -f $currentTruncationRate, $baselineTruncationRate, (Format-Delta -Value $delta.delta.truncationRate))) | Out-Null
} else {
    $commentLines.Add(('- Scenario: `{0}`' -f $benchmark.scenario)) | Out-Null
    $commentLines.Add('') | Out-Null
    $commentLines.Add('_Baseline unavailable (need at least one previous successful benchmark for this scenario)._') | Out-Null
}
$commentLines.Add('') | Out-Null
$commentLines.Add(('- Benchmark JSON: `{0}`' -f $resolvedBenchmarkPath)) | Out-Null
$commentLines.Add(('- Delta JSON: `{0}`' -f $resolvedDeltaPath)) | Out-Null
$commentMarkdown = $commentLines -join [Environment]::NewLine

$commentMarkdown | Set-Content -LiteralPath $CommentPath -Encoding utf8
$resolvedCommentPath = (Resolve-Path -LiteralPath $CommentPath).Path

$result = [pscustomobject]@{
    benchmarkPath = $resolvedBenchmarkPath
    deltaPath     = $resolvedDeltaPath
    commentPath   = $resolvedCommentPath
    baselineCount = $baselineCount
    deltaStatus   = [string]$delta.status
    commentMarkdown = $commentMarkdown
}

if ($GitHubOutputPath) {
    "benchmark_path=$resolvedBenchmarkPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
    "delta_path=$resolvedDeltaPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
    "comment_path=$resolvedCommentPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
    "baseline_count=$baselineCount" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
    "delta_status=$($delta.status)" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

return $result
