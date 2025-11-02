#Requires -Version 7.0

param(
  [string]$ReportPath,
  [string]$BaselineManifestPath,
  [string]$BaselineFixturePath,
  [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

function Ensure-Directory { param([string]$Path) $n = New-Item -ItemType Directory -Force -Path $Path; return (Resolve-Path -LiteralPath $n).Path }

function Expand-VipWithSystem {
  param([string]$VipPath, [string]$DestRoot)
  if (-not (Test-Path -LiteralPath $VipPath -PathType Leaf)) { throw "VI Package not found: $VipPath" }
  $root = Ensure-Directory $DestRoot
  Expand-Archive -Path $VipPath -DestinationPath $root -Force
  $systemVip = Join-Path $root 'Packages/ni_icon_editor_system-1.4.1.948.vip'
  $systemRoot = Join-Path $root '__system_extract'
  if (Test-Path -LiteralPath $systemVip -PathType Leaf) {
    Expand-Archive -Path $systemVip -DestinationPath $systemRoot -Force
  }
  return [ordered]@{ extract=$root; system=$systemRoot }
}

function Build-CurrentManifestFromReport { param($Summary)
  $entries = @()
  foreach ($asset in ($Summary.fixtureOnlyAssets | Sort-Object category, name)) {
    $rel = if ($asset.category -eq 'script') { Join-Path 'scripts' $asset.name } else { Join-Path 'tests' $asset.name }
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

function Compute-Delta { param($BaseEntries, $NewEntries)
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
$delta = Compute-Delta -BaseEntries $baseline.entries -NewEntries $currentEntries

$changedVis = @($delta.changed | Where-Object { $_.path -match '\.vi$' -and $_.category -eq 'test' })
if ($changedVis.Count -eq 0) {
  Write-Host 'No changed VI assets detected; skipping compare requests.'
  exit 0
}

$outDir = if ($OutputDir) { Ensure-Directory $OutputDir } else { Ensure-Directory (Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-diff') }

# Determine current VIP (always) and baseline VIP (optional)
$currentVip = $summary.source.fixturePath
$curExtract = Expand-VipWithSystem -VipPath $currentVip -DestRoot (Join-Path $outDir '__cur')

$baseExtract = $null
if ($BaselineFixturePath -and (Test-Path -LiteralPath $BaselineFixturePath -PathType Leaf)) {
  try { $baseExtract = Expand-VipWithSystem -VipPath $BaselineFixturePath -DestRoot (Join-Path $outDir '__base') } catch { $baseExtract = $null }
} else {
  Write-Host '::notice::Baseline VIP not provided; generating head-only compare requests.'
}

function Map-TestRelToFull {
  param([string]$Rel, [string]$SystemRoot)
  if (-not $SystemRoot) { return $null }
  $testsRoot = Join-Path $SystemRoot 'File Group 0/National Instruments/LabVIEW Icon Editor/Test'
  $sub = $Rel.Substring('tests'.Length).TrimStart('\','/')
  return Join-Path $testsRoot $sub
}

$pairs = @()
foreach ($e in $changedVis) {
  $head = Map-TestRelToFull -Rel $e.path -SystemRoot $curExtract.system
  $base = if ($baseExtract) { Map-TestRelToFull -Rel $e.path -SystemRoot $baseExtract.system } else { $null }
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

Write-Host "Prepared VI diff requests -> $jsonPath"
