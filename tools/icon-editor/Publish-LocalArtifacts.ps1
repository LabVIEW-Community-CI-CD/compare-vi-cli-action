#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$ArtifactsRoot = 'tests/results/_agent/icon-editor',
  [string]$GhTokenPath,
  [string]$ReleaseTag,
  [string]$ReleaseName,
  [switch]$SkipUpload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

$repoRoot = (Resolve-RepoRoot)
if (-not $repoRoot) { throw 'Unable to resolve repository root.' }
Push-Location $repoRoot
try {
  $artifactsRootResolved = (Resolve-Path -LiteralPath $ArtifactsRoot -ErrorAction Stop).Path
  $vipRoot = Join-Path $artifactsRootResolved 'vipm-cli-build'
  if (-not (Test-Path -LiteralPath $vipRoot -PathType Container)) {
    throw "VIP build directory not found at '$vipRoot'. Run the build task first."
  }

  $candidateFiles = @()
  $candidateFiles += Get-ChildItem -LiteralPath $vipRoot -Filter '*.vip' -Recurse -ErrorAction SilentlyContinue
  $candidateFiles += Get-ChildItem -LiteralPath $vipRoot -Filter '*.lvlibp' -Recurse -ErrorAction SilentlyContinue
  $candidateFiles += Get-ChildItem -LiteralPath $vipRoot -Filter 'missing-items.json' -ErrorAction SilentlyContinue
  $candidateFiles += Get-ChildItem -LiteralPath $vipRoot -Filter 'manifest.json' -ErrorAction SilentlyContinue

  if (-not $candidateFiles -or $candidateFiles.Count -eq 0) {
    throw "No VIP/PPL artifacts were found under '$vipRoot'."
  }

  $timestamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
  $zipName = "iconeditor-local-artifacts-$timestamp.zip"
  $zipPath = Join-Path $artifactsRootResolved $zipName
  if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
    Remove-Item -LiteralPath $zipPath -Force
  }

  Compress-Archive -Path ($candidateFiles | Select-Object -ExpandProperty FullName) -DestinationPath $zipPath -CompressionLevel Optimal
  Write-Host ("Artifacts packaged: {0}" -f (Resolve-Path -LiteralPath $zipPath).Path)

  if ($SkipUpload -or (-not $GhTokenPath)) {
    Write-Host 'SkipUpload set or no GH token path provided; upload step skipped.'
    return
  }

  if (-not (Test-Path -LiteralPath $GhTokenPath -PathType Leaf)) {
    throw "GH token file not found at '$GhTokenPath'."
  }

  $ghExe = Get-Command gh -ErrorAction SilentlyContinue
  if (-not $ghExe) {
    Write-Warning 'GitHub CLI (gh) is not installed; skipping upload.'
    return
  }

  $commit = (git rev-parse --short HEAD).Trim()
  $tag = if ($ReleaseTag) { $ReleaseTag } else { "local-build-$commit-$timestamp" }
  $name = if ($ReleaseName) { $ReleaseName } else { "Local build $commit ($timestamp)" }

  $env:GH_TOKEN = Get-Content -LiteralPath $GhTokenPath -Raw
  $releaseExists = $false
  try {
    & $ghExe.Source release view $tag 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $releaseExists = $true }
  } catch {
    $releaseExists = $false
  }

  if (-not $releaseExists) {
    Write-Host "Creating release '$tag'."
    & $ghExe.Source release create $tag $zipPath -t $name -n "Local icon-editor build artifacts for $commit." --prerelease --generate-notes
  } else {
    Write-Host "Uploading to existing release '$tag'."
    & $ghExe.Source release upload $tag $zipPath --clobber
  }
  if ($LASTEXITCODE -ne 0) {
    throw "gh release command failed with exit code $LASTEXITCODE."
  }
  Write-Host 'Upload complete.'
}
finally {
  Pop-Location
}
