#Requires -Version 7.0
<#
.SYNOPSIS
  Builds a Markdown summary from pr-vi-history-summary@v1 payloads.

.DESCRIPTION
  Reads the JSON summary emitted by Invoke-PRVIHistory.ps1 and produces a
  compact Markdown table suitable for PR comments or workflow step summaries.
  The helper also returns structured totals so callers can surface diff counts
  alongside the table when needed.

.PARAMETER SummaryPath
  Path to the `pr-vi-history-summary@v1` JSON file.

.PARAMETER MarkdownPath
  Optional path where the rendered Markdown should be written.

.PARAMETER OutputJsonPath
  Optional path for persisting the enriched summary object (totals, targets,
  markdown). When omitted the object is returned without writing a file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SummaryPath,

    [string]$MarkdownPath,

    [string]$OutputJsonPath,

    [ValidateRange(0, 50)]
    [int]$MaxPreviewImages = 6,

    [ValidateRange(500, 65535)]
    [int]$MaxMarkdownLength = 55000
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

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return $TargetPath
    }

    try {
        $rel = [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
        if ([string]::IsNullOrWhiteSpace($rel)) { return $TargetPath }
        return $rel.Replace('\','/')
    } catch {
        return $TargetPath
    }
}

function Get-MobilePreviewEntries {
    param(
        [object[]]$Targets,
        [string]$ResultsRoot,
        [int]$MaxPerTarget = 1
    )

    $entries = New-Object System.Collections.Generic.List[object]
    if (-not $Targets) { return $entries }

    foreach ($target in $Targets) {
        if (-not $target) { continue }
        if (-not ($target.PSObject.Properties['reportImages'] -and $target.reportImages)) { continue }

        $reportImages = $target.reportImages
        $status = if ($reportImages.PSObject.Properties['status']) { [string]$reportImages.status } else { $null }
        if ($status -ne 'completed') { continue }

        $indexPath = if ($reportImages.PSObject.Properties['indexPath']) { [string]$reportImages.indexPath } else { $null }
        if ([string]::IsNullOrWhiteSpace($indexPath)) { continue }
        if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { continue }

        $indexPayload = $null
        try {
            $indexPayload = Get-Content -LiteralPath $indexPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        if (-not $indexPayload) { continue }

        $images = @()
        if ($indexPayload.PSObject.Properties['images'] -and $indexPayload.images -is [System.Collections.IEnumerable]) {
            $images = @($indexPayload.images | Where-Object {
                $_ -and $_.PSObject.Properties['status'] -and $_.status -eq 'saved' -and $_.PSObject.Properties['savedPath'] -and $_.savedPath
            })
        }
        if ($images.Count -eq 0) { continue }

        $takeCount = [Math]::Min($MaxPerTarget, $images.Count)
        for ($i = 0; $i -lt $takeCount; $i++) {
            $img = $images[$i]
            $savedPath = [string]$img.savedPath
            $relativePath = Get-RelativePath -BasePath $ResultsRoot -TargetPath $savedPath
            $altText = if ($img.PSObject.Properties['alt'] -and $img.alt) {
                [string]$img.alt
            } else {
                'preview'
            }
            $repoPath = if ($target.PSObject.Properties['repoPath']) { [string]$target.repoPath } else { '(unknown)' }

            $entries.Add([pscustomobject]@{
                repoPath   = $repoPath
                alt        = $altText
                path       = $relativePath
                sourcePath = $savedPath
            }) | Out-Null
        }
    }

    return $entries
}

function Get-ShortRef {
    param([string]$Ref)
    if ([string]::IsNullOrWhiteSpace($Ref)) { return $null }
    $value = $Ref.Trim()
    if ($value.Length -le 12) { return $value }
    return $value.Substring(0, 12)
}

function Get-DurationDisplay {
    param([AllowNull()]$Seconds)
    if ($null -eq $Seconds) { return '_n/a_' }
    try {
        return ([Math]::Round([double]$Seconds, 3)).ToString('0.###')
    } catch {
        return '_n/a_'
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
            try {
                $durationValue = [double]$pair.durationSeconds
                if (-not [double]::IsNaN($durationValue) -and -not [double]::IsInfinity($durationValue) -and $durationValue -ge 0) {
                    $durations.Add([double]$durationValue) | Out-Null
                }
            } catch {
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
        if ($TimingSummary.PSObject.Properties['medianSeconds'] -and $null -ne $TimingSummary.medianSeconds) {
            $timingP50Seconds = [double]$TimingSummary.medianSeconds
        }
        if ($TimingSummary.PSObject.Properties['p95Seconds'] -and $null -ne $TimingSummary.p95Seconds) {
            $timingP95Seconds = [double]$TimingSummary.p95Seconds
        }
    }

    $normalizedReason = if ([string]::IsNullOrWhiteSpace($TruncationReason)) {
        if ($CommentTruncated) { 'unspecified' } else { 'none' }
    } else {
        $TruncationReason
    }

    [pscustomobject]@{
        signalRecall              = $signalRecall
        noisePrecisionMasscompile = $noisePrecisionMasscompile
        previewCoverage           = $previewCoverage
        timingP50Seconds          = $timingP50Seconds
        timingP95Seconds          = $timingP95Seconds
        commentTruncated          = [bool]$CommentTruncated
        truncationReason          = $normalizedReason
    }
}

function Get-CommitTimelineRows {
    param(
        [AllowNull()]$Summary,
        [AllowNull()]$Targets
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($Summary -and $Summary.PSObject.Properties['pairTimeline'] -and $Summary.pairTimeline -is [System.Collections.IEnumerable]) {
        foreach ($pair in @($Summary.pairTimeline)) {
            if (-not $pair) { continue }
            $rows.Add($pair) | Out-Null
        }
    }

    if ($rows.Count -eq 0 -and $Targets) {
        foreach ($target in $Targets) {
            if (-not $target) { continue }
            if (-not ($target.PSObject.Properties['commitPairs'] -and $target.commitPairs -is [System.Collections.IEnumerable])) { continue }
            foreach ($pair in @($target.commitPairs)) {
                if (-not $pair) { continue }
                $rows.Add($pair) | Out-Null
            }
        }
    }

    return @($rows)
}

$resolvedSummary = Resolve-ExistingFile -Path $SummaryPath -Description 'Summary'
$summaryRaw = Get-Content -LiteralPath $resolvedSummary -Raw -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($summaryRaw)) {
    throw "Summary file is empty: $resolvedSummary"
}

try {
    $summary = $summaryRaw | ConvertFrom-Json -ErrorAction Stop
} catch {
    throw ("Summary is not valid JSON: {0}" -f $_.Exception.Message)
}

if ($summary.schema -ne 'pr-vi-history-summary@v1') {
    throw ("Unexpected summary schema '{0}'. Expected 'pr-vi-history-summary@v1'." -f $summary.schema)
}

$resultsRoot = if ($summary.PSObject.Properties['resultsRoot']) { [string]$summary.resultsRoot } else { $null }
$targets = @()
if ($summary.targets -is [System.Collections.IEnumerable]) {
    $targets = @($summary.targets)
}

$rows = New-Object System.Collections.Generic.List[string]
$rows.Add('| VI | Change | Comparisons | Diffs | Status | Report / Notes |') | Out-Null
$rows.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null

$diffTotal = 0
$comparisonTotal = 0
$completed = 0
$durationTotalSeconds = 0.0
$durationSampleTotal = 0

foreach ($target in $targets) {
    $repoPath = if ($target.PSObject.Properties['repoPath']) { [string]$target.repoPath } else { '(unknown)' }
    $status = if ($target.PSObject.Properties['status']) { [string]$target.status } else { 'unknown' }
    $changeTypes = @()
    if ($target.PSObject.Properties['changeTypes']) {
        $changeTypes = @($target.changeTypes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($changeTypes.Count -eq 0) {
        $changeLabel = '_n/a_'
    } else {
        $changeLabel = [string]::Join(', ', ($changeTypes | ForEach-Object { $_ }))
    }

    $comparisons = '0'
    $diffs = '0'
    $reportNote = '_n/a_'
    $durationSecondsValue = $null
    $durationSamplesValue = 0
    $durationAvgSecondsValue = $null

    if ($target.PSObject.Properties['stats'] -and $target.stats) {
        $stats = $target.stats
        if ($stats.PSObject.Properties['processed']) {
            $comparisonValue = [int]$stats.processed
            $comparisonTotal += $comparisonValue
            $comparisons = $comparisonValue.ToString()
        }
        if ($stats.PSObject.Properties['diffs']) {
            $diffValue = [int]$stats.diffs
            $diffTotal += $diffValue
            $diffs = $diffValue.ToString()
        }
        if ($stats.PSObject.Properties['durationSeconds']) {
            $parsedDuration = 0.0
            if ([double]::TryParse([string]$stats.durationSeconds, [ref]$parsedDuration)) {
                $durationSecondsValue = $parsedDuration
                $durationTotalSeconds += $parsedDuration
            }
        }
        if ($stats.PSObject.Properties['durationSamples']) {
            try {
                $durationSamplesValue = [int]$stats.durationSamples
                if ($durationSamplesValue -gt 0) {
                    $durationSampleTotal += $durationSamplesValue
                }
            } catch {}
        }
        if ($stats.PSObject.Properties['durationAvgSeconds']) {
            $parsedAvg = 0.0
            if ([double]::TryParse([string]$stats.durationAvgSeconds, [ref]$parsedAvg)) {
                $durationAvgSecondsValue = $parsedAvg
            }
        }
    }

    if ($status -eq 'completed') {
        $completed++
    }

    $message = if ($target.PSObject.Properties['message']) { [string]$target.message } else { $null }

    $reportPaths = @()
    if ($target.PSObject.Properties['reportMd'] -and $target.reportMd) {
        $relativeMd = Get-RelativePath -BasePath $resultsRoot -TargetPath ([string]$target.reportMd)
        $reportPaths += ("<code>{0}</code>" -f $relativeMd)
    }
    if ($target.PSObject.Properties['reportHtml'] -and $target.reportHtml) {
        $relativeHtml = Get-RelativePath -BasePath $resultsRoot -TargetPath ([string]$target.reportHtml)
        $reportPaths += ("<code>{0}</code>" -f $relativeHtml)
    }
    if ($reportPaths.Count -gt 0) {
        $reportNote = [string]::Join('<br />', $reportPaths)
    } elseif ($message) {
        $reportNote = $message
    }

    $timingNote = $null
    if ($durationSecondsValue -ne $null -and $durationSamplesValue -gt 0) {
        $timingNote = ("time: {0:N2}s total ({1} compare{2}" -f $durationSecondsValue, $durationSamplesValue, $(if ($durationSamplesValue -eq 1) { '' } else { 's' }))
        if ($durationAvgSecondsValue -ne $null) {
            $timingNote += (", avg {0:N2}s" -f $durationAvgSecondsValue)
        }
        $timingNote += ')'
    } elseif ($durationSecondsValue -ne $null) {
        $timingNote = ("time: {0:N2}s total" -f $durationSecondsValue)
    }
    if ($timingNote) {
        if ($reportNote -eq '_n/a_') {
            $reportNote = $timingNote
        } else {
            $reportNote = ($reportNote + '<br />' + $timingNote)
        }
    }

    $statusLabel = switch ($status) {
        'completed' {
            if ([int]$diffs -gt 0) { 'diff' } else { 'match' }
        }
        'error'   { 'error' }
        'skipped' { 'skipped' }
        default   { $status }
    }

    $displayPath = if ($repoPath) { ("<code>{0}</code>" -f $repoPath) } else { '_unknown_' }

    $rows.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $displayPath, $changeLabel, $comparisons, $diffs, $statusLabel, $reportNote)) | Out-Null
}

$baseMarkdown = $rows -join [Environment]::NewLine
$timelineRows = @(Get-CommitTimelineRows -Summary $summary -Targets $targets)
$timelineEntries = New-Object System.Collections.Generic.List[object]
if ($timelineRows.Count -gt 0) {
    $timelineOrder = 0
    foreach ($pair in $timelineRows) {
        $targetPath = if ($pair.PSObject.Properties['targetPath'] -and $pair.targetPath) { [string]$pair.targetPath } else { '(unknown)' }
        $mode = if ($pair.PSObject.Properties['mode'] -and $pair.mode) { [string]$pair.mode } else { 'default' }
        $pairIndex = if ($pair.PSObject.Properties['pairIndex']) { [string]$pair.pairIndex } else { '_' }
        $baseRef = if ($pair.PSObject.Properties['baseRef']) { Get-ShortRef -Ref ([string]$pair.baseRef) } else { $null }
        $headRef = if ($pair.PSObject.Properties['headRef']) { Get-ShortRef -Ref ([string]$pair.headRef) } else { $null }
        $diffDetected = if ($pair.PSObject.Properties['diff']) { [bool]$pair.diff } else { $false }
        $classification = if ($pair.PSObject.Properties['classification'] -and $pair.classification) { [string]$pair.classification } else { 'unknown' }
        $classificationKey = $classification.ToLowerInvariant()
        $classificationBadge = ("[{0}]" -f $classificationKey)

        $durationSeconds = $null
        if ($pair.PSObject.Properties['durationSeconds']) {
            try { $durationSeconds = [double]$pair.durationSeconds } catch { $durationSeconds = $null }
        }
        $timingBadge = '[n/a]'
        if ($durationSeconds -ne $null) {
            $timingClass = if ($durationSeconds -le 60) { 'fast' } elseif ($durationSeconds -le 180) { 'steady' } else { 'slow' }
            $timingBadge = ("[{0} {1}s]" -f $timingClass, (Get-DurationDisplay -Seconds $durationSeconds))
        }

        $previewStatus = if ($pair.PSObject.Properties['previewStatus'] -and $pair.previewStatus) { [string]$pair.previewStatus } else { 'unknown' }
        $previewKey = $previewStatus.ToLowerInvariant()
        $previewBadge = switch ($previewKey) {
            'present' { '[image]' }
            'missing' { '[no-image]' }
            'error'   { '[preview-error]' }
            'skipped' { '[preview-skipped]' }
            default   { ("[{0}]" -f $previewKey) }
        }

        $reportValue = if ($pair.PSObject.Properties['reportPath'] -and $pair.reportPath) {
            $relativeReport = Get-RelativePath -BasePath $resultsRoot -TargetPath ([string]$pair.reportPath)
            "<code>$relativeReport</code>"
        } else {
            '_n/a_'
        }

        $diffLabel = if ($diffDetected) { 'yes' } else { 'no' }
        $priorityScore = if ($diffDetected -and $classificationKey -eq 'signal') {
            0
        } elseif ($diffDetected) {
            1
        } elseif ($previewKey -eq 'present') {
            2
        } else {
            3
        }

        $timelineEntries.Add([pscustomobject]@{
            order = $timelineOrder
            priority = $priorityScore
            diff = $diffDetected
            line = (
                '| <code>{0}</code> | {1} | {2} | <code>{3}</code> | <code>{4}</code> | {5} | {6} | {7} | {8} | {9} |' -f `
                    $targetPath,
                    $mode,
                    $pairIndex,
                    $(if ($baseRef) { $baseRef } else { '_' }),
                    $(if ($headRef) { $headRef } else { '_' }),
                    $diffLabel,
                    $classificationBadge,
                    $timingBadge,
                    $previewBadge,
                    $reportValue
            )
        }) | Out-Null
        $timelineOrder++
    }
}

$renderTimelineSection = {
    param([object[]]$Entries)
    if (-not $Entries -or $Entries.Count -eq 0) { return $null }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('') | Out-Null
    $lines.Add('### Commit Pair Timeline') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('| VI | Mode | Pair | Base | Head | Diff | Classification | Timing | Preview | Report |') | Out-Null
    $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |') | Out-Null
    foreach ($entry in @($Entries | Sort-Object order)) {
        $lines.Add([string]$entry.line) | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

$previewEntries = @(Get-MobilePreviewEntries -Targets $targets -ResultsRoot $resultsRoot -MaxPerTarget 1)
if ($MaxPreviewImages -ge 0 -and $previewEntries.Count -gt $MaxPreviewImages) {
    $previewEntries = @($previewEntries | Select-Object -First $MaxPreviewImages)
}

$renderPreviewSection = {
    param([object[]]$Entries)
    if (-not $Entries -or $Entries.Count -eq 0) { return $null }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('') | Out-Null
    $lines.Add('### Mobile Preview') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($entry in $Entries) {
        $lines.Add(('- <code>{0}</code><br /><img src="{1}" alt="{2}" width="240" />' -f $entry.repoPath, $entry.path, $entry.alt)) | Out-Null
    }
    return ($lines -join [Environment]::NewLine)
}

$composeMarkdown = {
    param(
        [string]$Base,
        [string]$Timeline,
        [string]$Preview
    )
    $sections = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Base)) { $sections.Add($Base) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($Timeline)) { $sections.Add($Timeline) | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($Preview)) { $sections.Add($Preview) | Out-Null }
    return ($sections -join [Environment]::NewLine)
}

$activeTimelineEntries = @($timelineEntries.ToArray())
$timelineSection = & $renderTimelineSection $activeTimelineEntries
$previewSection = & $renderPreviewSection $previewEntries
$markdown = & $composeMarkdown $baseMarkdown $timelineSection $previewSection

$timelineRowsDropped = 0
$timelineRowsTotal = $activeTimelineEntries.Count
if ($MaxMarkdownLength -gt 0 -and $markdown.Length -gt $MaxMarkdownLength -and $activeTimelineEntries.Count -gt 0) {
    $removalQueue = @($activeTimelineEntries | Sort-Object @{ Expression = { $_.priority }; Descending = $true }, @{ Expression = { $_.order }; Descending = $true })
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $activeTimelineEntries) { $kept.Add($entry) | Out-Null }

    foreach ($removeEntry in $removalQueue) {
        if ($kept.Count -le 1) { break }
        $candidate = @($kept | Where-Object { $_.order -ne $removeEntry.order })
        if ($candidate.Count -eq $kept.Count) { continue }
        $candidateTimeline = & $renderTimelineSection $candidate
        $candidateMarkdown = & $composeMarkdown $baseMarkdown $candidateTimeline $previewSection
        $kept.Clear()
        foreach ($entry in $candidate) { $kept.Add($entry) | Out-Null }
        $timelineSection = $candidateTimeline
        $markdown = $candidateMarkdown
        if ($markdown.Length -le $MaxMarkdownLength) { break }
    }

    $activeTimelineEntries = @($kept)
    $timelineRowsDropped = [Math]::Max(0, $timelineRowsTotal - $activeTimelineEntries.Count)
}

$markdownTruncated = $false
if ($MaxMarkdownLength -gt 0 -and $markdown.Length -gt $MaxMarkdownLength) {
    $suffix = [Environment]::NewLine + [Environment]::NewLine + (
        '> NOTE - Summary truncated for comment size safety (limit={0}, original={1}, pair_rows_kept={2}, pair_rows_dropped={3}, policy=newest-signal-first).' -f `
            $MaxMarkdownLength,
            $markdown.Length,
            $activeTimelineEntries.Count,
            $timelineRowsDropped
    )
    $safeLength = [Math]::Max(0, $MaxMarkdownLength - $suffix.Length)
    $markdown = $markdown.Substring(0, $safeLength).TrimEnd() + $suffix
    $markdownTruncated = $true
} elseif ($timelineRowsDropped -gt 0) {
    $markdown = ($markdown, '', (
        '> NOTE - Timeline rows truncated for mobile/comment-size safety (kept {0} of {1}; dropped {2}; policy=newest-signal-first).' -f `
            $activeTimelineEntries.Count,
            $timelineRowsTotal,
            $timelineRowsDropped
    )) -join [Environment]::NewLine
}

$activeTimelineRows = @()
if ($activeTimelineEntries.Count -eq $timelineRows.Count) {
    $activeTimelineRows = @($timelineRows)
} else {
    $activeOrderLookup = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($entry in $activeTimelineEntries) { [void]$activeOrderLookup.Add([int]$entry.order) }
    for ($i = 0; $i -lt $timelineRows.Count; $i++) {
        if ($activeOrderLookup.Contains($i)) {
            $activeTimelineRows += $timelineRows[$i]
        }
    }
}

$diffPairRows = 0
foreach ($pair in $activeTimelineRows) {
    if (-not $pair) { continue }
    if ($pair.PSObject.Properties['diff'] -and [bool]$pair.diff) {
        $diffPairRows++
    }
}

$timingSummary = $null
if ($summary.PSObject.Properties['timing'] -and $summary.timing) {
    $timingSummary = $summary.timing
} elseif ($summary.PSObject.Properties['totals'] -and $summary.totals -and $summary.totals.PSObject.Properties['timing']) {
    $timingSummary = $summary.totals.timing
}

$commentTruncated = ($markdownTruncated -or $timelineRowsDropped -gt 0)
$truncationReason = if ($markdownTruncated) {
    'max-markdown-length'
} elseif ($timelineRowsDropped -gt 0) {
    'timeline-row-drop'
} else {
    'none'
}
$kpiEnvelope = Get-PairKpiEnvelope -Pairs $activeTimelineRows -TimingSummary $timingSummary -CommentTruncated:$commentTruncated -TruncationReason $truncationReason

$result = [pscustomobject]@{
    totals = [pscustomobject]@{
        targets     = $targets.Count
        completed   = $completed
        comparisons = $comparisonTotal
        diffs       = $diffTotal
        pairRows    = $activeTimelineEntries.Count
        pairRowsTotal = $timelineRows.Count
        pairRowsDropped = $timelineRowsDropped
        diffPairRows= $diffPairRows
        previewImages = $previewEntries.Count
        markdownTruncated = $markdownTruncated
        durationSeconds = [Math]::Round($durationTotalSeconds, 6)
        durationSamples = $durationSampleTotal
        timing      = $timingSummary
    }
    targets  = $targets
    pairTimeline = $activeTimelineRows
    previews = $previewEntries
    kpi      = $kpiEnvelope
    markdown = $markdown
}

if ($MarkdownPath) {
    Set-Content -LiteralPath $MarkdownPath -Value $markdown -Encoding utf8
}
if ($OutputJsonPath) {
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJsonPath -Encoding utf8
}

if ($Env:GITHUB_OUTPUT) {
    $encodedMarkdown = $markdown -replace "`r?`n", '%0A'
    "markdown=$encodedMarkdown" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    if ($MarkdownPath) { "markdown_path=$MarkdownPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append }
    "target_count=$($targets.Count)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "completed_count=$completed" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_count=$diffTotal" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "pair_row_count=$($activeTimelineEntries.Count)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_pair_count=$diffPairRows" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

return $result
