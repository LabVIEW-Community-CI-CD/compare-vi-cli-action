#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CorpusPath = 'fixtures/real-history/offline-corpus.normalized.json',
  [string]$TargetId,
  [string]$ResultsRoot = 'tests/results/_agent/offline-corpus-evaluation',
  [string]$ReportPath,
  [switch]$SkipSchemaValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20)
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Schema validation runner not found at '$runner'."
  }

  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Get-StringArray {
  param([AllowNull()][object]$Value)

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($item in @($Value)) {
    if ([string]::IsNullOrWhiteSpace([string]$item)) {
      continue
    }
    $items.Add([string]$item) | Out-Null
  }

  return @($items.ToArray())
}

function Get-SortedUniqueStringArray {
  param([AllowNull()][object]$Value)

  $items = @(Get-StringArray -Value $Value)
  if ($items.Count -eq 0) {
    return @()
  }

  return @($items | Sort-Object -Unique)
}

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $PathValue
  $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $resolved)
  if ([string]::IsNullOrWhiteSpace($relative)) {
    return '.'
  }

  if ($relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
      $relative.StartsWith('..' + [System.IO.Path]::AltDirectorySeparatorChar) -or
      $relative -eq '..') {
    return $resolved
  }

  return ($relative -replace '\\', '/')
}

function Format-MarkdownCodeList {
  param([AllowEmptyCollection()][string[]]$Values = @())

  $items = @(Get-SortedUniqueStringArray -Value $Values)
  if ($items.Count -eq 0) {
    return 'n/a'
  }

  return (($items | ForEach-Object { ('`{0}`' -f $_) }) -join ', ')
}

function Format-HtmlCodeList {
  param([AllowEmptyCollection()][string[]]$Values = @())

  $items = @(Get-SortedUniqueStringArray -Value $Values)
  if ($items.Count -eq 0) {
    return '<span class="muted">n/a</span>'
  }

  return (($items | ForEach-Object { ('<code>{0}</code>' -f [System.Net.WebUtility]::HtmlEncode($_)) }) -join ', ')
}

function Get-MarkdownExpectationMap {
  param([Parameter(Mandatory)][object]$Target)

  $outcomeLabels = @(Get-SortedUniqueStringArray -Value $Target.annotations.outcomeLabels)
  return [ordered]@{
    coverageClass = ('| Coverage Class | {0} |' -f (Format-MarkdownCodeList -Values @([string]$Target.annotations.coverageClass)))
    modeSensitivity = ('| Mode Sensitivity | {0} |' -f (Format-MarkdownCodeList -Values @([string]$Target.annotations.modeSensitivity)))
    outcomeLabels = ('| Outcome Labels | {0} |' -f (Format-MarkdownCodeList -Values $outcomeLabels))
  }
}

function Get-HtmlExpectationMap {
  param([Parameter(Mandatory)][object]$Target)

  $outcomeLabels = @(Get-SortedUniqueStringArray -Value $Target.annotations.outcomeLabels)
  return [ordered]@{
    coverageClass = ('<th scope="row">Coverage Class</th><td>{0}</td>' -f (Format-HtmlCodeList -Values @([string]$Target.annotations.coverageClass)))
    modeSensitivity = ('<th scope="row">Mode Sensitivity</th><td>{0}</td>' -f (Format-HtmlCodeList -Values @([string]$Target.annotations.modeSensitivity)))
    outcomeLabels = ('<th scope="row">Outcome Labels</th><td>{0}</td>' -f (Format-HtmlCodeList -Values $outcomeLabels))
  }
}

$repoRoot = Resolve-RepoRoot
$corpusResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CorpusPath
if (-not (Test-Path -LiteralPath $corpusResolved -PathType Leaf)) {
  throw "Offline corpus file not found at '$corpusResolved'."
}

if (-not $SkipSchemaValidation.IsPresent) {
  $corpusSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'offline-real-history-corpus-v1.schema.json'
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $corpusSchemaPath -DataPath $corpusResolved
}

$rendererScript = Join-Path $repoRoot 'tools' 'Render-VIHistoryReport.ps1'
if (-not (Test-Path -LiteralPath $rendererScript -PathType Leaf)) {
  throw "Render-VIHistoryReport.ps1 not found at '$rendererScript'."
}

$resultsRootResolved = Ensure-Directory -Path (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot)
$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRootResolved 'offline-real-history-corpus-evaluation.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$reportDir = Split-Path -Parent $reportResolved
if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
  Ensure-Directory -Path $reportDir | Out-Null
}

$corpus = Read-JsonFile -Path $corpusResolved
$targets = @($corpus.targets)
if (-not [string]::IsNullOrWhiteSpace($TargetId)) {
  $targets = @($targets | Where-Object { [string]$_.id -eq $TargetId })
}
if ($targets.Count -eq 0) {
  throw "No offline real-history corpus targets matched '$TargetId'."
}

$targetReports = New-Object System.Collections.Generic.List[object]
foreach ($target in $targets) {
  $notes = New-Object System.Collections.Generic.List[string]
  $renderStatus = 'ok'
  $markdownChecks = [ordered]@{
    coverageClass = $false
    modeSensitivity = $false
    outcomeLabels = $false
  }
  $htmlChecks = [ordered]@{
    coverageClass = $false
    modeSensitivity = $false
    outcomeLabels = $false
  }
  $stepSummaryChecks = [ordered]@{
    coverageClass = $false
    modeSensitivity = $false
    outcomeLabels = $false
  }
  $targetOutputDir = Ensure-Directory -Path (Join-Path $resultsRootResolved ([string]$target.id))
  $markdownPath = Join-Path $targetOutputDir 'history-report.evaluated.md'
  $htmlPath = Join-Path $targetOutputDir 'history-report.evaluated.html'
  $stepSummaryPath = Join-Path $targetOutputDir 'history-report.step-summary.md'

  try {
    $suiteManifestPath = Resolve-AbsolutePath -BasePath $repoRoot -PathValue ([string]$target.provenance.suiteManifestPath)
    if (-not (Test-Path -LiteralPath $suiteManifestPath -PathType Leaf)) {
      throw "Suite manifest not found at '$suiteManifestPath'."
    }

    & $rendererScript `
      -ManifestPath $suiteManifestPath `
      -RequestedModesOverride @($target.requestedModes) `
      -OutputDir $targetOutputDir `
      -MarkdownPath $markdownPath `
      -EmitHtml `
      -HtmlPath $htmlPath `
      -StepSummaryPath $stepSummaryPath | Out-Null

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    $html = Get-Content -LiteralPath $htmlPath -Raw
    $stepSummary = Get-Content -LiteralPath $stepSummaryPath -Raw
    $markdownExpectations = Get-MarkdownExpectationMap -Target $target
    $htmlExpectations = Get-HtmlExpectationMap -Target $target

    foreach ($key in @($markdownChecks.Keys)) {
      $markdownChecks[$key] = $markdown.Contains([string]$markdownExpectations[$key])
      $htmlChecks[$key] = $html.Contains([string]$htmlExpectations[$key])
      $stepSummaryChecks[$key] = $stepSummary.Contains([string]$markdownExpectations[$key])
      if (-not $markdownChecks[$key]) {
        $notes.Add(("Markdown output is missing expected {0} evidence for target '{1}'." -f $key, [string]$target.id)) | Out-Null
      }
      if (-not $htmlChecks[$key]) {
        $notes.Add(("HTML output is missing expected {0} evidence for target '{1}'." -f $key, [string]$target.id)) | Out-Null
      }
      if (-not $stepSummaryChecks[$key]) {
        $notes.Add(("Step summary is missing expected {0} evidence for target '{1}'." -f $key, [string]$target.id)) | Out-Null
      }
    }

    if (@($notes.ToArray()).Count -gt 0) {
      $renderStatus = 'drift'
    }
  } catch {
    $renderStatus = 'drift'
    $notes.Add($_.Exception.Message) | Out-Null
  }

  $targetReports.Add([pscustomobject][ordered]@{
      id = [string]$target.id
      status = $renderStatus
      expected = [ordered]@{
        coverageClass = [string]$target.annotations.coverageClass
        modeSensitivity = [string]$target.annotations.modeSensitivity
        outcomeLabels = @(Get-SortedUniqueStringArray -Value $target.annotations.outcomeLabels)
      }
      observed = [ordered]@{
        markdown = $markdownChecks
        html = $htmlChecks
        stepSummary = $stepSummaryChecks
      }
      outputs = [ordered]@{
        suiteManifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue ([string]$target.provenance.suiteManifestPath)
        markdownPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $markdownPath
        htmlPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $htmlPath
        stepSummaryPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $stepSummaryPath
      }
      notes = @($notes.ToArray() | Select-Object -Unique)
    }) | Out-Null
}

$overallStatus = if (@($targetReports | Where-Object { $_.status -ne 'ok' }).Count -gt 0) { 'drift' } else { 'ok' }
$report = [ordered]@{
  schema = 'vi-history/offline-real-history-corpus-evaluation@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  corpusPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $corpusResolved
  rendererScriptPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $rendererScript
  overallStatus = $overallStatus
  targets = @($targetReports.ToArray())
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportResolved -Encoding utf8
$reportRelative = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved

if ($overallStatus -ne 'ok') {
  throw "Offline real-history corpus evaluation detected report drift. See '$reportRelative'."
}

Write-Host ("Offline real-history corpus evaluation passed. Report: {0}" -f $reportRelative)
