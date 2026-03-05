#Requires -Version 7.0

param(
  [switch]$CheckOnly,
  [string]$FixturePath,
  [string]$ManifestPath,
  [string]$ResultsRoot,
  [string]$ResourceOverlayRoot,
  [switch]$SkipDocUpdate,
  [switch]$NoSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim()
  } catch {
    return $StartPath
  }
}

$repoRoot = Resolve-RepoRoot
$describeScript = Join-Path $repoRoot 'tools' 'icon-editor' 'Describe-IconEditorFixture.ps1'
$renderScript = Join-Path $repoRoot 'tools' 'icon-editor' 'Render-IconEditorFixtureReport.ps1'

if (-not (Test-Path -LiteralPath $describeScript -PathType Leaf)) {
  throw "Descriptor script not found at '$describeScript'."
}
if (-not (Test-Path -LiteralPath $renderScript -PathType Leaf)) {
  throw "Renderer script not found at '$renderScript'."
}

$defaultFixturePath = Join-Path $repoRoot 'tests' 'fixtures' 'icon-editor' 'ni_icon_editor-1.4.1.948.vip'
if (-not $FixturePath) {
  $FixturePath = $defaultFixturePath
}
$shouldUpdateDoc = ($FixturePath -eq $defaultFixturePath) -and (-not $SkipDocUpdate.IsPresent)

$reportDir = if ($ResultsRoot) {
  if ([System.IO.Path]::IsPathRooted($ResultsRoot)) {
    $ResultsRoot
  } else {
    Join-Path $repoRoot $ResultsRoot
  }
} else {
  Join-Path $repoRoot 'tests' 'results' '_agent' 'icon-editor'
}
if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) {
  New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
$reportPath = Join-Path $reportDir 'fixture-report.json'
$markdownPath = Join-Path $reportDir 'fixture-report.md'

$resolvedOverlay = $null
if ($ResourceOverlayRoot) {
  $resolvedOverlay = if ([System.IO.Path]::IsPathRooted($ResourceOverlayRoot)) {
    $ResourceOverlayRoot
  } else {
    Join-Path $repoRoot $ResourceOverlayRoot
  }
  if (-not (Test-Path -LiteralPath $resolvedOverlay -PathType Container)) {
    throw "Resource overlay path not found at '$resolvedOverlay'."
  }
  $resolvedOverlay = (Resolve-Path -LiteralPath $resolvedOverlay).Path
}

$describeParams = @{
  OutputPath  = $reportPath
  KeepWork    = $false
  FixturePath = $FixturePath
}

$useOverlay = $true
if ($resolvedOverlay) {
  $describeParams['ResourceOverlayRoot'] = $resolvedOverlay
} else {
  $useOverlay = $shouldUpdateDoc
}
if (-not $useOverlay) {
  $describeParams['SkipResourceOverlay'] = $true
}

pwsh -NoLogo -NoProfile -File $describeScript @describeParams | Out-Null
pwsh -NoLogo -NoProfile -File $renderScript -ReportPath $reportPath -OutputPath $markdownPath | Out-Null
if ($shouldUpdateDoc) {
  pwsh -NoLogo -NoProfile -File $renderScript -ReportPath $reportPath -UpdateDoc | Out-Null
}

$summary = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 8

function Convert-ToManifestEntries {
  param($Assets)
  $entries = @()
  foreach ($asset in ($Assets | Sort-Object category, name)) {
    $rel = switch ($asset.category) {
      'script'   { Join-Path 'scripts' $asset.name; break }
      'test'     { Join-Path 'tests' $asset.name; break }
      'resource' { Join-Path 'resource' $asset.name; break }
      default    { Join-Path $asset.category $asset.name }
    }
    $entries += [ordered]@{
      key       = ($asset.category + ':' + $rel).ToLower()
      category  = $asset.category
      path      = $rel
      sizeBytes = ($asset.sizeBytes ?? 0)
      hash      = $asset.hash
    }
  }
  return $entries
}

$manifestObject = [ordered]@{
  schema      = 'icon-editor/fixture-manifest@v1'
  generatedAt = (Get-Date).ToString('o')
  entries     = Convert-ToManifestEntries -Assets $summary.fixtureOnlyAssets
}

if (-not $ManifestPath) {
  $ManifestPath = Join-Path $repoRoot 'tests/fixtures/icon-editor/fixture-manifest.json'
}
$manifestDir = Split-Path -Parent $ManifestPath
if (-not (Test-Path -LiteralPath $manifestDir -PathType Container)) {
  New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
}
$manifestObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding utf8

if ($CheckOnly.IsPresent) {
  git -C $repoRoot diff --quiet -- docs/ICON_EDITOR_PACKAGE.md
  $diffExit = $LASTEXITCODE
  git -C $repoRoot checkout -- docs/ICON_EDITOR_PACKAGE.md | Out-Null
  if (Test-Path -LiteralPath $reportPath) {
    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path -LiteralPath $markdownPath) {
    Remove-Item -LiteralPath $markdownPath -Force -ErrorAction SilentlyContinue
  }
  if ($diffExit -ne 0) {
    throw "docs/ICON_EDITOR_PACKAGE.md is out of date. Run `pwsh -File tools/icon-editor/Update-IconEditorFixtureReport.ps1` and commit the changes."
  }
  return
}

if ($NoSummary.IsPresent) {
  return
}

return [pscustomobject]$summary
