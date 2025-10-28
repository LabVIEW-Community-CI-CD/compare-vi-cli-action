#Requires -Version 7.0
<#
.SYNOPSIS
  Produces human-friendly summaries for staged LVCompare results.

.DESCRIPTION
  Reads the `vi-staging-compare.json` payload emitted by Run-StagedLVCompare,
  enriches each pair with compare-report insights (included/suppressed
  categories, headings, diff details), and renders aggregate totals together
  with a Markdown table that can be dropped into PR comments.

.PARAMETER CompareJson
  Path to `vi-staging-compare.json`.

.PARAMETER MarkdownPath
  Optional path where the rendered Markdown table should be written.

.PARAMETER SummaryJsonPath
  Optional path for writing the enriched summary (pairs, totals, markdown).

.OUTPUTS
  PSCustomObject with `totals`, `pairs`, `markdown`, and `compareDir`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompareJson,

    [string]$MarkdownPath,

    [string]$SummaryJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Leaf) {
            return $resolved
        }
    } catch {
        return $null
    }
    return $null
}

function Get-RelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $null }
    if ([string]::IsNullOrWhiteSpace($BasePath)) { return $TargetPath }
    try {
        return [System.IO.Path]::GetRelativePath($BasePath, $TargetPath)
    } catch {
        return $TargetPath
    }
}

function Parse-InclusionList {
    param([string]$Html)
    $map = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Html)) { return $map }
    $pattern = '<li\s+class="(?<class>checked|unchecked)">(?<label>[^<]+)</li>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $label = $match.Groups['label'].Value.Trim()
        if (-not $label) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($label)
        $map[$decoded] = ($match.Groups['class'].Value.Trim().ToLowerInvariant() -eq 'checked')
    }
    return $map
}

function Parse-DiffHeadings {
    param([string]$Html)
    $headings = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $headings }
    $pattern = '<summary\s+class="difference-heading">\s*(?<text>.*?)\s*</summary>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $raw = $match.Groups['text'].Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
        $decoded = ($decoded -replace '^\s*\d+\.\s*', '')
        if (-not $decoded) { continue }
        $headings.Add($decoded)
    }
    return $headings
}

function Parse-DiffDetails {
    param([string]$Html)
    $details = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $details }
    $pattern = '<li\s+class="diff-detail">\s*(?<text>.*?)\s*</li>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $raw = $match.Groups['text'].Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
        if ($decoded) { $details.Add($decoded) }
    }
    return $details
}

function Build-MarkdownTable {
    param(
        [pscustomobject[]]$Pairs,
        [pscustomobject]$Totals,
        [string]$CompareDir
    )

    if (-not $Pairs -or $Pairs.Count -eq 0) {
        return "No staged VI pairs were compared."
    }

    $rows = @()
    $rows += '| Pair | Status | Diff Categories | Included | Report |'
    $rows += '| --- | --- | --- | --- | --- |'

    foreach ($pair in $Pairs) {
        $statusIcon = switch ($pair.status) {
            'match'   { '✅ match' }
            'diff'    { '🟥 diff' }
            'error'   { '⚠️ error' }
            'skipped' { '⏭️ skipped' }
            default   { $pair.status }
        }

        $categories = if ($pair.diffCategories -and $pair.diffCategories.Count -gt 0) {
            ($pair.diffCategories -join ', ')
        } elseif ($pair.status -eq 'match') {
            '—'
        } elseif ($pair.status -eq 'skipped') {
            'staged bundle missing'
        } else {
            'n/a'
        }

        $included = if ($pair.includedAttributes -and $pair.includedAttributes.Count -gt 0) {
            ($pair.includedAttributes | ForEach-Object {
                if ($_.value) { "{0} ✅" -f $_.name } else { "{0} ❌" -f $_.name }
            }) -join '<br/>'
        } else {
            '—'
        }

        $reportLink = if ($pair.reportRelative) {
            ('`{0}`' -f $pair.reportRelative.Replace('\','/'))
        } elseif ($pair.reportPath) {
            ('`{0}`' -f $pair.reportPath)
        } else {
            '—'
        }

        $pairLabel = ('Pair {0} ({1})' -f $pair.index, $pair.changeType)
        $rows += ('| {0} | {1} | {2} | {3} | {4} |' -f $pairLabel, $statusIcon, $categories, $included, $reportLink)
    }

    $summaryLines = @()
    $summaryLines += ('**Totals** — diff: {0}, match: {1}, skipped: {2}, error: {3}' -f `
        $Totals.diff, $Totals.match, $Totals.skipped, $Totals.error)
    if ($CompareDir) {
        $summaryLines += ('Artifacts rooted at `{0}`.' -f $CompareDir.Replace('\','/'))
    }

    return ($summaryLines + '' + $rows) -join "`n"
}

if (-not (Test-Path -LiteralPath $CompareJson -PathType Leaf)) {
    throw "Compare summary file not found: $CompareJson"
}

$raw = Get-Content -LiteralPath $CompareJson -Raw -ErrorAction Stop
if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Compare summary file is empty: $CompareJson"
}

try {
    $entries = $raw | ConvertFrom-Json -Depth 8
} catch {
    throw ("Unable to parse compare summary JSON at {0}: {1}" -f $CompareJson, $_.Exception.Message)
}

if ($entries -isnot [System.Collections.IEnumerable]) {
    $entries = @($entries)
}

$pairs = New-Object System.Collections.Generic.List[pscustomobject]
$totals = [ordered]@{
    diff    = 0
    match   = 0
    skipped = 0
    error   = 0
}

$compareRoot = $null
foreach ($entry in $entries) {
    if ($entry -and $entry.PSObject.Properties['outputDir'] -and $entry.outputDir) {
        $candidate = Resolve-ExistingFile -Path $entry.outputDir
        if (-not $candidate -and (Test-Path -LiteralPath $entry.outputDir -PathType Container)) {
            $candidate = (Resolve-Path -LiteralPath $entry.outputDir -ErrorAction SilentlyContinue).Path
        }
        if ($candidate) {
            $parent = Split-Path -Parent $candidate
            if ($parent) { $compareRoot = $parent; break }
        }
    }
}

foreach ($entry in $entries) {
    $status = $entry.status
    if ($totals.Contains($status)) {
        $totals[$status]++
    }

    $reportPath = $null
    if ($entry.PSObject.Properties['reportPath']) {
        $reportPath = Resolve-ExistingFile -Path $entry.reportPath
    }
    if (-not $reportPath -and $entry.PSObject.Properties['outputDir'] -and $entry.outputDir) {
        $htmlCandidate = Join-Path $entry.outputDir 'compare-report.html'
        if (Test-Path -LiteralPath $htmlCandidate -PathType Leaf) {
            $reportPath = (Resolve-Path -LiteralPath $htmlCandidate).Path
        }
    }
    $capturePath = $null
    if ($entry.PSObject.Properties['capturePath']) {
        $capturePath = Resolve-ExistingFile -Path $entry.capturePath
    }
    if (-not $capturePath -and $entry.PSObject.Properties['outputDir'] -and $entry.outputDir) {
        $capCandidate = Join-Path $entry.outputDir 'lvcompare-capture.json'
        if (Test-Path -LiteralPath $capCandidate -PathType Leaf) {
            $capturePath = (Resolve-Path -LiteralPath $capCandidate).Path
        }
    }

    $htmlContent = $null
    if ($reportPath) {
        try {
            $htmlContent = Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop
        } catch {
            $htmlContent = $null
        }
    }

    $included = Parse-InclusionList -Html $htmlContent
    $headings = Parse-DiffHeadings -Html $htmlContent
    $details  = Parse-DiffDetails -Html $htmlContent

    $categories = New-Object System.Collections.Generic.List[string]
    foreach ($heading in $headings) {
        if (-not $heading) { continue }
        $primary = $heading
        $splitIdx = $heading.IndexOf(' - ')
        if ($splitIdx -gt 0) {
            $primary = $heading.Substring(0, $splitIdx)
        }
        $primary = $primary.Trim()
        if (-not $primary) { continue }
        if (-not $categories.Contains($primary)) {
            $categories.Add($primary)
        }
    }

    $includedList = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($key in $included.Keys) {
        $includedList.Add([pscustomobject]@{
            name  = $key
            value = [bool]$included[$key]
        })
    }

    $reportRelative = $null
    if ($reportPath -and $compareRoot) {
        $reportRelative = Get-RelativePath -BasePath $compareRoot -TargetPath $reportPath
    }

    $stagedBase = $null
    $stagedHead = $null
    if ($entry.PSObject.Properties['stagedBase']) {
        $stagedBase = $entry.stagedBase
    }
    if ($entry.PSObject.Properties['stagedHead']) {
        $stagedHead = $entry.stagedHead
    }

    $pairInfo = [pscustomobject]@{
        index             = $entry.index
        changeType        = $entry.changeType
        basePath          = $entry.basePath
        headPath          = $entry.headPath
        stagedBase        = $stagedBase
        stagedHead        = $stagedHead
        status            = $status
        exitCode          = $entry.exitCode
        capturePath       = $capturePath
        reportPath        = $reportPath
        reportRelative    = $reportRelative
        diffCategories    = $categories
        diffHeadings      = $headings
        diffDetails       = $details
        includedAttributes= $includedList
    }

    $pairs.Add($pairInfo)
}

$totalsObj = [pscustomobject]$totals
$markdown = Build-MarkdownTable -Pairs $pairs -Totals $totalsObj -CompareDir $compareRoot

$result = [pscustomobject]@{
    totals     = $totalsObj
    pairs      = $pairs
    markdown   = $markdown
    compareDir = $compareRoot
}

if ($SummaryJsonPath) {
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $SummaryJsonPath -Encoding utf8
}

if ($MarkdownPath) {
    $markdown | Set-Content -LiteralPath $MarkdownPath -Encoding utf8
}

if ($Env:GITHUB_OUTPUT) {
    if ($MarkdownPath) {
        "markdown_path=$MarkdownPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
    if ($SummaryJsonPath) {
        "summary_json=$SummaryJsonPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
    if ($compareRoot) {
        "compare_dir=$compareRoot" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}

return $result
