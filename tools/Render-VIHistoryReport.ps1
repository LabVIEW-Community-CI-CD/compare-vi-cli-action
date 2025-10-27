param(
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [string]$HistoryContextPath,
  [string]$OutputDir,
  [string]$MarkdownPath,
  [string]$HtmlPath,
  [switch]$EmitHtml,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

    foreach ($comparison in @($modeManifest.comparisons)) {
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
        if ($resultNode.PSObject.Properties['artifactDir'] -and $resultNode.artifactDir) {
          $resultPayload.artifactDir = $resultNode.artifactDir
        }
        if ($resultNode.PSObject.Properties['execPath'] -and $resultNode.execPath) {
          $resultPayload.execPath = $resultNode.execPath
        }
        if ($resultNode.PSObject.Properties['command'] -and $resultNode.command) {
          $resultPayload.command = $resultNode.command
        }
      }

      $comparisons.Add([pscustomobject]@{
        mode  = [string](Coalesce $modeName 'unknown')
        index = $comparison.index
        report = $comparison.outName
        base  = [pscustomobject]@{
          full    = $baseNode.ref
          short   = $baseNode.short
          author  = if ($baseMeta) { $baseMeta.authorName } else { $null }
          authorEmail = if ($baseMeta) { $baseMeta.authorEmail } else { $null }
          date    = if ($baseMeta) { $baseMeta.authorDate } else { $null }
          subject = if ($baseMeta) { $baseMeta.subject } else { $null }
        }
        head  = [pscustomobject]@{
          full    = $headNode.ref
          short   = $headNode.short
          author  = if ($headMeta) { $headMeta.authorName } else { $null }
          authorEmail = if ($headMeta) { $headMeta.authorEmail } else { $null }
          date    = if ($headMeta) { $headMeta.authorDate } else { $null }
          subject = if ($headMeta) { $headMeta.subject } else { $null }
        }
        result = [pscustomobject]$resultPayload
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

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# VI History Report')
$summaryLines.Add('')
$summaryLines.Add(('Target: `{0}`' -f (Coalesce $targetPath 'unknown')))
$summaryLines.Add(('Requested Start Ref: `{0}`' -f (Coalesce $requestedStart 'n/a')))
$summaryLines.Add(('Effective Start Ref: `{0}`' -f (Coalesce $startRef 'n/a')))

if ($stats) {
  $summaryLines.Add('')
  $summaryLines.Add('| Metric | Value |')
  $summaryLines.Add('| --- | --- |')
  $summaryLines.Add(('| Modes | {0} |' -f (Coalesce $stats.modes $modeEntries.Count)))
  $summaryLines.Add(('| Comparisons | {0} |' -f (Coalesce $stats.processed 'n/a')))
  $summaryLines.Add(('| Diffs | {0} |' -f (Coalesce $stats.diffs 'n/a')))
  $summaryLines.Add(('| Missing | {0} |' -f (Coalesce $stats.missing 'n/a')))
  if ($stats.errors -ne $null) {
    $summaryLines.Add(('| Errors | {0} |' -f $stats.errors))
  }
}

if ($modeEntries.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('## Mode overview')
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Processed | Diffs | Flags |')
  $summaryLines.Add('| --- | --- | --- | --- |')
  foreach ($mode in $modeEntries) {
    $flagDisplay = '_none_'
    if ($mode.flags) {
      $flags = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($flags.Count -gt 0) {
        $flagDisplay = ($flags | ForEach-Object { ('`{0}`' -f $_) }) -join '<br>'
      }
    }
    $summaryLines.Add(('| {0} | {1} | {2} | {3} |' -f (Coalesce $mode.name 'unknown'), (Coalesce $mode.stats.processed 'n/a'), (Coalesce $mode.stats.diffs 'n/a'), $flagDisplay))
  }
}

$comparisonHtmlRows = New-Object System.Collections.Generic.List[object]
$comparisons = @($historyContext.comparisons)
if ($comparisons.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('## Commit pairs')
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Pair | Base | Head | Diff | Duration (s) | Report |')
  $summaryLines.Add('| --- | --- | --- | --- | --- | --- | --- |')
  $comparisonSubLines = New-Object System.Collections.Generic.List[string]
  foreach ($entry in $comparisons) {
    $baseRef = Coalesce $entry.base.short $entry.base.full
    if ($entry.base.subject) { $baseRef = '{0} ({1})' -f $baseRef, $entry.base.subject }
    $headRef = Coalesce $entry.head.short $entry.head.full
    if ($entry.head.subject) { $headRef = '{0} ({1})' -f $headRef, $entry.head.subject }
    $resultNode = $entry.result
    $hasDiffValue = $resultNode -and $resultNode.PSObject.Properties['diff']
    $diffValue = $hasDiffValue -and ($resultNode.diff -eq $true)
    $statusValue = if ($resultNode -and $resultNode.PSObject.Properties['status']) { [string]$resultNode.status } else { $null }
    $diffCell = if ($hasDiffValue) {
      if ($diffValue) { '**diff**' } else { 'clean' }
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
    $summaryLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f (Coalesce $entry.mode 'n/a'), (Coalesce $entry.index 'n/a'), $baseRef, $headRef, $diffCell, $duration, $reportCell))
    $comparisonSubLines.Add(('<sub>{0} - {1}</sub>' -f $baseRef, $headRef))
    $comparisonHtmlRows.Add([pscustomobject]@{
      Mode       = Coalesce $entry.mode 'n/a'
      Index      = Coalesce $entry.index 'n/a'
      BaseLabel  = $baseRef
      HeadLabel  = $headRef
      Diff       = [bool]$diffValue
      HasDiff    = $hasDiffValue
      Status     = $statusValue
      Duration   = $durationValue
      DurationDisplay = $duration
      ReportPath = $reportPath
      ReportRelative = $reportRelativeNormalized
      ReportDisplay = $reportCell
      ExitCode   = if ($resultNode -and $resultNode.PSObject.Properties['exitCode']) { $resultNode.exitCode } else { $null }
    })
  }
  if ($comparisonSubLines.Count -gt 0) {
    foreach ($subLine in $comparisonSubLines) {
      $summaryLines.Add($subLine)
    }
  }
}

$summaryLines.Add('')
$summaryLines.Add('## Attribute coverage')
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

  if ($modeEntries.Count -gt 0) {
    [void]$htmlBuilder.AppendLine('  <h2>Mode overview</h2>')
    [void]$htmlBuilder.AppendLine('  <table>')
    [void]$htmlBuilder.AppendLine('    <thead><tr><th>Mode</th><th>Processed</th><th>Diffs</th><th>Missing</th><th>Flags</th></tr></thead>')
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($mode in $modeEntries) {
      $modeName = ConvertTo-HtmlSafe (Coalesce $mode.name 'unknown')
      $processed = ConvertTo-HtmlSafe (Coalesce $mode.stats.processed 'n/a')
      $diffCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.diffs 'n/a')
      $missingCount = ConvertTo-HtmlSafe (Coalesce $mode.stats.missing 'n/a')
      $flags = @($mode.flags | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($flags.Count -gt 0) {
        $flagCells = $flags | ForEach-Object { "<code>{0}</code>" -f (ConvertTo-HtmlSafe $_) }
        $flagHtml = ($flagCells -join '<br />')
      } else {
        $flagHtml = '<span class="muted">none</span>'
      }
      [void]$htmlBuilder.AppendLine(("      <tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>" -f $modeName, $processed, $diffCount, $missingCount, $flagHtml))
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
  }

  [void]$htmlBuilder.AppendLine('  <h2>Commit pairs</h2>')
  if ($comparisonHtmlRows.Count -gt 0) {
    [void]$htmlBuilder.AppendLine('  <table>')
    [void]$htmlBuilder.AppendLine('    <thead><tr><th>Mode</th><th>Pair</th><th>Base</th><th>Head</th><th>Diff</th><th>Duration (s)</th><th>Report</th></tr></thead>')
    [void]$htmlBuilder.AppendLine('    <tbody>')
    foreach ($row in $comparisonHtmlRows) {
      $diffClass = if ($row.Diff) { 'diff-yes' } elseif ($row.Status) { 'diff-status' } else { 'diff-no' }
      $diffLabel = if ($row.Diff) { 'Diff' } elseif ($row.Status) { ConvertTo-HtmlSafe $row.Status } else { 'No' }
      $durationDisplay = '<span class="muted">n/a</span>'
      if ($row.DurationDisplay -and $row.DurationDisplay -ne 'n/a') {
        $durationDisplay = ConvertTo-HtmlSafe $row.DurationDisplay
      } elseif ($row.Duration -ne $null) {
        $durationDisplay = ('{0:N2}' -f $row.Duration)
      }
      $reportHtml = '<span class="muted">missing</span>'
      if ($row.ReportRelative) {
        $reportHref = $row.ReportRelative -replace '\\','/'
        $reportHtml = ('<a href="{0}">report</a>' -f (ConvertTo-HtmlSafe $reportHref))
      } elseif ($row.ReportPath) {
        $reportHtml = ('<code>{0}</code>' -f (ConvertTo-HtmlSafe $row.ReportPath))
      }
      [void]$htmlBuilder.AppendLine(("      <tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td class=""{4}"">{5}</td><td>{6}</td><td class=""report-path"">{7}</td></tr>" -f (ConvertTo-HtmlSafe (Coalesce $row.Mode 'n/a')), (ConvertTo-HtmlSafe (Coalesce $row.Index 'n/a')), (ConvertTo-HtmlSafe $row.BaseLabel), (ConvertTo-HtmlSafe $row.HeadLabel), $diffClass, $diffLabel, $durationDisplay, $reportHtml))
    }
    [void]$htmlBuilder.AppendLine('    </tbody>')
    [void]$htmlBuilder.AppendLine('  </table>')
  } else {
    [void]$htmlBuilder.AppendLine('  <p class="muted">No commit pairs were captured for the requested history window.</p>')
  }

  [void]$htmlBuilder.AppendLine('  <h2>Attribute coverage</h2>')
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

Write-GitHubOutput -Key 'history-report-md' -Value $markdownOutPath -DestPath $GitHubOutputPath

$stepLines = @(
  '### VI history report',
  '',
  ('- Target: `{0}`' -f (Coalesce $targetPath 'unknown')),
  ('- Total comparisons: {0}' -f (Coalesce $stats.processed $comparisons.Count)),
  ('- Diffs: {0}' -f (Coalesce $stats.diffs 'n/a')),
  ('- Report: `{0}`' -f $markdownOutPath)
)
if ($htmlOutPath) {
  $stepLines += ('- HTML: `{0}`' -f $htmlOutPath)
}
Write-StepSummary -Lines $stepLines -DestPath $StepSummaryPath

Write-Host ("History report generated at {0}" -f $markdownOutPath)
