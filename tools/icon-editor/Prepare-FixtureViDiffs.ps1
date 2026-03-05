#Requires -Version 7.0

param(
  [string]$ReportPath,
  [string]$BaselineManifestPath,
  [string]$BaselineFixturePath,
  [string]$OutputDir,
  [string]$ResourceOverlayRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

function Get-DirectoryPath {
  param([string]$Path)
  $created = New-Item -ItemType Directory -Force -Path $Path
  return (Resolve-Path -LiteralPath $created).Path
}

function Expand-VipWithSystem {
  param([string]$VipPath, [string]$DestRoot)
  if (-not (Test-Path -LiteralPath $VipPath -PathType Leaf)) {
    throw "VI Package not found: $VipPath"
  }

  $root = Get-DirectoryPath $DestRoot
  Expand-Archive -Path $VipPath -DestinationPath $root -Force

  $packagesDir = Join-Path $root 'Packages'
  $systemVip = $null
  if (Test-Path -LiteralPath $packagesDir -PathType Container) {
    $systemVip = Get-ChildItem -LiteralPath $packagesDir -Filter 'ni_icon_editor_system-*.vip' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  }

  $systemRoot = $null
  if ($systemVip) {
    $systemRoot = Join-Path $root '__system_extract'
    Expand-Archive -Path $systemVip.FullName -DestinationPath $systemRoot -Force
  } else {
    Write-Information '::notice::No nested system VIP detected; continuing without system extraction.'
  }

  return [ordered]@{
    extract     = $root
    system      = $systemRoot
    systemVip   = ($systemVip ? $systemVip.FullName : $null)
  }
}

function Invoke-ResourceOverlay {
  param(
    [string]$OverlayRoot,
    [string]$SystemRoot
  )
  if (-not $OverlayRoot -or -not $SystemRoot) {
    return
  }
  if (-not (Test-Path -LiteralPath $OverlayRoot -PathType Container)) {
    return
  }
  $resourceDest = Join-Path $SystemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource'
  if (-not (Test-Path -LiteralPath $resourceDest -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $resourceDest -Force)
  }
  $sourceArg = '"{0}"' -f $OverlayRoot
  $destArg = '"{0}"' -f $resourceDest
  $robocopyArgs = @($sourceArg, $destArg, '/MIR')
  try {
    $robocopy = Start-Process -FilePath 'robocopy' -ArgumentList $robocopyArgs -NoNewWindow -PassThru -Wait
    if ($robocopy.ExitCode -gt 3) {
      throw "robocopy exit code $($robocopy.ExitCode)"
    }
  } catch {
    Copy-Item -LiteralPath (Join-Path $OverlayRoot '*') -Destination $resourceDest -Recurse -Force
  }
}

function Build-CurrentManifestFromReport { param($Summary)
  $entries = @()
  foreach ($asset in ($Summary.fixtureOnlyAssets | Sort-Object category, name)) {
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

function Get-ManifestDelta { param($BaseEntries, $NewEntries)
  $baseMap = @{}; foreach($e in $BaseEntries){ $baseMap[$e.key] = $e }
  $newMap = @{}; foreach($e in $NewEntries){ $newMap[$e.key] = $e }
  $added=@(); $removed=@(); $changed=@()
  foreach($k in $newMap.Keys){ if(-not $baseMap.ContainsKey($k)){ $added += $newMap[$k]; continue }; $b=$baseMap[$k]; $n=$newMap[$k]; if(($b.hash -ne $n.hash) -or ([int64]$b.sizeBytes -ne [int64]$n.sizeBytes)){ $changed += $n } }
  foreach($k in $baseMap.Keys){ if(-not $newMap.ContainsKey($k)){ $removed += $baseMap[$k] } }
  return [ordered]@{ added=$added; removed=$removed; changed=$changed }
}

$repoRoot = Resolve-RepoRoot
if (-not $ReportPath) { $ReportPath = Join-Path $repoRoot 'tests/results/_agent/icon-editor/fixture-report.json' }
if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { throw "Report not found: $ReportPath" }
$summary = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -Depth 10

if (-not $BaselineManifestPath) { $BaselineManifestPath = Join-Path $repoRoot 'tests/fixtures/icon-editor/fixture-manifest.json' }
if (-not (Test-Path -LiteralPath $BaselineManifestPath -PathType Leaf)) {
  Write-Warning "Baseline manifest not found at $BaselineManifestPath; no VI diffs to prepare."
  exit 0
}
$baseline = Get-Content -LiteralPath $BaselineManifestPath -Raw | ConvertFrom-Json -Depth 6

$currentEntries = Build-CurrentManifestFromReport -Summary $summary
$delta = Get-ManifestDelta -BaseEntries $baseline.entries -NewEntries $currentEntries

$changedVis = @($delta.changed | Where-Object { $_.path -match '\.vi$' -and $_.category -in @('test','resource') })
$addedVis = @($delta.added | Where-Object { $_.path -match '\.vi$' -and $_.category -in @('test','resource') })
$candidateVis = @($changedVis + $addedVis)
if ($candidateVis.Count -eq 0) {
  Write-Information 'No changed VI assets detected; skipping compare requests.'
  exit 0
}

$outDir = if ($OutputDir) { Get-DirectoryPath $OutputDir } else { Get-DirectoryPath (Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-diff') }

# Determine current VIP (always) and baseline VIP (optional)
$currentVip = $summary.source.fixturePath
$curExtract = Expand-VipWithSystem -VipPath $currentVip -DestRoot (Join-Path $outDir '__cur')

$overlayRoot = $ResourceOverlayRoot
if (-not $overlayRoot) {
  $defaultOverlay = Join-Path $repoRoot 'vendor/icon-editor/resource'
  if (Test-Path -LiteralPath $defaultOverlay -PathType Container) {
    $overlayRoot = (Resolve-Path -LiteralPath $defaultOverlay).Path
  }
}
if ($overlayRoot -and $curExtract.system) {
  Invoke-ResourceOverlay -OverlayRoot $overlayRoot -SystemRoot $curExtract.system
}

$baseExtract = $null
if ($BaselineFixturePath -and (Test-Path -LiteralPath $BaselineFixturePath -PathType Leaf)) {
  try { $baseExtract = Expand-VipWithSystem -VipPath $BaselineFixturePath -DestRoot (Join-Path $outDir '__base') } catch { $baseExtract = $null }
} else {
  Write-Information '::notice::Baseline VIP not provided; generating head-only compare requests.'
}

function Convert-RelativePath {
  param(
    [string]$Rel,
    [string]$SystemRoot,
    [string]$Category
  )
  if (-not $SystemRoot) { return $null }
  switch ($Category) {
    'test' {
      $testsRoot = Join-Path $SystemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test'
      $sub = $Rel.Substring('tests'.Length).TrimStart('\','/')
      return Join-Path $testsRoot $sub
    }
    'resource' {
      $resourcesRoot = Join-Path $SystemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\resource'
      $sub = $Rel.Substring('resource'.Length).TrimStart('\','/')
      return Join-Path $resourcesRoot $sub
    }
    default { return $null }
  }
}

$pairs = @()
foreach ($e in $candidateVis) {
  $head = Convert-RelativePath -Rel $e.path -SystemRoot $curExtract.system -Category $e.category
  $base = if ($baseExtract) { Convert-RelativePath -Rel $e.path -SystemRoot $baseExtract.system -Category $e.category } else { $null }
  $pairs += [ordered]@{
    name    = [System.IO.Path]::GetFileName($e.path)
    relPath = $e.path
    category= $e.category
    base    = $base
    head    = $head
  }
}

$req = [ordered]@{
  schema   = 'icon-editor/vi-diff-requests@v1'
  generatedAt = (Get-Date).ToString('o')
  count    = $pairs.Count
  requests = $pairs
}
$jsonPath = Join-Path $outDir 'vi-diff-requests.json'
$req | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$md = @("### Icon-Editor: Changed VI compare requests","", "- Requests: $($pairs.Count)")
foreach ($p in ($pairs | Select-Object -First 10)) { $md += ("- ``{0}``" -f $p.relPath) }
if ($pairs.Count -gt 10) { $md += ("- (+{0} more)" -f ($pairs.Count - 10)) }
$mdPath = Join-Path $outDir 'vi-diff-requests.md'
($md -join "`n") | Set-Content -LiteralPath $mdPath -Encoding utf8

Write-Information ("Prepared VI diff requests -> {0}" -f $jsonPath)
