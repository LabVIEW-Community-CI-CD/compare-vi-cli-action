[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$ContextPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonObject {
  param([Parameter(Mandatory = $true)][string]$PathValue)
  if (-not (Test-Path -LiteralPath $PathValue -PathType Leaf)) {
    throw "JSON file not found: $PathValue"
  }
  return (Get-Content -LiteralPath $PathValue -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function Append-MarkdownBlock {
  param(
    [string[]]$Lines,
    [string]$CommentPath
  )

  if (-not $Lines -or $Lines.Count -eq 0) {
    return
  }

  $content = ($Lines -join "`n") + "`n"
  if ($env:GITHUB_STEP_SUMMARY) {
    $summaryDir = Split-Path -Parent $env:GITHUB_STEP_SUMMARY
    if ($summaryDir -and -not (Test-Path -LiteralPath $summaryDir -PathType Container)) {
      New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
    }
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $content -Encoding UTF8
  }
  if (-not [string]::IsNullOrWhiteSpace($CommentPath)) {
    $commentDir = Split-Path -Parent $CommentPath
    if ($commentDir -and -not (Test-Path -LiteralPath $commentDir -PathType Container)) {
      New-Item -ItemType Directory -Path $commentDir -Force | Out-Null
    }
    Add-Content -LiteralPath $CommentPath -Value $content -Encoding UTF8
  }
}

function Build-DiagnosticsLines {
  param([Parameter(Mandatory = $true)][string]$ResultsDirectory)

  $diagPath = Join-Path $ResultsDirectory 'result-shapes.json'
  if (-not (Test-Path -LiteralPath $diagPath -PathType Leaf)) {
    return @()
  }

  try {
    $diag = Read-JsonObject -PathValue $diagPath
    $total = [int]$diag.totalEntries
    $hasPath = [int]$diag.overall.hasPath
    $hasTags = [int]$diag.overall.hasTags
    $pct = {
      param([int]$Numerator, [int]$Denominator)
      if ($Denominator -le 0) { return '0%' }
      return ('{0:P1}' -f ([double]$Numerator / [double]$Denominator))
    }
    return @(
      '### Diagnostics Summary',
      '',
      '| Metric | Count | Percent |',
      '|---|---:|---:|',
      ("| Total entries | {0} | - |" -f $total),
      ("| Has Path | {0} | {1} |" -f $hasPath, (& $pct $hasPath $total)),
      ("| Has Tags | {0} | {1} |" -f $hasTags, (& $pct $hasTags $total))
    )
  } catch {
    Write-Warning ("Failed to build diagnostics publication block: {0}" -f $_.Exception.Message)
    return @()
  }
}

$resolvedContextPath = [System.IO.Path]::GetFullPath($ContextPath)
$context = Read-JsonObject -PathValue $resolvedContextPath
$repoRoot = [System.IO.Path]::GetFullPath([string]$context.repoRoot)
$resultsDir = [System.IO.Path]::GetFullPath([string]$context.resultsDir)
$publication = if ($context.PSObject.Properties['publication']) { $context.publication } else { $null }
$commentPath = if ($publication -and $publication.PSObject.Properties['commentPath'] -and $publication.commentPath) { [string]$publication.commentPath } else { $null }
$toolRepoRoot = Split-Path -Parent $PSScriptRoot

$summaryWriter = Join-Path $repoRoot 'scripts/Write-PesterSummaryToStepSummary.ps1'
if (-not (Test-Path -LiteralPath $summaryWriter -PathType Leaf)) {
  $summaryWriter = Join-Path $toolRepoRoot 'scripts/Write-PesterSummaryToStepSummary.ps1'
}

$sessionWriter = Join-Path $repoRoot 'tools/Write-SessionIndexSummary.ps1'
if (-not (Test-Path -LiteralPath $sessionWriter -PathType Leaf)) {
  $sessionWriter = Join-Path $toolRepoRoot 'tools/Write-SessionIndexSummary.ps1'
}
$sessionIndexPath = Join-Path $resultsDir 'session-index.json'
$reportPath = Join-Path $resultsDir 'pester-execution-publication.json'

$stepSummaryPresent = -not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)
$publicationEnabled = $true
if ($publication -and $publication.PSObject.Properties['disableStepSummary']) {
  $publicationEnabled = -not [bool]$publication.disableStepSummary
}

$summaryWritten = $false
$sessionSummaryWritten = $false
$metadataWritten = $false
$diagnosticsWritten = $false
$sessionIndexMetadata = $false

if ($publicationEnabled -and ($stepSummaryPresent -or -not [string]::IsNullOrWhiteSpace($commentPath))) {
  if (Test-Path -LiteralPath $summaryWriter -PathType Leaf) {
    $summaryArgs = @{
      ResultsDir = $resultsDir
    }
    if (-not [string]::IsNullOrWhiteSpace($commentPath)) {
      $summaryArgs.CommentPath = $commentPath
    }
    try {
      & $summaryWriter @summaryArgs | Out-Host
    } catch {
      throw "Write-PesterSummaryToStepSummary.ps1 failed: $($_.Exception.Message)"
    }
    $summaryWritten = $true
  }

  if ($stepSummaryPresent -and (Test-Path -LiteralPath $sessionWriter -PathType Leaf)) {
    try {
      & $sessionWriter -ResultsDir $resultsDir | Out-Host
    } catch {
      throw "Write-SessionIndexSummary.ps1 failed: $($_.Exception.Message)"
    }
    $sessionSummaryWritten = $true
  }

  if (Test-Path -LiteralPath $sessionIndexPath -PathType Leaf) {
    try {
      $sessionIndex = Read-JsonObject -PathValue $sessionIndexPath
      if ($sessionIndex.PSObject.Properties['stepSummary'] -and $sessionIndex.stepSummary) {
        Append-MarkdownBlock -Lines @([string]$sessionIndex.stepSummary) -CommentPath $commentPath
        $sessionIndexMetadata = $true
      }
    } catch {
      Write-Warning ("Failed to append session index publication metadata: {0}" -f $_.Exception.Message)
    }
  }

  $diagnosticsLines = Build-DiagnosticsLines -ResultsDirectory $resultsDir
  if ($diagnosticsLines.Count -gt 0) {
    Append-MarkdownBlock -Lines $diagnosticsLines -CommentPath $commentPath
    $diagnosticsWritten = $true
  }

  $metadataWritten = $sessionIndexMetadata -or $diagnosticsWritten
}

$report = [ordered]@{
  schema = 'pester-execution-publication@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  contextPath = $resolvedContextPath
  resultsDir = $resultsDir
  publicationEnabled = $publicationEnabled
  stepSummaryPresent = $stepSummaryPresent
  commentPath = $commentPath
  summaryWritten = $summaryWritten
  sessionSummaryWritten = $sessionSummaryWritten
  sessionIndexMetadataWritten = $sessionIndexMetadata
  diagnosticsWritten = $diagnosticsWritten
  metadataWritten = $metadataWritten
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "path=$reportPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "summary_written=$summaryWritten" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "metadata_written=$metadataWritten" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester execution publication' -ForegroundColor Cyan
Write-Host ("enabled      : {0}" -f $publicationEnabled)
Write-Host ("summary      : {0}" -f $summaryWritten)
Write-Host ("session      : {0}" -f $sessionSummaryWritten)
Write-Host ("metadata     : {0}" -f $metadataWritten)
Write-Host ("report       : {0}" -f $reportPath)

exit 0
