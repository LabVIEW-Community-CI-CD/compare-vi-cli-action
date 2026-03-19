#Requires -Version 7.0
param(
  [string]$Tag = 'comparevi-vi-history-dev:local',
  [string]$BaseImage = 'nationalinstruments/labview:2026q1-linux',
  [switch]$NoCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  try { return (git rev-parse --show-toplevel 2>$null).Trim() } catch { return (Get-Location).Path }
}

$root = Resolve-RepoRoot
$dockerfile = Join-Path $root 'tools/docker/Dockerfile.vi-history-dev'
if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) {
  throw "Dockerfile not found at $dockerfile"
}

$repoSource = 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action'
$repoRevision = ''
try {
  $repoRevision = (git -C $root rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
} catch {
  $repoRevision = ''
}
if ([string]::IsNullOrWhiteSpace($repoRevision)) {
  $repoRevision = 'unknown'
}

$args = @(
  'build',
  '-f', $dockerfile,
  '-t', $Tag,
  '--build-arg', ("BASE_IMAGE={0}" -f $BaseImage),
  '--build-arg', ("REPO_SOURCE={0}" -f $repoSource),
  '--build-arg', ("REPO_REVISION={0}" -f $repoRevision),
  $root
)
if ($NoCache) {
  $args = @(
    'build',
    '--no-cache',
    '-f', $dockerfile,
    '-t', $Tag,
    '--build-arg', ("BASE_IMAGE={0}" -f $BaseImage),
    '--build-arg', ("REPO_SOURCE={0}" -f $repoSource),
    '--build-arg', ("REPO_REVISION={0}" -f $repoRevision),
    $root
  )
}

Write-Host ("[vi-history-dev-image] docker {0}" -f ($args -join ' ')) -ForegroundColor Cyan
& docker @args
if ($LASTEXITCODE -ne 0) {
  throw "docker build failed with code $LASTEXITCODE"
}

Write-Host ("[vi-history-dev-image] Built image: {0}" -f $Tag) -ForegroundColor Green
