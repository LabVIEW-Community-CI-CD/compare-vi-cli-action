param(
  [string]$ResultsDir = 'tests/results'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-PathSafe([string]$path) {
  try { return (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path }
  catch { return $null }
}

$canonicalPath = Join-Path $ResultsDir 'compare-report.html'
$manifestPath  = Join-Path $ResultsDir 'compare-report.manifest.json'

$hasCanonical = Test-Path -LiteralPath $canonicalPath -PathType Leaf
$hasManifest  = Test-Path -LiteralPath $manifestPath -PathType Leaf

if (-not $hasCanonical -and -not $hasManifest) {
  Write-Host "[compare-manifest] No canonical compare report found; nothing to validate." -ForegroundColor DarkGray
  exit 0
}

if ($hasCanonical -and -not $hasManifest) {
  throw "[compare-manifest] Canonical compare report exists at '$canonicalPath' but manifest '$manifestPath' is missing."
}

if (-not $hasCanonical -and $hasManifest) {
  throw "[compare-manifest] Manifest '$manifestPath' exists but canonical compare report '$canonicalPath' is missing."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6
if (-not $manifest) { throw "[compare-manifest] Unable to parse manifest JSON at '$manifestPath'." }

$canonicalResolved = Resolve-PathSafe $canonicalPath
if (-not $canonicalResolved) {
  throw "[compare-manifest] Failed to resolve canonical compare report path '$canonicalPath'."
}

if ($manifest.canonical -and ($manifest.canonical -ne $canonicalResolved)) {
  throw "[compare-manifest] Manifest canonical path '$($manifest.canonical)' does not match resolved path '$canonicalResolved'."
}

if (-not $manifest.sources -or $manifest.sources.Count -eq 0) {
  throw "[compare-manifest] Manifest contains no sources."
}

$canonicalEntries = @($manifest.sources | Where-Object { $_.sourceType -eq 'canonical' -and $_.path -eq $canonicalResolved })
if ($canonicalEntries.Count -ne 1) {
  throw "[compare-manifest] Manifest must include exactly one canonical source entry matching '$canonicalResolved'."
}

$stagingFilesPresent = @(Get-ChildItem -LiteralPath $ResultsDir -Filter 'compare-report.html' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\_staging\\compare\\' })

$stagingSources = @($manifest.sources | Where-Object { $_.sourceType -eq 'staging' })
if ($stagingFilesPresent.Count -gt 0 -and $stagingSources.Count -lt 1) {
  throw "[compare-manifest] Manifest must include at least one staging source entry when staging reports are present."
}

foreach ($src in $manifest.sources) {
  if (-not $src.path) { throw "[compare-manifest] Manifest source entry is missing 'path'." }
  $resolvedSource = Resolve-PathSafe $src.path
  if (-not $resolvedSource -or -not (Test-Path -LiteralPath $resolvedSource -PathType Leaf)) {
    throw "[compare-manifest] Manifest references missing source file '$($src.path)'."
  }
  if (-not $src.sha256) { throw "[compare-manifest] Manifest entry '$($src.path)' is missing sha256 hash." }
}

Write-Host "[compare-manifest] Manifest OK: $manifestPath" -ForegroundColor Green
