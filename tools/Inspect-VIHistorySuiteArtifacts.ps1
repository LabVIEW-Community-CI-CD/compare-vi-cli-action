#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,

  [string]$HistoryReportPath,
  [string]$HistorySummaryPath,
  [string]$OutputJsonPath,
  [string]$OutputHtmlPath,
  [string]$GitHubOutputPath = $env:GITHUB_OUTPUT,
  [string]$GitHubStepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ExistingDirectory {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw ("{0} path not provided." -f $Description)
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw ("{0} not found: {1}" -f $Description, $Path)
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-ExistingFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Description
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw ("{0} path not provided." -f $Description)
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ("{0} not found: {1}" -f $Description, $Path)
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-OutputPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Get-RelativePathSafe {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return [System.IO.Path]::GetRelativePath($BasePath, $Path).Replace('\', '/')
}

function ConvertTo-HtmlSafe {
  param([AllowEmptyString()][string]$Value)
  return [System.Net.WebUtility]::HtmlEncode(($Value ?? ''))
}

function Write-GitHubOutput {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [AllowEmptyString()][string]$Value,
    [AllowEmptyString()][string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $dest = [System.IO.Path]::GetFullPath($Path)
  $parent = Split-Path -Parent $dest
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  Add-Content -LiteralPath $dest -Value ("{0}={1}" -f $Key, ($Value ?? '')) -Encoding utf8
}

function Resolve-ImageSource {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$ReportDirectory
  )

  if ([string]::IsNullOrWhiteSpace($Source)) {
    return [pscustomobject]@{
      sourceType = 'invalid'
      resolvedPath = ''
      exists = $false
      status = 'invalid'
      message = 'Image source is empty.'
      previewSrc = ''
    }
  }

  if ($Source -match '^(?i)data:') {
    return [pscustomobject]@{
      sourceType = 'embedded'
      resolvedPath = ''
      exists = $true
      status = 'embedded'
      message = ''
      previewSrc = $Source
    }
  }

  $uri = $null
  if ([System.Uri]::TryCreate($Source, [System.UriKind]::Absolute, [ref]$uri)) {
    if ($uri.IsFile) {
      $path = $uri.LocalPath
      return [pscustomobject]@{
        sourceType = 'file'
        resolvedPath = $path
        exists = (Test-Path -LiteralPath $path -PathType Leaf)
        status = if (Test-Path -LiteralPath $path -PathType Leaf) { 'ok' } else { 'missing' }
        message = ''
        previewSrc = ''
      }
    }

    return [pscustomobject]@{
      sourceType = 'external'
      resolvedPath = ''
      exists = $false
      status = 'external'
      message = ('External URI scheme is not artifact-local: {0}' -f $uri.Scheme)
      previewSrc = $Source
    }
  }

  $candidatePath = if ([System.IO.Path]::IsPathRooted($Source)) {
    $Source
  } else {
    Join-Path $ReportDirectory $Source
  }

  $exists = Test-Path -LiteralPath $candidatePath -PathType Leaf
  return [pscustomobject]@{
    sourceType = 'file'
    resolvedPath = $candidatePath
    exists = $exists
    status = if ($exists) { 'ok' } else { 'missing' }
    message = if ($exists) { '' } else { ('Image source not found: {0}' -f $candidatePath) }
    previewSrc = ''
  }
}

$resultsDirResolved = Resolve-ExistingDirectory -Path $ResultsDir -Description 'VI history results directory'
$effectiveHistoryReportPath = if ([string]::IsNullOrWhiteSpace($HistoryReportPath)) {
  Join-Path $resultsDirResolved 'history-report.html'
} else {
  Resolve-OutputPath -Path $HistoryReportPath -BasePath $resultsDirResolved
}
$effectiveHistorySummaryPath = if ([string]::IsNullOrWhiteSpace($HistorySummaryPath)) {
  Join-Path $resultsDirResolved 'history-summary.json'
} else {
  Resolve-OutputPath -Path $HistorySummaryPath -BasePath $resultsDirResolved
}
$historyReportResolved = Resolve-ExistingFile -Path $effectiveHistoryReportPath -Description 'VI history consolidated HTML report'
$historySummaryResolved = Resolve-ExistingFile -Path $effectiveHistorySummaryPath -Description 'VI history summary JSON'
$suiteManifestResolved = Resolve-ExistingFile -Path (Join-Path $resultsDirResolved 'suite-manifest.json') -Description 'VI history suite manifest'

$effectiveOutputJsonPath = if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
  Join-Path $resultsDirResolved 'history-suite-inspection.json'
} else {
  Resolve-OutputPath -Path $OutputJsonPath -BasePath $resultsDirResolved
}
$effectiveOutputHtmlPath = if ([string]::IsNullOrWhiteSpace($OutputHtmlPath)) {
  Join-Path $resultsDirResolved 'history-suite-inspection.html'
} else {
  Resolve-OutputPath -Path $OutputHtmlPath -BasePath $resultsDirResolved
}

$historyHtml = Get-Content -LiteralPath $historyReportResolved -Raw -ErrorAction Stop
$historySummary = Get-Content -LiteralPath $historySummaryResolved -Raw | ConvertFrom-Json -Depth 24
$suiteManifest = Get-Content -LiteralPath $suiteManifestResolved -Raw | ConvertFrom-Json -Depth 24

$modeEntries = @()
if ($suiteManifest.PSObject.Properties['modes'] -and $suiteManifest.modes) {
  $modeEntries = @($suiteManifest.modes)
}

$pairInspections = @()
$imageTagPattern = '<img\b[^>]*?\bsrc\s*=\s*(["''])(?<src>.*?)\1[^>]*>'
$regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline

$missingReports = 0
$reportsWithoutImages = 0
$missingImages = 0
$externalImages = 0
$embeddedImages = 0
$resolvedImages = 0

foreach ($modeEntry in @($modeEntries)) {
  $modeSlug = if ($modeEntry.PSObject.Properties['slug'] -and -not [string]::IsNullOrWhiteSpace([string]$modeEntry.slug)) {
    [string]$modeEntry.slug
  } elseif ($modeEntry.PSObject.Properties['name']) {
    [string]$modeEntry.name
  } else {
    'default'
  }

  $modeManifestPath = Join-Path (Join-Path $resultsDirResolved $modeSlug) 'manifest.json'
  $modeManifest = Get-Content -LiteralPath $modeManifestPath -Raw | ConvertFrom-Json -Depth 24
  $comparisons = if ($modeManifest.PSObject.Properties['comparisons'] -and $modeManifest.comparisons) {
    @($modeManifest.comparisons)
  } else {
    @()
  }

  foreach ($comparison in @($comparisons)) {
    $pairIndex = if ($comparison.PSObject.Properties['index']) { [int]$comparison.index } else { 0 }
    $outName = if ($comparison.PSObject.Properties['outName']) { [string]$comparison.outName } else { ('pair-{0:d3}' -f $pairIndex) }
    $comparisonResult = if ($comparison.PSObject.Properties['result'] -and $comparison.result) {
      $comparison.result
    } else {
      $null
    }
    $hostReportPath = Join-Path (Join-Path $resultsDirResolved $modeSlug) ("{0}-report.html" -f $outName)
    $hostReportExists = Test-Path -LiteralPath $hostReportPath -PathType Leaf
    $reportRelativePath = Get-RelativePathSafe -BasePath $resultsDirResolved -Path $hostReportPath
    $reportRelativeDirectory = [System.IO.Path]::GetDirectoryName($reportRelativePath)
    if ([string]::IsNullOrWhiteSpace($reportRelativeDirectory)) {
      $reportRelativeDirectory = ''
    } else {
      $reportRelativeDirectory = $reportRelativeDirectory.Replace('\', '/')
    }
    $reportBaseName = [System.IO.Path]::GetFileNameWithoutExtension($reportRelativePath)
    $previewPrefix = if ([string]::IsNullOrWhiteSpace($reportRelativeDirectory)) {
      ('{0}_files/' -f $reportBaseName)
    } else {
      ('{0}/{1}_files/' -f $reportRelativeDirectory, $reportBaseName)
    }
    $imageEntries = @()
    $pairStatus = 'ok'
    $compareDiff = if ($comparisonResult -and $comparisonResult.PSObject.Properties['diff']) { [bool]$comparisonResult.diff } else { $false }
    $compareStatus = if ($comparisonResult -and $comparisonResult.PSObject.Properties['status']) { [string]$comparisonResult.status } else { '' }

    if (-not $hostReportExists) {
      $missingReports++
      $pairStatus = 'missing-report'
    } else {
      $pairReportHtml = Get-Content -LiteralPath $hostReportPath -Raw -ErrorAction Stop
      $imageMatches = [System.Text.RegularExpressions.Regex]::Matches($pairReportHtml, $imageTagPattern, $regexOptions)
      if ($imageMatches.Count -eq 0) {
        $reportsWithoutImages++
        $pairStatus = 'no-images'
      }

      foreach ($match in $imageMatches) {
        $src = [System.Net.WebUtility]::HtmlDecode($match.Groups['src'].Value.Trim())
        $imageResolution = Resolve-ImageSource -Source $src -ReportDirectory (Split-Path -Parent $hostReportPath)
        $previewSrc = if ($imageResolution.status -eq 'ok') {
          $resolvedPath = (Resolve-Path -LiteralPath $imageResolution.resolvedPath).Path
          Get-RelativePathSafe -BasePath (Split-Path -Parent $effectiveOutputHtmlPath) -Path $resolvedPath
        } else {
          [string]$imageResolution.previewSrc
        }

        switch ([string]$imageResolution.status) {
          'ok' { $resolvedImages++ }
          'embedded' { $embeddedImages++ }
          'external' {
            $externalImages++
            $pairStatus = if ($pairStatus -eq 'ok') { 'invalid-images' } else { $pairStatus }
          }
          'missing' {
            $missingImages++
            $pairStatus = if ($pairStatus -eq 'ok') { 'invalid-images' } else { $pairStatus }
          }
        }

        $imageEntries += [pscustomobject]@{
          source = $src
          sourceType = [string]$imageResolution.sourceType
          status = [string]$imageResolution.status
          resolvedPath = if ([string]::IsNullOrWhiteSpace([string]$imageResolution.resolvedPath)) { '' } else { [System.IO.Path]::GetFullPath([string]$imageResolution.resolvedPath) }
          relativePath = if ($imageResolution.status -eq 'ok') { Get-RelativePathSafe -BasePath $resultsDirResolved -Path ([System.IO.Path]::GetFullPath([string]$imageResolution.resolvedPath)) } else { '' }
          previewSrc = $previewSrc
          message = [string]$imageResolution.message
        }
      }
    }

    $pairInspections += [pscustomobject]@{
      mode = $modeSlug
      index = $pairIndex
      outName = $outName
      diff = $compareDiff
      compareStatus = $compareStatus
      reportPath = $hostReportPath
      reportRelativePath = $reportRelativePath
      previewPrefix = $previewPrefix
      inspectionStatus = $pairStatus
      imageCount = $imageEntries.Count
      images = @($imageEntries)
    }
  }
}

$historyLinkPattern = '<a\b[^>]*href\s*=\s*(["''])(?<href>.*?)\1[^>]*>'
$historyLinkMatches = [System.Text.RegularExpressions.Regex]::Matches($historyHtml, $historyLinkPattern, $regexOptions)
$historyLinkTargets = @(
  $historyLinkMatches |
    ForEach-Object {
      $hrefValue = [System.Net.WebUtility]::HtmlDecode($_.Groups['href'].Value.Trim())
      if ([string]::IsNullOrWhiteSpace($hrefValue)) {
        return
      }
      if ($hrefValue.StartsWith('./')) {
        return $hrefValue.Substring(2)
      }
      return $hrefValue
    } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$historyPreviewEntries = @()
$historyPreviewMatches = [System.Text.RegularExpressions.Regex]::Matches($historyHtml, $imageTagPattern, $regexOptions)
$historyPreviewResolvedImages = 0
$historyPreviewMissingImages = 0
$historyPreviewExternalImages = 0
$historyPreviewEmbeddedImages = 0

foreach ($match in $historyPreviewMatches) {
  $src = [System.Net.WebUtility]::HtmlDecode($match.Groups['src'].Value.Trim())
  $imageResolution = Resolve-ImageSource -Source $src -ReportDirectory (Split-Path -Parent $historyReportResolved)
  $normalizedSource = if ($src.StartsWith('./')) { $src.Substring(2) } else { $src }
  switch ([string]$imageResolution.status) {
    'ok' { $historyPreviewResolvedImages++ }
    'embedded' { $historyPreviewEmbeddedImages++ }
    'external' { $historyPreviewExternalImages++ }
    'missing' { $historyPreviewMissingImages++ }
  }

  $historyPreviewEntries += [pscustomobject]@{
    source = $src
    normalizedSource = $normalizedSource
    status = [string]$imageResolution.status
    sourceType = [string]$imageResolution.sourceType
    resolvedPath = if ([string]::IsNullOrWhiteSpace([string]$imageResolution.resolvedPath)) { '' } else { [System.IO.Path]::GetFullPath([string]$imageResolution.resolvedPath) }
    relativePath = if ($imageResolution.status -eq 'ok') { Get-RelativePathSafe -BasePath $resultsDirResolved -Path ([System.IO.Path]::GetFullPath([string]$imageResolution.resolvedPath)) } else { '' }
    message = [string]$imageResolution.message
  }
}

$missingHistoryLinks = 0
$pairsWithoutHistoryPreview = 0
foreach ($pair in @($pairInspections)) {
  $linkPresent = $historyLinkTargets -contains [string]$pair.reportRelativePath
  $suitePreviewMatchCount = @(
    $historyPreviewEntries |
      Where-Object {
        [string]::Equals([string]$_.status, 'ok', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]$_.normalizedSource -like ("{0}*" -f [string]$pair.previewPrefix)
      }
  ).Count

  if (-not $linkPresent) {
    $missingHistoryLinks++
  }
  if ($suitePreviewMatchCount -lt 1) {
    $pairsWithoutHistoryPreview++
  }

  $pair | Add-Member -NotePropertyName historyReportLinkPresent -NotePropertyValue $linkPresent -Force
  $pair | Add-Member -NotePropertyName suitePreviewMatchCount -NotePropertyValue $suitePreviewMatchCount -Force
}

$historyLinkCount = [System.Text.RegularExpressions.Regex]::Matches($historyHtml, 'pair-\d+-report\.html', $regexOptions).Count
$historyRelativeLinkCount = [System.Text.RegularExpressions.Regex]::Matches($historyHtml, '<a\b[^>]*href\s*=\s*(["''])(?<href>[^"'']*pair-\d+-report\.html)\1', $regexOptions).Count
$historyContainerPathCount = [System.Text.RegularExpressions.Regex]::Matches($historyHtml, '/opt/comparevi/vi-history/results/[^<"]*pair-\d+-report\.html', $regexOptions).Count

$overallStatus = 'ok'
if (
  $pairInspections.Count -eq 0 -or
  $missingReports -gt 0 -or
  $reportsWithoutImages -gt 0 -or
  $missingImages -gt 0 -or
  $externalImages -gt 0 -or
  $historyContainerPathCount -gt 0 -or
  $missingHistoryLinks -gt 0 -or
  $pairsWithoutHistoryPreview -gt 0 -or
  $historyPreviewMissingImages -gt 0 -or
  $historyPreviewExternalImages -gt 0
) {
  $overallStatus = 'failed'
}

$inspectionPayload = [ordered]@{
  schema = 'vi-history-suite-inspection@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  overallStatus = $overallStatus
  consolidatedHistoryReport = [ordered]@{
    path = $historyReportResolved
    relativePath = Get-RelativePathSafe -BasePath $resultsDirResolved -Path $historyReportResolved
    pairReferenceCount = $historyLinkCount
    relativeLinkCount = $historyRelativeLinkCount
    containerPathReferenceCount = $historyContainerPathCount
    previewImageCount = $historyPreviewEntries.Count
    previewResolvedImages = $historyPreviewResolvedImages
    previewEmbeddedImages = $historyPreviewEmbeddedImages
    previewMissingImages = $historyPreviewMissingImages
    previewExternalImages = $historyPreviewExternalImages
  }
  summary = [ordered]@{
    comparisons = $pairInspections.Count
    missingReports = $missingReports
    reportsWithoutImages = $reportsWithoutImages
    resolvedImages = $resolvedImages
    embeddedImages = $embeddedImages
    missingImages = $missingImages
    externalImages = $externalImages
    missingHistoryLinks = $missingHistoryLinks
    pairsWithoutHistoryPreview = $pairsWithoutHistoryPreview
  }
  historySummary = [ordered]@{
    path = $historySummaryResolved
    reportHtmlPath = if ($historySummary.PSObject.Properties['reports'] -and $historySummary.reports.PSObject.Properties['htmlPath']) { [string]$historySummary.reports.htmlPath } else { '' }
    reportMarkdownPath = if ($historySummary.PSObject.Properties['reports'] -and $historySummary.reports.PSObject.Properties['markdownPath']) { [string]$historySummary.reports.markdownPath } else { '' }
  }
  pairs = @($pairInspections)
}

New-Item -ItemType Directory -Path (Split-Path -Parent $effectiveOutputJsonPath) -Force | Out-Null
New-Item -ItemType Directory -Path (Split-Path -Parent $effectiveOutputHtmlPath) -Force | Out-Null
$inspectionPayload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $effectiveOutputJsonPath -Encoding utf8

$htmlLines = @(
  '<html><body><h1>VI history suite inspection</h1>',
  '<p>This inspection validates that each host-side pair report exists and that every referenced difference image resolves inside the uploaded artifact tree.</p>',
  '<h2>Summary</h2>',
  '<table border="1" cellspacing="0" cellpadding="4"><tbody>',
  ('<tr><th>Overall status</th><td>{0}</td></tr>' -f (ConvertTo-HtmlSafe $overallStatus)),
  ('<tr><th>Comparisons</th><td>{0}</td></tr>' -f $pairInspections.Count),
  ('<tr><th>Missing reports</th><td>{0}</td></tr>' -f $missingReports),
  ('<tr><th>Reports without images</th><td>{0}</td></tr>' -f $reportsWithoutImages),
  ('<tr><th>Missing images</th><td>{0}</td></tr>' -f $missingImages),
  ('<tr><th>External images</th><td>{0}</td></tr>' -f $externalImages),
  ('<tr><th>Resolved images</th><td>{0}</td></tr>' -f $resolvedImages),
  ('<tr><th>Embedded images</th><td>{0}</td></tr>' -f $embeddedImages),
  ('<tr><th>Missing history links</th><td>{0}</td></tr>' -f $missingHistoryLinks),
  ('<tr><th>Pairs without suite previews</th><td>{0}</td></tr>' -f $pairsWithoutHistoryPreview),
  '</tbody></table>',
  '<h2>Consolidated report diagnostics</h2>',
  '<table border="1" cellspacing="0" cellpadding="4"><tbody>',
  ('<tr><th>History report</th><td><a href="./{0}">{1}</a></td></tr>' -f (Get-RelativePathSafe -BasePath (Split-Path -Parent $effectiveOutputHtmlPath) -Path $historyReportResolved), (ConvertTo-HtmlSafe (Split-Path -Leaf $historyReportResolved))),
  ('<tr><th>Pair references</th><td>{0}</td></tr>' -f $historyLinkCount),
  ('<tr><th>Relative links</th><td>{0}</td></tr>' -f $historyRelativeLinkCount),
  ('<tr><th>Container path references</th><td>{0}</td></tr>' -f $historyContainerPathCount),
  ('<tr><th>Preview images</th><td>{0}</td></tr>' -f $historyPreviewEntries.Count),
  ('<tr><th>Resolved suite previews</th><td>{0}</td></tr>' -f $historyPreviewResolvedImages),
  ('<tr><th>Missing suite previews</th><td>{0}</td></tr>' -f $historyPreviewMissingImages),
  ('<tr><th>External suite previews</th><td>{0}</td></tr>' -f $historyPreviewExternalImages),
  '</tbody></table>',
  '<h2>Pair inspections</h2>',
  '<table border="1" cellspacing="0" cellpadding="4">',
  '<thead><tr><th>Mode</th><th>Pair</th><th>Status</th><th>Report</th><th>History link</th><th>Suite previews</th><th>Image count</th><th>Preview</th></tr></thead>',
  '<tbody>'
)

foreach ($pair in @($pairInspections)) {
  $previewParts = @()
  if ($pair.images.Count -eq 0) {
    $previewParts += '<span>none</span>'
  } else {
    foreach ($image in @($pair.images)) {
      if ([string]::Equals([string]$image.status, 'ok', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals([string]$image.status, 'embedded', [System.StringComparison]::OrdinalIgnoreCase)) {
        $previewParts += ('<img src="{0}" alt="{1}" style="max-width:180px; max-height:180px; margin:4px; border:1px solid #d0d7de;" />' -f (ConvertTo-HtmlSafe [string]$image.previewSrc), (ConvertTo-HtmlSafe [string]$image.source))
      } else {
        $previewParts += ('<div><code>{0}</code>: {1}</div>' -f (ConvertTo-HtmlSafe [string]$image.source), (ConvertTo-HtmlSafe [string]$image.message))
      }
    }
  }

  $reportCell = if (Test-Path -LiteralPath $pair.reportPath -PathType Leaf) {
    ('<a href="./{0}">{1}</a>' -f (ConvertTo-HtmlSafe [string]$pair.reportRelativePath), (ConvertTo-HtmlSafe [string]$pair.outName))
  } else {
    ('<code>{0}</code>' -f (ConvertTo-HtmlSafe [string]$pair.reportRelativePath))
  }

  $historyLinkCell = if ($pair.historyReportLinkPresent) { 'present' } else { 'missing' }
  $htmlLines += ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td></tr>' -f (ConvertTo-HtmlSafe [string]$pair.mode), [int]$pair.index, (ConvertTo-HtmlSafe [string]$pair.inspectionStatus), $reportCell, (ConvertTo-HtmlSafe $historyLinkCell), [int]$pair.suitePreviewMatchCount, [int]$pair.imageCount, ([string]::Join('', @($previewParts))))
}

$htmlLines += '</tbody></table></body></html>'
$htmlLines -join "`n" | Set-Content -LiteralPath $effectiveOutputHtmlPath -Encoding utf8

if (-not [string]::IsNullOrWhiteSpace($GitHubStepSummaryPath)) {
  @(
    '### VI History Suite Inspection',
    '',
    ('- overall_status: `{0}`' -f $overallStatus),
    ('- comparisons: `{0}`' -f $pairInspections.Count),
    ('- missing_reports: `{0}`' -f $missingReports),
    ('- reports_without_images: `{0}`' -f $reportsWithoutImages),
    ('- missing_images: `{0}`' -f $missingImages),
    ('- missing_history_links: `{0}`' -f $missingHistoryLinks),
    ('- pairs_without_suite_previews: `{0}`' -f $pairsWithoutHistoryPreview),
    ('- inspection_html: `{0}`' -f (Get-RelativePathSafe -BasePath $resultsDirResolved -Path $effectiveOutputHtmlPath))
  ) -join "`n" | Out-File -FilePath $GitHubStepSummaryPath -Append -Encoding utf8
}

Write-GitHubOutput -Key 'vi-history-inspection-json' -Value $effectiveOutputJsonPath -Path $GitHubOutputPath
Write-GitHubOutput -Key 'vi-history-inspection-html' -Value $effectiveOutputHtmlPath -Path $GitHubOutputPath

if ($overallStatus -ne 'ok') {
  throw ("VI history suite inspection failed. missingReports={0}; reportsWithoutImages={1}; missingImages={2}; externalImages={3}; missingHistoryLinks={4}; pairsWithoutHistoryPreview={5}; historyPreviewMissingImages={6}; historyPreviewExternalImages={7}; containerPathReferenceCount={8}" -f $missingReports, $reportsWithoutImages, $missingImages, $externalImages, $missingHistoryLinks, $pairsWithoutHistoryPreview, $historyPreviewMissingImages, $historyPreviewExternalImages, $historyContainerPathCount)
}

return $inspectionPayload
