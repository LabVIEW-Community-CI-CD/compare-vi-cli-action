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

.PARAMETER HtmlPath
  Optional path where a consolidated HTML summary should be written.

.OUTPUTS
  PSCustomObject with `totals`, `pairs`, `markdown`, `html`, and `compareDir`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CompareJson,

    [string]$MarkdownPath,

    [string]$SummaryJsonPath,

    [string]$HtmlPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $categoryModule = Join-Path (Split-Path -Parent $PSCommandPath) 'VICategoryBuckets.psm1'
    if (Test-Path -LiteralPath $categoryModule -PathType Leaf) {
        Import-Module $categoryModule -Force
    }
} catch {}
try {
    $artifactModule = Join-Path (Split-Path -Parent $PSCommandPath) 'VICompareArtifacts.psm1'
    if (Test-Path -LiteralPath $artifactModule -PathType Leaf) {
        Import-Module $artifactModule -Force
    }
} catch {}

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

function Resolve-ExistingDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            return $resolved
        }
    } catch {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            return $Path
        }
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

function Convert-ToSafeHtmlText {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Convert-ToHtmlHref {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $null }
    $relative = Get-RelativePath -BasePath $BasePath -TargetPath $TargetPath
    if ([string]::IsNullOrWhiteSpace($relative)) { return $null }
    $normalized = ($relative -replace '\\', '/')
    $segments = $normalized -split '/'
    $encoded = foreach ($segment in $segments) {
        if ($segment -eq '.' -or $segment -eq '..' -or [string]::IsNullOrWhiteSpace($segment)) {
            $segment
        } else {
            [Uri]::EscapeDataString($segment)
        }
    }
    return ($encoded -join '/')
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

    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor `
                    [System.Text.RegularExpressions.RegexOptions]::Singleline

    $patterns = @(
        '<summary\b[^>]*class="[^"]*\bdifference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
        '<summary\b[^>]*class="[^"]*\bvi-difference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
        '<summary\b[^>]*class="[^"]*\bdifference-cosmetic-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</summary>',
        '<h[1-6]\b[^>]*class="[^"]*\bdifference-heading\b[^"]*"[^>]*>\s*(?<text>.*?)\s*</h[1-6]>',
        '<details\b[^>]*data-diff-(?:category|heading)="(?<text>[^"]+)"[^>]*>'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, $regexOptions)) {
            $raw = $match.Groups['text'].Value
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
            $decoded = ($decoded -replace '^\s*\d+[\.\)]\s*', '')
            if (-not $decoded) { continue }
            if (-not $headings.Contains($decoded)) {
                $headings.Add($decoded) | Out-Null
            }
        }
    }

    return $headings
}

function Parse-DiffDetails {
    param([string]$Html)
    $details = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $details }
    $pattern = '<li\s+class="diff-detail(?:-cosmetic)?">\s*(?<text>.*?)\s*</li>'
    foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($Html, $pattern, 'IgnoreCase')) {
        $raw = $match.Groups['text'].Value
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $decoded = [System.Net.WebUtility]::HtmlDecode($raw.Trim())
        if ($decoded) { $details.Add($decoded) }
    }
    return $details
}

function Infer-DiffCategoriesFromDetails {
    param([System.Collections.IEnumerable]$Details)

    $inferred = New-Object System.Collections.Generic.List[string]
    if (-not $Details) { return $inferred }

    $append = {
        param($name)
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        if (-not $inferred.Contains($name)) {
            $inferred.Add($name) | Out-Null
        }
    }

    foreach ($detail in $Details) {
        if ([string]::IsNullOrWhiteSpace($detail)) { continue }
        $token = $detail.ToLowerInvariant()

        $hasBlockDiagram = $token -match 'block diagram'
        $hasFrontPanel   = $token -match 'front panel'
        $hasConnector    = $token -match 'connector pane'
        $hasWindow       = $token -match 'window'
        $hasIcon         = $token -match 'icon'
        $hasAttribute    = $token -match 'vi attribute' -or $token -match 'attributes'
        $hasCosmetic     = $token -match 'cosmetic'

        if ($hasBlockDiagram) {
            if ($hasCosmetic) {
                &$append 'Block Diagram Cosmetic'
            } elseif ($token -match 'functional') {
                &$append 'Block Diagram Functional'
            } else {
                &$append 'Block Diagram'
            }
        } elseif ($hasCosmetic) {
            &$append 'Cosmetic'
        }

        if ($hasConnector) {
            &$append 'Connector Pane'
        }

        if ($hasFrontPanel -or $token -match 'control' -or $token -match 'indicator') {
            &$append 'Front Panel'
        }

        if ($hasWindow -or $token -match 'position/size' -or $token -match 'window size' -or $token -match 'panel position') {
            &$append 'Front Panel Position/Size'
        }

        if ($hasIcon -or $hasAttribute -or $token -match 'documentation' -or $token -match 'execution') {
            if ($hasIcon) { &$append 'Icon' }
            &$append 'VI Attribute'
        }
    }

    return $inferred
}

function Find-ReportPath {
    param(
        [pscustomobject]$Entry,
        [string]$CompareDir,
        [string]$CapturePath
    )

    $directories = New-Object System.Collections.Generic.List[string]
    if ($Entry -and $Entry.PSObject.Properties['outputDir'] -and $Entry.outputDir) {
        $directories.Add([string]$Entry.outputDir) | Out-Null
    }
    if ($Entry -and $Entry.PSObject.Properties['modes'] -and $Entry.modes) {
        foreach ($mode in $Entry.modes) {
            if (-not $mode) { continue }
            if ($mode.PSObject.Properties['outputDir'] -and $mode.outputDir) {
                $directories.Add([string]$mode.outputDir) | Out-Null
            }
        }
    }
    $pairIndex = 0
    if ($Entry -and $Entry.PSObject.Properties['index']) {
        try { $pairIndex = [int]$Entry.index } catch { $pairIndex = 0 }
    }
    if ($CompareDir -and $pairIndex -gt 0) {
        $directories.Add((Join-Path $CompareDir ("pair-{0:D2}" -f $pairIndex))) | Out-Null
    }
    $explicitReportPath = $null
    if ($Entry -and $Entry.PSObject.Properties['reportPath'] -and $Entry.reportPath) {
        $explicitReportPath = [string]$Entry.reportPath
    }
    if (-not [string]::IsNullOrWhiteSpace($explicitReportPath)) {
        $resolvedExplicit = Resolve-ExistingFile -Path $explicitReportPath
        if ($resolvedExplicit) {
            return $resolvedExplicit
        }
    }
    return (Find-VICompareReportArtifact `
        -ExplicitReportPath $explicitReportPath `
        -CapturePath $CapturePath `
        -SearchDirectories @($directories.ToArray()) `
        -Recursive)
}

function Find-CapturePath {
    param(
        [pscustomobject]$Entry,
        [string]$CompareDir
    )

    if ($Entry -and $Entry.PSObject.Properties['capturePath'] -and $Entry.capturePath) {
        $resolved = Resolve-ExistingFile -Path $Entry.capturePath
        if ($resolved) { return $resolved }
    }

    $directories = New-Object System.Collections.Generic.List[string]
    if ($Entry -and $Entry.PSObject.Properties['outputDir'] -and $Entry.outputDir) {
        $directories.Add([string]$Entry.outputDir) | Out-Null
    }
    if ($Entry -and $Entry.PSObject.Properties['modes'] -and $Entry.modes) {
        foreach ($mode in $Entry.modes) {
            if (-not $mode) { continue }
            if ($mode.PSObject.Properties['outputDir'] -and $mode.outputDir) {
                $directories.Add([string]$mode.outputDir) | Out-Null
            }
        }
    }
    $pairIndex = 0
    if ($Entry -and $Entry.PSObject.Properties['index']) {
        try { $pairIndex = [int]$Entry.index } catch { $pairIndex = 0 }
    }
    if ($CompareDir -and $pairIndex -gt 0) {
        $directories.Add((Join-Path $CompareDir ("pair-{0:D2}" -f $pairIndex))) | Out-Null
    }

    foreach ($dir in ($directories | Select-Object -Unique)) {
        $resolvedDir = Resolve-ExistingDirectory -Path $dir
        if (-not $resolvedDir) { continue }
        $candidate = Join-Path $resolvedDir 'lvcompare-capture.json'
        $resolved = Resolve-ExistingFile -Path $candidate
        if ($resolved) { return $resolved }
        try {
            $modeDirs = Get-ChildItem -LiteralPath $resolvedDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'mode-*' }
            foreach ($modeDir in $modeDirs) {
                $candidate = Join-Path $modeDir.FullName 'lvcompare-capture.json'
                $resolved = Resolve-ExistingFile -Path $candidate
                if ($resolved) { return $resolved }
            }
        } catch {}
    }

    if ($CompareDir) {
        try {
            $fallback = Get-ChildItem -LiteralPath $CompareDir -Recurse -File -Filter 'lvcompare-capture.json' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($fallback) { return $fallback.FullName }
        } catch {}
    }

    return $null
}

function Format-ModeFlags {
    param([System.Collections.IEnumerable]$Modes)
    if (-not $Modes) { return '_none_' }
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($mode in $Modes) {
        if (-not $mode) { continue }
        $modeName = if ($mode.PSObject.Properties['name']) { [string]$mode.name } else { $null }
        if ([string]::IsNullOrWhiteSpace($modeName)) { $modeName = 'mode' }
        $statusText = if ($mode.PSObject.Properties['status'] -and $mode.status) { [string]$mode.status } else { 'unknown' }
        $modeFlags = @()
        if ($mode.PSObject.Properties['flags'] -and $mode.flags) {
            $modeFlags = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $flagText = if ($modeFlags.Count -gt 0) { ('`{0}`' -f ($modeFlags -join ' ')) } else { '_none_' }
        $parts.Add("$($modeName): $flagText ($statusText)") | Out-Null
    }
    if ($parts.Count -eq 0) { return '_none_' }
    return ($parts -join '<br>')
}

function Get-DiffDetailPreview {
    param(
        [System.Collections.IEnumerable]$Details,
        [System.Collections.IEnumerable]$Headings,
        [string]$Status
    )

    $preview = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    if ($Details) {
        foreach ($item in $Details) {
            $text = [string]$item
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($seen.Add($text) -eq $false) { continue }
            if ($preview.Count -lt 3) {
                $preview.Add($text) | Out-Null
            } elseif ($preview.Count -eq 3) {
                $preview[2] = $preview[2] + '; …'
                break
            }
        }
    }

    if ($preview.Count -eq 0 -and $Status -eq 'diff' -and $Headings) {
        foreach ($heading in $Headings) {
            $text = [string]$heading
            if ([string]::IsNullOrWhiteSpace($text)) { continue }
            if ($preview.Count -lt 3) {
                $preview.Add($text) | Out-Null
            } elseif ($preview.Count -eq 3) {
                $preview[2] = $preview[2] + '; …'
                break
            }
        }
    }

    return $preview
}

function Get-CategoryDetailsFromNames {
    param([System.Collections.IEnumerable]$Names)

    return @(ConvertTo-VICategoryDetails -Names $Names)
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
    $rows += '| Pair | Status | Diff Categories | Included | Report | Flags | Leak |'
    $rows += '| --- | --- | --- | --- | --- | --- | --- |'

    foreach ($pair in $Pairs) {
        $statusIcon = switch ($pair.status) {
            'match'   { '✅ match' }
            'diff'    { '🟥 diff' }
            'error'   { '⚠️ error' }
            'skipped' { '⏭️ skipped' }
            default   { $pair.status }
        }

        $categoryLines = New-Object System.Collections.Generic.List[string]
        $hasCategories = $false
        if ($pair.PSObject.Properties['diffCategoryDetails'] -and $pair.diffCategoryDetails) {
            foreach ($detail in $pair.diffCategoryDetails) {
                if (-not $detail) { continue }
                $text = [string]$detail.label
                if ([string]::IsNullOrWhiteSpace($text)) { $text = $detail.slug }
                switch ($detail.classification) {
                    'noise'   { $text = '{0} _(noise)_' -f $text }
                    'neutral' { $text = '{0} _(neutral)_' -f $text }
                }
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    $categoryLines.Add($text) | Out-Null
                }
            }
            if ($categoryLines.Count -gt 0) {
                $hasCategories = $true
            }
        }
        if (-not $hasCategories -and $pair.diffCategories -and $pair.diffCategories.Count -gt 0) {
            foreach ($rawCategory in $pair.diffCategories) {
                if ([string]::IsNullOrWhiteSpace($rawCategory)) { continue }
                $categoryLines.Add($rawCategory) | Out-Null
            }
            if ($categoryLines.Count -gt 0) {
                $hasCategories = $true
            }
        }
        if (-not $hasCategories) {
            switch ($pair.status) {
                'match'   { $categoryLines.Add('-') | Out-Null }
                'skipped' { $categoryLines.Add('staged bundle missing') | Out-Null }
                default   { $categoryLines.Add('n/a') | Out-Null }
            }
        }

        $detailList = @()
        if ($pair.PSObject.Properties['diffDetailPreview'] -and $pair.diffDetailPreview) {
            $detailList = @($pair.diffDetailPreview | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($detailList.Count -gt 0) {
            $detailMarkup = "<small>{0}</small>" -f ($detailList -join '<br/>')
            if ($hasCategories) {
                $categoryLines.Add($detailMarkup) | Out-Null
            } else {
                $categoryLines.Clear()
                $categoryLines.Add($detailMarkup) | Out-Null
            }
        }

        $bucketLines = New-Object System.Collections.Generic.List[string]
        if ($pair.PSObject.Properties['diffBucketDetails'] -and $pair.diffBucketDetails) {
            foreach ($bucket in $pair.diffBucketDetails) {
                if (-not $bucket) { continue }
                $bucketLabel = $null
                if ($bucket.PSObject.Properties['bucketLabel']) {
                    $bucketLabel = [string]$bucket.bucketLabel
                }
                if ([string]::IsNullOrWhiteSpace($bucketLabel) -and $bucket.PSObject.Properties['label']) {
                    $bucketLabel = [string]$bucket.label
                }
                if ([string]::IsNullOrWhiteSpace($bucketLabel)) {
                    $bucketLabel = [string]$bucket.slug
                }
                $bucketClassification = $null
                if ($bucket.PSObject.Properties['bucketClassification']) {
                    $bucketClassification = [string]$bucket.bucketClassification
                } elseif ($bucket.PSObject.Properties['classification']) {
                    $bucketClassification = [string]$bucket.classification
                }
                switch ($bucketClassification) {
                    'noise'   { $bucketLabel = '{0} _(noise)_' -f $bucketLabel }
                    'neutral' { $bucketLabel = '{0} _(neutral)_' -f $bucketLabel }
                }
                if (-not [string]::IsNullOrWhiteSpace($bucketLabel)) {
                    $bucketLines.Add($bucketLabel) | Out-Null
                }
            }
        } elseif ($pair.PSObject.Properties['diffBuckets'] -and $pair.diffBuckets) {
            foreach ($bucketSlug in $pair.diffBuckets) {
                if ([string]::IsNullOrWhiteSpace($bucketSlug)) { continue }
                $bucketMeta = Get-VIBucketMetadata -BucketSlug $bucketSlug
                $bucketLabel = if ($bucketMeta) { $bucketMeta.label } else { $bucketSlug }
                if ($bucketMeta) {
                    switch ($bucketMeta.classification) {
                        'noise'   { $bucketLabel = '{0} _(noise)_' -f $bucketLabel }
                        'neutral' { $bucketLabel = '{0} _(neutral)_' -f $bucketLabel }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($bucketLabel)) {
                    $bucketLines.Add($bucketLabel) | Out-Null
                }
            }
        }
        if ($bucketLines.Count -gt 0) {
            $bucketMarkup = "<small>Buckets: $($bucketLines -join ', ')</small>"
            $categoryLines.Add($bucketMarkup) | Out-Null
        }

        $categories = [string]::Join('<br/>', $categoryLines.ToArray())

        $included = if ($pair.includedAttributes -and $pair.includedAttributes.Count -gt 0) {
            ($pair.includedAttributes | ForEach-Object {
                if ($_.value) { "{0} ✅" -f $_.name } else { "{0} ❌" -f $_.name }
            }) -join '<br/>'
        } else {
            '-'
        }

        $reportLink = if ($pair.reportRelative) {
            ('`{0}`' -f $pair.reportRelative.Replace('\','/'))
        } elseif ($pair.reportPath) {
            ('`{0}`' -f $pair.reportPath)
        } else {
            '-'
        }

        $flagsCell = '_none_'
        if ($pair.PSObject.Properties['flagSummary'] -and $pair.flagSummary) {
            $flagsCell = $pair.flagSummary
        } elseif ($pair.PSObject.Properties['modeSummaries'] -and $pair.modeSummaries) {
            $flagsCell = Format-ModeFlags $pair.modeSummaries
        }

        $leakCell = '-'
        $leakCountsKnown = $false
        $lvLeak = $null
        $labLeak = $null
        if ($pair.PSObject.Properties['leakLvcompare']) {
            try { $lvLeak = [int]$pair.leakLvcompare } catch { $lvLeak = $pair.leakLvcompare }
            $leakCountsKnown = $true
        }
        if ($pair.PSObject.Properties['leakLabVIEW']) {
            try { $labLeak = [int]$pair.leakLabVIEW } catch { $labLeak = $pair.leakLabVIEW }
            $leakCountsKnown = $true
        }
        if ($leakCountsKnown) {
            $lvLeak = if ($lvLeak -ne $null) { $lvLeak } else { 0 }
            $labLeak = if ($labLeak -ne $null) { $labLeak } else { 0 }
            if ($lvLeak -gt 0 -or $labLeak -gt 0 -or ($pair.PSObject.Properties['leakWarning'] -and $pair.leakWarning)) {
                $leakCell = ("⚠ lv={0}, lab={1}" -f $lvLeak, $labLeak)
            } else {
                $leakCell = '_none_'
            }
        }

        $pairLabel = ('Pair {0} ({1})' -f $pair.index, $pair.changeType)
        $rows += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $pairLabel, $statusIcon, $categories, $included, $reportLink, $flagsCell, $leakCell)
    }

    $summaryLines = @()
    $summaryLines += ('**Totals** - diff: {0}, match: {1}, skipped: {2}, error: {3}, leaks: {4}' -f `
        $Totals.diff, $Totals.match, $Totals.skipped, $Totals.error, $Totals.leakWarnings)
    if ($CompareDir) {
        $summaryLines += ('Artifacts rooted at `{0}`.' -f $CompareDir.Replace('\','/'))
    }
    if ($Totals.PSObject.Properties['categoryCounts'] -and $Totals.categoryCounts.Keys.Count -gt 0) {
        $categoryParts = New-Object System.Collections.Generic.List[string]
        foreach ($categoryKey in ($Totals.categoryCounts.Keys | Sort-Object)) {
            $countValue = $Totals.categoryCounts[$categoryKey]
            $meta = Get-VICategoryMetadata -Name $categoryKey
            $label = if ($meta) { $meta.label } else { $categoryKey }
            $categoryParts.Add("$label ($countValue)") | Out-Null
        }
        if ($categoryParts.Count -gt 0) {
            $summaryLines += ("Categories: $($categoryParts -join ', ')")
        }
    }
    if ($Totals.PSObject.Properties['bucketCounts'] -and $Totals.bucketCounts.Keys.Count -gt 0) {
        $bucketParts = New-Object System.Collections.Generic.List[string]
        foreach ($bucketKey in ($Totals.bucketCounts.Keys | Sort-Object)) {
            $countValue = $Totals.bucketCounts[$bucketKey]
            $bucketMeta = Get-VIBucketMetadata -BucketSlug $bucketKey
            $label = if ($bucketMeta) { $bucketMeta.label } else { $bucketKey }
            $bucketParts.Add("$label ($countValue)") | Out-Null
        }
        if ($bucketParts.Count -gt 0) {
            $summaryLines += ("Buckets: $($bucketParts -join ', ')")
        }
    }

    return ($summaryLines + '' + $rows) -join "`n"
}

function Build-HtmlReport {
    param(
        [pscustomobject[]]$Pairs,
        [pscustomobject]$Totals,
        [string]$CompareDir,
        [string]$HtmlRoot
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('<!DOCTYPE html>') | Out-Null
    $lines.Add('<html lang="en">') | Out-Null
    $lines.Add('<head>') | Out-Null
    $lines.Add('  <meta charset="utf-8">') | Out-Null
    $lines.Add('  <meta name="viewport" content="width=device-width, initial-scale=1">') | Out-Null
    $lines.Add('  <title>VI Compare Summary</title>') | Out-Null
    $lines.Add('  <style>') | Out-Null
    $lines.Add('    body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; color: #111; }') | Out-Null
    $lines.Add('    h1 { margin: 0 0 8px 0; }') | Out-Null
    $lines.Add('    .meta { margin: 0 0 12px 0; color: #333; }') | Out-Null
    $lines.Add('    table { border-collapse: collapse; width: 100%; }') | Out-Null
    $lines.Add('    th, td { border: 1px solid #ccc; padding: 8px; text-align: left; vertical-align: top; }') | Out-Null
    $lines.Add('    th { background: #f2f2f2; }') | Out-Null
    $lines.Add('    .status-diff { color: #7a1515; font-weight: 700; }') | Out-Null
    $lines.Add('    .status-match { color: #155724; font-weight: 700; }') | Out-Null
    $lines.Add('    .status-error { color: #8a6d3b; font-weight: 700; }') | Out-Null
    $lines.Add('    .status-skipped { color: #555; font-weight: 700; }') | Out-Null
    $lines.Add('    .mono { font-family: Consolas, Menlo, monospace; font-size: 12px; }') | Out-Null
    $lines.Add('  </style>') | Out-Null
    $lines.Add('</head>') | Out-Null
    $lines.Add('<body>') | Out-Null
    $lines.Add('  <h1>VI Compare Summary</h1>') | Out-Null
    $summaryText = "Totals: diff=$($Totals.diff), match=$($Totals.match), skipped=$($Totals.skipped), error=$($Totals.error), leaks=$($Totals.leakWarnings)"
    $lines.Add("  <p class=`"meta`">$([System.Net.WebUtility]::HtmlEncode($summaryText))</p>") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($CompareDir)) {
        $lines.Add("  <p class=`"meta`">Artifacts root: <span class=`"mono`">$([System.Net.WebUtility]::HtmlEncode(($CompareDir -replace '\\','/')))</span></p>") | Out-Null
    }
    $lines.Add('  <table>') | Out-Null
    $lines.Add('    <thead><tr><th>Pair</th><th>Target</th><th>Status</th><th>Exit</th><th>Categories</th><th>Details</th><th>Report</th><th>Capture</th></tr></thead>') | Out-Null
    $lines.Add('    <tbody>') | Out-Null

    foreach ($pair in $Pairs) {
        $pairLabel = Convert-ToSafeHtmlText -Value ("Pair {0} ({1})" -f $pair.index, $pair.changeType)
        $targetText = if (-not [string]::IsNullOrWhiteSpace([string]$pair.headPath)) { [string]$pair.headPath } else { [string]$pair.basePath }
        $targetCell = Convert-ToSafeHtmlText -Value $targetText
        $statusRaw = [string]$pair.status
        $statusClass = switch ($statusRaw) {
            'diff'    { 'status-diff' }
            'match'   { 'status-match' }
            'error'   { 'status-error' }
            'skipped' { 'status-skipped' }
            default   { '' }
        }
        $statusCell = Convert-ToSafeHtmlText -Value $statusRaw
        $exitCell = if ($null -ne $pair.exitCode) { Convert-ToSafeHtmlText -Value ([string]$pair.exitCode) } else { '-' }

        $categoryValues = New-Object System.Collections.Generic.List[string]
        if ($pair.PSObject.Properties['diffCategoryDetails'] -and $pair.diffCategoryDetails) {
            foreach ($detail in $pair.diffCategoryDetails) {
                if (-not $detail) { continue }
                $label = if ($detail.PSObject.Properties['label'] -and $detail.label) { [string]$detail.label } else { [string]$detail.slug }
                if (-not [string]::IsNullOrWhiteSpace($label)) {
                    $categoryValues.Add($label) | Out-Null
                }
            }
        } elseif ($pair.PSObject.Properties['diffCategories'] -and $pair.diffCategories) {
            foreach ($category in $pair.diffCategories) {
                if (-not [string]::IsNullOrWhiteSpace([string]$category)) {
                    $categoryValues.Add([string]$category) | Out-Null
                }
            }
        }
        $categoriesCell = if ($categoryValues.Count -gt 0) {
            Convert-ToSafeHtmlText -Value ($categoryValues -join ', ')
        } else {
            '-'
        }

        $detailValues = @()
        if ($pair.PSObject.Properties['diffDetailPreview'] -and $pair.diffDetailPreview) {
            $detailValues = @($pair.diffDetailPreview | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 3)
        }
        $detailsCell = if ($detailValues.Count -gt 0) {
            (Convert-ToSafeHtmlText -Value ($detailValues -join '; '))
        } else {
            '-'
        }

        $reportHref = if ($pair.PSObject.Properties['reportPath']) { Convert-ToHtmlHref -BasePath $HtmlRoot -TargetPath ([string]$pair.reportPath) } else { $null }
        $reportCell = if (-not [string]::IsNullOrWhiteSpace($reportHref)) {
            "<a href=`"$reportHref`">compare-report</a>"
        } else {
            '-'
        }

        $captureHref = if ($pair.PSObject.Properties['capturePath']) { Convert-ToHtmlHref -BasePath $HtmlRoot -TargetPath ([string]$pair.capturePath) } else { $null }
        $captureCell = if (-not [string]::IsNullOrWhiteSpace($captureHref)) {
            "<a href=`"$captureHref`">capture-json</a>"
        } else {
            '-'
        }

        $lines.Add("      <tr><td>$pairLabel</td><td><span class=`"mono`">$targetCell</span></td><td class=`"$statusClass`">$statusCell</td><td>$exitCell</td><td>$categoriesCell</td><td>$detailsCell</td><td>$reportCell</td><td>$captureCell</td></tr>") | Out-Null
    }

    $lines.Add('    </tbody>') | Out-Null
    $lines.Add('  </table>') | Out-Null
    $lines.Add('</body>') | Out-Null
    $lines.Add('</html>') | Out-Null

    return ($lines -join "`n")
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
    diff         = 0
    match        = 0
    skipped      = 0
    error        = 0
    leakWarnings = 0
    categoryCounts = [ordered]@{}
    bucketCounts   = [ordered]@{}
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

    $capturePath = $null
    if ($entry.PSObject.Properties['capturePath']) {
        $capturePath = Resolve-ExistingFile -Path $entry.capturePath
    }
    if (-not $capturePath) {
        $capturePath = Find-CapturePath -Entry $entry -CompareDir $compareRoot
        if ($capturePath) {
            try { $entry | Add-Member -NotePropertyName capturePath -NotePropertyValue $capturePath -Force } catch {}
        }
    }

    $reportPath = $null
    if ($entry.PSObject.Properties['reportPath']) {
        $reportPath = Resolve-ExistingFile -Path $entry.reportPath
    }
    if (-not $reportPath) {
        $reportPath = Find-ReportPath -Entry $entry -CompareDir $compareRoot -CapturePath $capturePath
        if ($reportPath) {
            try { $entry | Add-Member -NotePropertyName reportPath -NotePropertyValue $reportPath -Force } catch {}
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

    $hasBlockDiagramCosmetic = $false
    if ($htmlContent) {
        $patternCosmeticHeading = '<summary\s+class="[^"]*\bdifference-cosmetic-heading\b[^"]*"\s*>'
        if ([System.Text.RegularExpressions.Regex]::IsMatch($htmlContent, $patternCosmeticHeading, 'IgnoreCase')) {
            $hasBlockDiagramCosmetic = $true
        } else {
            $patternCosmeticDetail = '<li\s+class="[^"]*\bdiff-detail-cosmetic\b[^"]*"\s*>'
            if ([System.Text.RegularExpressions.Regex]::IsMatch($htmlContent, $patternCosmeticDetail, 'IgnoreCase')) {
                $hasBlockDiagramCosmetic = $true
            }
        }
    }
    if ($hasBlockDiagramCosmetic -and -not $categories.Contains('Block Diagram Cosmetic')) {
        $categories.Add('Block Diagram Cosmetic')
    }

    if ($categories.Count -eq 0 -and ($details -and $details.Count -gt 0)) {
        $fallbackCategories = Infer-DiffCategoriesFromDetails -Details $details
        foreach ($name in $fallbackCategories) {
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $categories.Contains($name)) {
                $categories.Add($name) | Out-Null
            }
        }
    }

    $categoryDetails = Get-CategoryDetailsFromNames -Names $categories
    $bucketDetails = New-Object System.Collections.Generic.List[pscustomobject]
    $bucketSlugs = New-Object System.Collections.Generic.List[string]
    if ($categoryDetails -and $categoryDetails.Count -gt 0) {
        $bucketSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($detail in $categoryDetails) {
            if (-not $detail) { continue }
            $slugKey = [string]$detail.slug
            if (-not [string]::IsNullOrWhiteSpace($slugKey)) {
                if (-not $totals.categoryCounts.Contains($slugKey)) {
                    $totals.categoryCounts[$slugKey] = 0
                }
                try {
                    $totals.categoryCounts[$slugKey] += 1
                } catch {
                    $totals.categoryCounts[$slugKey] = ($totals.categoryCounts[$slugKey] + 1)
                }
            }

            $bucketSlug = $null
            if ($detail.PSObject.Properties['bucketSlug']) {
                $bucketSlug = [string]$detail.bucketSlug
            }
            if (-not [string]::IsNullOrWhiteSpace($bucketSlug)) {
                if (-not $totals.bucketCounts.Contains($bucketSlug)) {
                    $totals.bucketCounts[$bucketSlug] = 0
                }
                try {
                    $totals.bucketCounts[$bucketSlug] += 1
                } catch {
                    $totals.bucketCounts[$bucketSlug] = ($totals.bucketCounts[$bucketSlug] + 1)
                }
                if ($bucketSeen.Add($bucketSlug)) {
                    $bucketMeta = Get-VIBucketMetadata -BucketSlug $bucketSlug
                    if ($bucketMeta) {
                        $bucketDetails.Add($bucketMeta) | Out-Null
                    }
                    $bucketSlugs.Add($bucketSlug) | Out-Null
                }
            }
        }
    }

    $includedList = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($key in $included.Keys) {
        $includedList.Add([pscustomobject]@{
            name  = $key
            value = [bool]$included[$key]
        })
    }
    $diffDetected = $false
    if ($entry.PSObject.Properties['diffDetected'] -and $entry.diffDetected) {
        $diffDetected = $true
    }
    if (-not $diffDetected -and $categoryDetails -and $categoryDetails.Count -gt 0) {
        $diffDetected = $true
    }
    if ($diffDetected -and $status -ne 'diff') {
        $status = 'diff'
    }

    $detailPreviewList = Get-DiffDetailPreview -Details $details -Headings $headings -Status $status

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

    $leakWarning = $false
    if ($entry.PSObject.Properties['leakWarning']) {
        try { $leakWarning = [bool]$entry.leakWarning } catch { $leakWarning = $entry.leakWarning }
    }
    $leakPath = $null
    $lvLeak = $null
    $labLeak = $null
    if ($entry.PSObject.Properties['leakLvcompare']) {
        $lvLeak = $entry.leakLvcompare
    } elseif ($entry.PSObject.Properties['leak'] -and $entry.leak -and $entry.leak.PSObject.Properties['lvcompare']) {
        $lvLeak = $entry.leak.lvcompare
    }
    if ($entry.PSObject.Properties['leakLabVIEW']) {
        $labLeak = $entry.leakLabVIEW
    } elseif ($entry.PSObject.Properties['leak'] -and $entry.leak -and $entry.leak.PSObject.Properties['labview']) {
        $labLeak = $entry.leak.labview
    }
    if ($entry.PSObject.Properties['leakPath'] -and $entry.leakPath) {
        $leakPath = $entry.leakPath
    } elseif ($entry.PSObject.Properties['leak'] -and $entry.leak -and $entry.leak.PSObject.Properties['path'] -and $entry.leak.path) {
        $leakPath = $entry.leak.path
    }
    $lvLeakInt = $null
    $labLeakInt = $null
    if ($lvLeak -ne $null) {
        try { $lvLeakInt = [int]$lvLeak } catch { $lvLeakInt = $lvLeak }
    }
    if ($labLeak -ne $null) {
        try { $labLeakInt = [int]$labLeak } catch { $labLeakInt = $labLeak }
    }
    if (($lvLeakInt -ne $null -and $lvLeakInt -gt 0) -or ($labLeakInt -ne $null -and $labLeakInt -gt 0)) {
        $leakWarning = $true
    }
    if ($leakWarning -and $totals.Contains('leakWarnings')) {
        $totals.leakWarnings++
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
        diffCategories    = @($categories.ToArray())
        diffCategoryDetails = @($categoryDetails)
        diffBuckets       = @($bucketSlugs.ToArray())
        diffBucketDetails = @($bucketDetails.ToArray())
        diffHeadings      = $headings
        diffDetails       = $details
        diffDetailPreview = $detailPreviewList
        includedAttributes= $includedList
        leakWarning       = $leakWarning
        leakLvcompare     = $lvLeakInt
        leakLabVIEW       = $labLeakInt
        leakPath          = $leakPath
    }

    if ($diffDetected) {
        try { $pairInfo | Add-Member -NotePropertyName diffDetected -NotePropertyValue $true -Force } catch {}
    }

    $modeSummaries = New-Object System.Collections.Generic.List[pscustomobject]
    if ($entry.PSObject.Properties['modes'] -and $entry.modes) {
        foreach ($modeEntry in $entry.modes) {
            if (-not $modeEntry) { continue }
            $modeName = if ($modeEntry.PSObject.Properties['name']) { [string]$modeEntry.name } else { $null }
            if ([string]::IsNullOrWhiteSpace($modeName)) { $modeName = 'mode' }
            $modeStatus = if ($modeEntry.PSObject.Properties['status']) { [string]$modeEntry.status } else { $null }
            $modeDiffDetected = $false
            if ($modeEntry.PSObject.Properties['diffDetected'] -and $modeEntry.diffDetected) {
                $modeDiffDetected = $true
            }
            if ($modeDiffDetected -and $modeStatus -ne 'diff') {
                $modeStatus = 'diff'
            }
            $modeFlags = @()
            if ($modeEntry.PSObject.Properties['flags'] -and $modeEntry.flags) {
                $modeFlags = @($modeEntry.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            $modeSummary = [pscustomobject]@{
                name   = $modeName
                status = $modeStatus
                flags  = $modeFlags
            }
            if ($modeDiffDetected) {
                try { $modeSummary | Add-Member -NotePropertyName diffDetected -NotePropertyValue $true -Force } catch {}
            }
            if ($modeEntry.PSObject.Properties['replace']) {
                try { $modeSummary | Add-Member -NotePropertyName replace -NotePropertyValue ([bool]$modeEntry.replace) -Force } catch {}
            }
            $modeSummaries.Add($modeSummary) | Out-Null
        }
    }
    if ($modeSummaries.Count -gt 0) {
        if ($entry.PSObject.Properties['primaryMode']) {
            $pairInfo | Add-Member -NotePropertyName primaryMode -NotePropertyValue $entry.primaryMode -Force
        }
        $pairInfo | Add-Member -NotePropertyName modeSummaries -NotePropertyValue @($modeSummaries.ToArray()) -Force
        $pairInfo | Add-Member -NotePropertyName flagSummary -NotePropertyValue (Format-ModeFlags @($modeSummaries.ToArray())) -Force
    } elseif ($entry.PSObject.Properties['flags']) {
        $fallbackFlags = @()
        if ($entry.flags) {
            $fallbackFlags = @($entry.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        $fallbackSummary = @([pscustomobject]@{
            name   = if ($entry.PSObject.Properties['primaryMode']) { [string]$entry.primaryMode } else { 'primary' }
            status = $status
            flags  = $fallbackFlags
        })
        $pairInfo | Add-Member -NotePropertyName flagSummary -NotePropertyValue (Format-ModeFlags $fallbackSummary) -Force
    } else {
        $pairInfo | Add-Member -NotePropertyName flagSummary -NotePropertyValue '_none_' -Force
    }

    $pairs.Add($pairInfo)

    if ($totals.Contains($status)) {
        $totals[$status]++
    }
}

$sortedCategoryTotals = [ordered]@{}
foreach ($categoryKey in ($totals.categoryCounts.Keys | Sort-Object)) {
    $sortedCategoryTotals[$categoryKey] = [int]$totals.categoryCounts[$categoryKey]
}
$totals.categoryCounts = $sortedCategoryTotals

$sortedBucketTotals = [ordered]@{}
foreach ($bucketKey in ($totals.bucketCounts.Keys | Sort-Object)) {
    $sortedBucketTotals[$bucketKey] = [int]$totals.bucketCounts[$bucketKey]
}
$totals.bucketCounts = $sortedBucketTotals

$totalsObj = [pscustomobject]$totals
$markdown = Build-MarkdownTable -Pairs $pairs -Totals $totalsObj -CompareDir $compareRoot
$html = $null
$resolvedHtmlPath = $null
if ($HtmlPath) {
    $resolvedHtmlPath = [System.IO.Path]::GetFullPath($HtmlPath)
    $htmlRoot = Split-Path -Parent $resolvedHtmlPath
    if (-not [string]::IsNullOrWhiteSpace($htmlRoot)) {
        New-Item -ItemType Directory -Path $htmlRoot -Force | Out-Null
    }
    $html = Build-HtmlReport -Pairs $pairs -Totals $totalsObj -CompareDir $compareRoot -HtmlRoot $htmlRoot
    $html | Set-Content -LiteralPath $resolvedHtmlPath -Encoding utf8
}

$result = [pscustomobject]@{
    totals     = $totalsObj
    pairs      = $pairs
    markdown   = $markdown
    html       = $html
    htmlPath   = $resolvedHtmlPath
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
    if ($resolvedHtmlPath) {
        "summary_html=$resolvedHtmlPath" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
    if ($compareRoot) {
        "compare_dir=$compareRoot" | Out-File -FilePath $Env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}

return $result
