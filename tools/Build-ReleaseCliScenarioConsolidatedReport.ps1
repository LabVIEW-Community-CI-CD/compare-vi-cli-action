#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$MatrixRoot = 'tests/results/_agent/release-v1.0.1/scenario-matrix',
  [string]$OutputDir,
  [string]$JsonPath,
  [string]$MarkdownPath,
  [string]$HtmlPath,
  [switch]$SkipImageExtraction
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRootPath {
  param([string]$Provided)

  if (-not [string]::IsNullOrWhiteSpace($Provided)) {
    return (Resolve-Path -LiteralPath $Provided).Path
  }

  $current = (Get-Location).Path
  while ($true) {
    if (Test-Path -LiteralPath (Join-Path $current '.git')) {
      return $current
    }

    $parent = Split-Path -Parent $current
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
      throw 'Could not locate repository root (.git). Pass -RepoRoot explicitly.'
    }

    $current = $parent
  }
}

function Resolve-ContainerPathToHost {
  param(
    [string]$Path,
    [string]$RepoPath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return ''
  }

  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return (Resolve-Path -LiteralPath $Path).Path
  }

  $trimmed = $Path.Trim()
  if ($trimmed -match '^[A-Za-z]:\\work\\(?<rel>.+)$') {
    $relative = ($Matches.rel -replace '\\', [IO.Path]::DirectorySeparatorChar)
    return (Join-Path $RepoPath $relative)
  }

  if ($trimmed -like '/work/*') {
    $relativeUnix = $trimmed.Substring('/work/'.Length)
    $relative = ($relativeUnix -replace '/', [IO.Path]::DirectorySeparatorChar)
    return (Join-Path $RepoPath $relative)
  }

  if ([IO.Path]::IsPathRooted($trimmed)) {
    return $trimmed
  }

  return (Join-Path $RepoPath ($trimmed -replace '/', [IO.Path]::DirectorySeparatorChar))
}

function Resolve-OutputFilePath {
  param(
    [string]$Path,
    [string]$BaseDir,
    [string]$DefaultLeaf
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return (Join-Path $BaseDir $DefaultLeaf)
  }

  if ([IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return (Join-Path $BaseDir $Path)
}

function Get-ObjectStringProperty {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return ''
  }

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    return ''
  }

  return [string]$prop.Value
}

$repoPath = Resolve-RepoRootPath -Provided $RepoRoot
Push-Location $repoPath
try {
  $matrixRootResolved = if ([IO.Path]::IsPathRooted($MatrixRoot)) { $MatrixRoot } else { Join-Path $repoPath $MatrixRoot }
  if (-not (Test-Path -LiteralPath $matrixRootResolved -PathType Container)) {
    throw "Matrix root not found: $matrixRootResolved"
  }

  $scenarioJsonPath = Join-Path $matrixRootResolved 'scenario-results.json'
  if (-not (Test-Path -LiteralPath $scenarioJsonPath -PathType Leaf)) {
    throw "Scenario results JSON not found: $scenarioJsonPath"
  }

  $rows = @((Get-Content -LiteralPath $scenarioJsonPath -Raw) | ConvertFrom-Json -Depth 20)
  if ($rows.Count -lt 1) {
    throw "Scenario results JSON is empty: $scenarioJsonPath"
  }

  $defaultOutputDir = Join-Path $matrixRootResolved 'consolidated'
  $effectiveOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) { $defaultOutputDir } elseif ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repoPath $OutputDir }
  New-Item -ItemType Directory -Path $effectiveOutputDir -Force | Out-Null
  $effectiveOutputDir = (Resolve-Path -LiteralPath $effectiveOutputDir).Path

  $imagesDir = Join-Path $effectiveOutputDir 'images'
  New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null

  $jsonOut = Resolve-OutputFilePath -Path $JsonPath -BaseDir $effectiveOutputDir -DefaultLeaf 'scenario-consolidated-report.json'
  $mdOut = Resolve-OutputFilePath -Path $MarkdownPath -BaseDir $effectiveOutputDir -DefaultLeaf 'scenario-consolidated-report.md'
  $htmlOut = Resolve-OutputFilePath -Path $HtmlPath -BaseDir $effectiveOutputDir -DefaultLeaf 'scenario-consolidated-report.html'

  $extractScript = Join-Path $repoPath 'tools/Extract-VIHistoryReportImages.ps1'
  if (-not (Test-Path -LiteralPath $extractScript -PathType Leaf)) {
    throw "Missing extractor script: $extractScript"
  }

  $scenarioItems = New-Object System.Collections.Generic.List[object]
  $galleryItems = New-Object System.Collections.Generic.List[object]

  foreach ($row in $rows) {
    $stdoutRelative = [string]$row.stdoutPath
    $stdoutPath = Resolve-ContainerPathToHost -Path $stdoutRelative -RepoPath $repoPath

    $parsed = $null
    $reportPathResolved = ''
    $reportExists = $false
    $indexPathResolved = ''
    $indexExists = $false
    $imageCount = 0
    $notes = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $stdoutPath -PathType Leaf)) {
      $notes.Add('stdout payload missing') | Out-Null
    } else {
      $stdoutRaw = Get-Content -LiteralPath $stdoutPath -Raw
      try {
        $parsed = $stdoutRaw | ConvertFrom-Json -Depth 20
      } catch {
        $notes.Add('stdout payload is not valid JSON') | Out-Null
      }
    }

    if ($parsed) {
      $reportPathResolved = Resolve-ContainerPathToHost -Path (Get-ObjectStringProperty -Object $parsed -Name 'reportHtmlPath') -RepoPath $repoPath
      if (-not [string]::IsNullOrWhiteSpace($reportPathResolved) -and (Test-Path -LiteralPath $reportPathResolved -PathType Leaf)) {
        $reportExists = $true
      }

      $indexPathResolved = Resolve-ContainerPathToHost -Path (Get-ObjectStringProperty -Object $parsed -Name 'imageIndexPath') -RepoPath $repoPath
      if (-not [string]::IsNullOrWhiteSpace($indexPathResolved) -and (Test-Path -LiteralPath $indexPathResolved -PathType Leaf)) {
        $indexExists = $true
      }
    }

    $scenarioImageEntries = @()
    if ($reportExists -and -not $SkipImageExtraction.IsPresent) {
      $scenarioImageOut = Join-Path $imagesDir ([string]$row.scenarioId)
      $scenarioIndexOut = Join-Path $scenarioImageOut 'vi-history-image-index.json'
      $extractResult = & $extractScript -ReportPath $reportPathResolved -OutputDir $scenarioImageOut -IndexPath $scenarioIndexOut
      if ($extractResult -and $extractResult.images) {
        $scenarioImageEntries = @($extractResult.images | Where-Object { [string]$_.status -eq 'saved' })
      }
      $imageCount = @($scenarioImageEntries).Count
    } elseif (-not $reportExists) {
      $notes.Add('reportHtmlPath missing or file absent') | Out-Null
    }

    foreach ($imageEntry in $scenarioImageEntries) {
      $savedPath = [string]$imageEntry.savedPath
      if (-not (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
        continue
      }

      $leaf = Split-Path -Leaf $savedPath
      $finalName = ('{0}-{1}' -f [string]$row.scenarioId, $leaf)
      $finalPath = Join-Path $imagesDir $finalName
      Copy-Item -LiteralPath $savedPath -Destination $finalPath -Force

      $relativeForHtml = ('images/{0}' -f $finalName)
      $galleryItems.Add([pscustomobject]@{
        scenarioId = [string]$row.scenarioId
        fixture = [string]$row.fixture
        relativePath = $relativeForHtml
      }) | Out-Null
    }

    $scenarioItems.Add([pscustomobject]@{
      scenarioId = [string]$row.scenarioId
      fixture = [string]$row.fixture
      diff = [bool]$row.diff
      nonInteractive = [bool]$row.nonInteractive
      headless = [bool]$row.headless
      exitCode = [int]$row.exitCode
      gateOutcome = [string]$row.gateOutcome
      resultClass = [string]$row.resultClass
      failureClass = [string]$row.failureClass
      reportPath = $reportPathResolved
      reportExists = $reportExists
      imageIndexPath = $indexPathResolved
      imageIndexExists = $indexExists
      extractedImageCount = $imageCount
      notes = @($notes)
    }) | Out-Null
  }

  $reportFilesPresent = 0
  $imageIndexesPresent = 0
  $passCount = 0
  $failCount = 0
  foreach ($scenario in $scenarioItems) {
    if ([bool]$scenario.reportExists) { $reportFilesPresent++ }
    if ([bool]$scenario.imageIndexExists) { $imageIndexesPresent++ }
    if ([string]$scenario.gateOutcome -eq 'pass') { $passCount++ }
    if ([string]$scenario.gateOutcome -eq 'fail') { $failCount++ }
  }

  $totals = [ordered]@{
    scenarios = $scenarioItems.Count
    reportFilesPresent = $reportFilesPresent
    imageIndexesPresent = $imageIndexesPresent
    extractedImages = $galleryItems.Count
    passCount = $passCount
    failCount = $failCount
  }

  $reportObject = [ordered]@{
    schema = 'release-cli-scenario-consolidated-report@v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    matrixRoot = $matrixRootResolved
    outputDir = $effectiveOutputDir
    totals = $totals
    scenarios = $scenarioItems.ToArray()
    gallery = $galleryItems.ToArray()
  }

  $reportObject | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonOut -Encoding utf8

  $mdLines = New-Object System.Collections.Generic.List[string]
  $mdLines.Add('# Release CLI Scenario Consolidated Report') | Out-Null
  $mdLines.Add('') | Out-Null
  $mdLines.Add(('- Generated (UTC): `{0}`' -f $reportObject.generatedAtUtc)) | Out-Null
  $mdLines.Add(('- Matrix root: `{0}`' -f $matrixRootResolved)) | Out-Null
  $mdLines.Add(('- Scenarios: `{0}`' -f $totals.scenarios)) | Out-Null
  $mdLines.Add(('- Reports present: `{0}`' -f $totals.reportFilesPresent)) | Out-Null
  $mdLines.Add(('- Image indexes present: `{0}`' -f $totals.imageIndexesPresent)) | Out-Null
  $mdLines.Add(('- Extracted images: `{0}`' -f $totals.extractedImages)) | Out-Null
  $mdLines.Add('') | Out-Null
  $mdLines.Add('| Scenario | Fixture | Flags (`diff,nonInteractive,headless`) | Exit | Gate | Report | Images | Notes |') | Out-Null
  $mdLines.Add('| --- | --- | --- | --- | --- | --- | --- | --- |') | Out-Null

  foreach ($scenario in $scenarioItems) {
    $flagsText = ('{0},{1},{2}' -f $scenario.diff, $scenario.nonInteractive, $scenario.headless)
    $reportText = if ($scenario.reportExists) { 'present' } else { 'missing' }
    $notesText = if ($scenario.notes.Count -gt 0) { ($scenario.notes -join '; ') } else { '' }
    $mdLines.Add(('| {0} | {1} | `{2}` | {3} | {4} | {5} | {6} | {7} |' -f $scenario.scenarioId, $scenario.fixture, $flagsText, $scenario.exitCode, $scenario.gateOutcome, $reportText, $scenario.extractedImageCount, $notesText)) | Out-Null
  }

  if ($galleryItems.Count -gt 0) {
    $mdLines.Add('') | Out-Null
    $mdLines.Add('## Image Gallery') | Out-Null
    $mdLines.Add('') | Out-Null
    foreach ($gallery in $galleryItems) {
      $mdLines.Add(('### {0} ({1})' -f $gallery.scenarioId, $gallery.fixture)) | Out-Null
      $mdLines.Add(('![{0}]({1})' -f $gallery.scenarioId, $gallery.relativePath)) | Out-Null
      $mdLines.Add('') | Out-Null
    }
  }

  $mdLines | Set-Content -LiteralPath $mdOut -Encoding utf8

  $htmlRows = ($scenarioItems | ForEach-Object {
    $flagsText = ('{0},{1},{2}' -f $_.diff, $_.nonInteractive, $_.headless)
    $reportText = if ($_.reportExists) { 'present' } else { 'missing' }
    $notesText = if ($_.notes.Count -gt 0) { ($_.notes -join '; ') } else { '' }
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td></tr>' -f $_.scenarioId, $_.fixture, $flagsText, $_.exitCode, $_.gateOutcome, $reportText, $_.extractedImageCount, [System.Net.WebUtility]::HtmlEncode($notesText)
  }) -join [Environment]::NewLine

  $galleryHtml = if ($galleryItems.Count -gt 0) {
    ($galleryItems | ForEach-Object {
      '<section><h3>{0} ({1})</h3><img src="{2}" alt="{0}" style="max-width:100%;height:auto;border:1px solid #ccc;"/></section>' -f $_.scenarioId, $_.fixture, $_.relativePath
    }) -join [Environment]::NewLine
  } else {
    '<p>No images were extracted. This typically means compare report HTML files were not generated for the scenarios.</p>'
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>Release CLI Scenario Consolidated Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 16px; }
    table { border-collapse: collapse; width: 100%; margin-bottom: 16px; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background: #f4f4f4; }
    section { margin-bottom: 16px; }
  </style>
</head>
<body>
  <h1>Release CLI Scenario Consolidated Report</h1>
  <p><strong>Generated (UTC):</strong> $($reportObject.generatedAtUtc)</p>
  <p><strong>Scenarios:</strong> $($totals.scenarios) | <strong>Reports present:</strong> $($totals.reportFilesPresent) | <strong>Extracted images:</strong> $($totals.extractedImages)</p>
  <h2>Scenario Summary</h2>
  <table>
    <thead>
      <tr><th>Scenario</th><th>Fixture</th><th>Flags</th><th>Exit</th><th>Gate</th><th>Report</th><th>Images</th><th>Notes</th></tr>
    </thead>
    <tbody>
      $htmlRows
    </tbody>
  </table>
  <h2>Image Gallery</h2>
  $galleryHtml
</body>
</html>
"@

  Set-Content -LiteralPath $htmlOut -Value $html -Encoding utf8

  [pscustomobject]@{
    jsonPath = $jsonOut
    markdownPath = $mdOut
    htmlPath = $htmlOut
    outputDir = $effectiveOutputDir
    scenarios = $totals.scenarios
    reportsPresent = $totals.reportFilesPresent
    extractedImages = $totals.extractedImages
  } | ConvertTo-Json -Depth 6
}
finally {
  Pop-Location
}
