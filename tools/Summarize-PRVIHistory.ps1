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

    [string]$OutputJsonPath
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

$result = [pscustomobject]@{
    totals = [pscustomobject]@{
        targets     = $targets.Count
        completed   = $completed
        comparisons = $comparisonTotal
        diffs       = $diffTotal
    }
    targets  = $targets
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
}

return $result
