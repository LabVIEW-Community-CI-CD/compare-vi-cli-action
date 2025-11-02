#Requires -Version 7.0

param(
  [switch]$CheckOnly,
  [string]$FixturePath
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

$reportDir = Join-Path $repoRoot 'tests' 'results' '_agent' 'icon-editor'
if (-not (Test-Path -LiteralPath $reportDir -PathType Container)) {
  New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
$reportPath = Join-Path $reportDir 'fixture-report.json'
$markdownPath = Join-Path $reportDir 'fixture-report.md'

$describeParams = @{
  OutputPath = $reportPath
  KeepWork   = $false
}
if ($FixturePath) {
  $describeParams['FixturePath'] = $FixturePath
}

pwsh -NoLogo -NoProfile -File $describeScript @describeParams | Out-Null
pwsh -NoLogo -NoProfile -File $renderScript -ReportPath $reportPath -OutputPath $markdownPath | Out-Null
pwsh -NoLogo -NoProfile -File $renderScript -ReportPath $reportPath -UpdateDoc | Out-Null

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
}
