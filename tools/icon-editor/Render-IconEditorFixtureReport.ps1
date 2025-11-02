#Requires -Version 7.0

param(
  [string]$ReportPath,
  [string]$FixturePath,
  [string]$OutputPath,
  [switch]$UpdateDoc
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

function Ensure-FixtureReport {
  param(
    [string]$ReportPath,
    [string]$FixturePath,
    [string]$RepoRoot
  )

  if ($ReportPath -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return $ReportPath
  }

  $defaultPath = Join-Path $RepoRoot 'tests' 'results' '_agent' 'icon-editor' 'fixture-report.json'
  $targetPath = $ReportPath
  if (-not $targetPath) {
    $targetPath = $defaultPath
  }

  if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    $describeScript = Join-Path $RepoRoot 'tools' 'icon-editor' 'Describe-IconEditorFixture.ps1'
    $describeParams = @{
      OutputPath = $targetPath
      KeepWork   = $false
    }
    if ($FixturePath) {
      $describeParams['FixturePath'] = $FixturePath
    }
    pwsh -NoLogo -NoProfile -File $describeScript @describeParams | Out-Null
  }

  return $targetPath
}

function Format-HashMatch {
  param([bool]$Match)
  if ($Match) { return 'match' }
  return 'mismatch'
}

function Render-CustomActions {
  param($CustomActions)
  $lines = @(
    '| Action | Fixture Hash | Repo Hash | Match |',
    '| --- | --- | --- | --- |'
  )

  foreach ($item in $CustomActions) {
    $fixtureHash = if ($item.fixture) { $item.fixture.hash } else { '_missing_' }
    $repoHash = if ($item.repo) { $item.repo.hash } else { '_missing_' }
    $lines += [string]::Format('| {0} | `{1}` | `{2}` | {3} |', $item.name, $fixtureHash, $repoHash, (Format-HashMatch $item.hashMatch))
  }

  return $lines
}

function Render-ArtifactList {
  param($Artifacts)
  foreach ($artifact in $Artifacts) {
    $sizeMB = [math]::Round($artifact.sizeBytes / 1MB, 2)
    [string]::Format('{0} - {1} MB (`{2}`)', $artifact.name, $sizeMB, $artifact.hash)
  }
}

function Render-FixtureOnlyAssets {
  param($Assets)
  if (-not $Assets -or $Assets.Count -eq 0) {
    return @('- None detected.')
  }

  $grouped = $Assets | Group-Object category
  $lines = @()
  foreach ($group in $grouped) {
    $lines += ("- {0} ({1} entries)" -f $group.Name, $group.Count)
    foreach ($asset in ($group.Group | Sort-Object name | Select-Object -First 5)) {
      $lines += ("  - `{0}` (`{1}`)" -f $asset.name, $asset.hash)
    }
    if ($group.Count -gt 5) {
      $lines += ("  - ... {0} more" -f ($group.Count - 5))
    }
  }
  return $lines
}

$repoRoot = Resolve-RepoRoot
$resolvedReportPath = Ensure-FixtureReport -ReportPath $ReportPath -FixturePath $FixturePath -RepoRoot $repoRoot
$summary = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json -Depth 10

$fixtureVersion = $summary.fixture.package.Version
$systemVersion = $summary.systemPackage.package.Version
$fixtureLicense = $summary.fixture.description.License
$generatedAt = $summary.generatedAt
$fixturePathFull = $summary.source.fixturePath
try {
  $fixturePath = [System.IO.Path]::GetRelativePath($repoRoot, $fixturePathFull)
} catch {
  $fixturePath = $fixturePathFull
}
$manifest = $summary.manifest
$stakeholder = $summary.stakeholder

$lines = @()
$lines += "## Package layout highlights"
$lines += ""
$lines += [string]::Format('- Fixture version `{0}` (system `{1}`), license `{2}`.', $fixtureVersion, $systemVersion, $fixtureLicense)
$lines += [string]::Format('- Fixture path: `{0}`', $fixturePath)
$lines += [string]::Format('- Package smoke status: **{0}** (VIPs: {1})', $manifest.packageSmoke.status, $manifest.packageSmoke.vipCount)
$lines += [string]::Format('- Report generated: `{0}`', $stakeholder.generatedAt ?? $generatedAt)
$lines += "- Artifacts:"
foreach ($item in (Render-ArtifactList $summary.artifacts)) {
  $lines += ("  - {0}" -f $item)
}
$lines += ""
$lines += "## Stakeholder summary"
$lines += ""
$lines += [string]::Format('- Smoke status: **{0}**', $stakeholder.smokeStatus)
$lines += [string]::Format('- Runner dependencies: {0}', $stakeholder.runnerDependencies.matchesRepo ? 'match' : 'mismatch')
$lines += [string]::Format('- Custom actions: {0} entries (all match: {1})', ($stakeholder.customActions | Measure-Object).Count, (($stakeholder.customActions | Where-Object { $_.matchStatus -ne 'match' } | Measure-Object).Count -eq 0))
$lines += [string]::Format('- Fixture-only assets discovered: {0}', ($stakeholder.fixtureOnlyAssets | Measure-Object).Count)
$lines += ""
$lines += "## Comparison with repository sources"
$lines += ""
$lines += "- Custom action hashes:"
$lines += Render-CustomActions $summary.customActions
$lines += ""
$lines += ("- Runner dependencies hash match: {0}" -f (Format-HashMatch $summary.runnerDependencies.hashMatch))
$lines += ""
$lines += "## Fixture-only assets"
$lines += ""
$lines += Render-FixtureOnlyAssets $summary.fixtureOnlyAssets
$lines += ""
$lines += "## Simulation metadata"
$lines += ""
$lines += [string]::Format('- Simulation enabled: {0}', $manifest.simulation.enabled)
$lines += [string]::Format('- Unit tests executed: {0}', $manifest.unitTestsRun)

$markdown = ($lines -join "`n")

if ($OutputPath) {
  $markdown | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if ($UpdateDoc.IsPresent) {
  $docPath = Join-Path $repoRoot 'docs' 'ICON_EDITOR_PACKAGE.md'
  $startMarker = '<!-- icon-editor-report:start -->'
  $endMarker = '<!-- icon-editor-report:end -->'
  $docContent = Get-Content -LiteralPath $docPath -Raw
  if (-not ($docContent.Contains($startMarker) -and $docContent.Contains($endMarker))) {
    throw "Markers not found in $docPath. Expected $startMarker ... $endMarker."
  }
  $replaceScript = {
    param([System.Text.RegularExpressions.Match]$match, [string]$replacementText)
    return $replacementText
  }
  $pattern = [System.Text.RegularExpressions.Regex]::Escape($startMarker) + '.*?' + [System.Text.RegularExpressions.Regex]::Escape($endMarker)
  $regex = [System.Text.RegularExpressions.Regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $updated = $regex.Replace($docContent, { param($m) "$startMarker`n$markdown`n$endMarker" })
  $updatedLines = @($updated -split "`r?`n")
  while ($updatedLines.Count -gt 1 -and [string]::IsNullOrWhiteSpace($updatedLines[-1])) {
    $updatedLines = $updatedLines[0..($updatedLines.Count - 2)]
  }
  $updatedLines += ''
  Set-Content -LiteralPath $docPath -Value $updatedLines -Encoding utf8
}

if (-not $OutputPath) {
  Write-Output $markdown
}
