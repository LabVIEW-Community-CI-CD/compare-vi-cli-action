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

$markdown = $rows -join [Environment]::NewLine
$timelineRows = @(Get-CommitTimelineRows -Summary $summary -Targets $targets)
if ($timelineRows.Count -gt 0) {
    $timelineLines = New-Object System.Collections.Generic.List[string]
    $timelineLines.Add('') | Out-Null
    $timelineLines.Add('### Commit Pair Timeline') | Out-Null
    $timelineLines.Add('') | Out-Null
    $timelineLines.Add('| VI | Mode | Pair | Base | Head | Diff | Classification | Time (s) | Preview | Report |') | Out-Null
    $timelineLines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |') | Out-Null

    foreach ($pair in $timelineRows) {
        $targetPath = if ($pair.PSObject.Properties['targetPath'] -and $pair.targetPath) { [string]$pair.targetPath } else { '(unknown)' }
        $mode = if ($pair.PSObject.Properties['mode'] -and $pair.mode) { [string]$pair.mode } else { 'default' }
        $pairIndex = if ($pair.PSObject.Properties['pairIndex']) { [string]$pair.pairIndex } else { '_' }
        $baseRef = if ($pair.PSObject.Properties['baseRef']) { Get-ShortRef -Ref ([string]$pair.baseRef) } else { $null }
        $headRef = if ($pair.PSObject.Properties['headRef']) { Get-ShortRef -Ref ([string]$pair.headRef) } else { $null }
        $diffDetected = if ($pair.PSObject.Properties['diff']) { [bool]$pair.diff } else { $false }
        $classification = if ($pair.PSObject.Properties['classification'] -and $pair.classification) { [string]$pair.classification } else { 'unknown' }
        $durationDisplay = if ($pair.PSObject.Properties['durationSeconds']) {
            Get-DurationDisplay -Seconds $pair.durationSeconds
        } else {
            '_n/a_'
        }
        $previewStatus = if ($pair.PSObject.Properties['previewStatus'] -and $pair.previewStatus) { [string]$pair.previewStatus } else { 'unknown' }
        $reportValue = if ($pair.PSObject.Properties['reportPath'] -and $pair.reportPath) {
            $relativeReport = Get-RelativePath -BasePath $resultsRoot -TargetPath ([string]$pair.reportPath)
            "<code>$relativeReport</code>"
        } else {
            '_n/a_'
        }

        $diffLabel = if ($diffDetected) { 'yes' } else { 'no' }
        $timelineLines.Add((
            '| <code>{0}</code> | {1} | {2} | <code>{3}</code> | <code>{4}</code> | {5} | {6} | {7} | {8} | {9} |' -f `
                $targetPath,
                $mode,
                $pairIndex,
                $(if ($baseRef) { $baseRef } else { '_' }),
                $(if ($headRef) { $headRef } else { '_' }),
                $diffLabel,
                $classification,
                $durationDisplay,
                $previewStatus,
                $reportValue
        )) | Out-Null
    }

    $markdown = ($markdown, ($timelineLines -join [Environment]::NewLine)) -join [Environment]::NewLine
}

$previewEntries = @(Get-MobilePreviewEntries -Targets $targets -ResultsRoot $resultsRoot -MaxPerTarget 1)
if ($MaxPreviewImages -ge 0 -and $previewEntries.Count -gt $MaxPreviewImages) {
    $previewEntries = @($previewEntries | Select-Object -First $MaxPreviewImages)
}
if ($previewEntries.Count -gt 0) {
    $previewLines = New-Object System.Collections.Generic.List[string]
    $previewLines.Add('') | Out-Null
    $previewLines.Add('### Mobile Preview') | Out-Null
    $previewLines.Add('') | Out-Null
    foreach ($entry in $previewEntries) {
        $previewLines.Add(('- <code>{0}</code><br /><img src="{1}" alt="{2}" width="240" />' -f $entry.repoPath, $entry.path, $entry.alt)) | Out-Null
    }
    $markdown = ($markdown, ($previewLines -join [Environment]::NewLine)) -join [Environment]::NewLine
}

$markdownTruncated = $false
if ($MaxMarkdownLength -gt 0 -and $markdown.Length -gt $MaxMarkdownLength) {
    $suffix = [Environment]::NewLine + [Environment]::NewLine + '> NOTE - Summary truncated for comment size safety.'
    $safeLength = [Math]::Max(0, $MaxMarkdownLength - $suffix.Length)
    $markdown = $markdown.Substring(0, $safeLength).TrimEnd() + $suffix
    $markdownTruncated = $true
}

$diffPairRows = 0
foreach ($pair in $timelineRows) {
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

$result = [pscustomobject]@{
    totals = [pscustomobject]@{
        targets     = $targets.Count
        completed   = $completed
        comparisons = $comparisonTotal
        diffs       = $diffTotal
        pairRows    = $timelineRows.Count
        diffPairRows= $diffPairRows
        previewImages = $previewEntries.Count
        markdownTruncated = $markdownTruncated
        timing      = $timingSummary
    }
    targets  = $targets
    pairTimeline = $timelineRows
    previews = $previewEntries
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
    "pair_row_count=$($timelineRows.Count)" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    "diff_pair_count=$diffPairRows" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
}

return $result
