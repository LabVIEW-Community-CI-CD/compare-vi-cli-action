#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepositoryRoot,
  [string]$Name,
  [switch]$SkipUntrackedCopy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitStatus {
  param([string]$RepoRoot)
  Push-Location $RepoRoot
  try {
    $result = & git status --porcelain=1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      throw "git status failed with exit code $exit."
    }
    return @($result)
  } finally {
    Pop-Location
  }
}

function Get-RepoRoot {
  param([string]$RepositoryRoot)
  if ($RepositoryRoot) {
    $resolved = Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop
    return $resolved.Path
  }
  $root = (& git rev-parse --show-toplevel)
  if ($LASTEXITCODE -ne 0 -or -not $root) {
    throw 'Not inside a git repository.'
  }
  return $root.Trim()
}

function Resolve-SnapshotPath {
  param([string]$RepoRoot,[string]$Name)
  $timestamp = (Get-Date).ToString('yyyyMMddTHHmmssfffZ')
  $id = if ($Name) {
    $sanitized = ($Name -replace '[^a-zA-Z0-9\-_]', '-')
    if ([string]::IsNullOrWhiteSpace($sanitized)) { "snapshot-$timestamp" } else { "$timestamp-$sanitized" }
  } else {
    "snapshot-$timestamp"
  }
  $base = Join-Path $RepoRoot 'tests/results/_agent/wip'
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $path = Join-Path $base $id
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Write-TrackedPatch {
  param([string]$RepoRoot,[string]$Destination)
  Push-Location $RepoRoot
  try {
    $patch = & git diff --binary HEAD
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
      throw "git diff failed with exit code $exit."
    }
    if ($patch) {
      $patch | Set-Content -LiteralPath $Destination -Encoding utf8
    } else {
      New-Item -ItemType File -Path $Destination -Force | Out-Null
    }
  } finally {
    Pop-Location
  }
}

function Copy-UntrackedItems {
  param([string]$RepoRoot,[object[]]$Items,[string]$Destination)
  foreach ($item in $Items) {
    $rel = $item.Path
    $source = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $source)) { continue }
    $target = Join-Path $Destination $rel
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $source -PathType Container) {
      Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
    } else {
      Copy-Item -LiteralPath $source -Destination $target -Force
    }
  }
}

function Parse-StatusLines {
  param([string[]]$Lines)
  $entries = @()
  foreach ($line in $Lines) {
    if (-not $line) { continue }
    $code = $line.Substring(0,2)
    $rawPath = $line.Substring(3)
    switch ($code) {
      '??' {
        $entries += [pscustomobject]@{
          Path   = $rawPath.Trim()
          Kind   = 'untracked'
          Status = '??'
        }
      }
      default {
        $statusCode = $code.Trim()
        $path = $rawPath
        if ($statusCode.StartsWith('R') -and $rawPath -match '->') {
          $parts = $rawPath -split '->',2
          $path = $parts[1].Trim()
        }
        $entries += [pscustomobject]@{
          Path   = $path.Trim()
          Kind   = 'tracked'
          Status = $statusCode
        }
      }
    }
  }
  return $entries
}

$repoRoot = Get-RepoRoot -RepositoryRoot $RepositoryRoot
$statusLines = Invoke-GitStatus -RepoRoot $repoRoot
if (-not $statusLines -or $statusLines.Count -eq 0) {
  Write-Host '[wip] Working tree is clean; nothing to snapshot.' -ForegroundColor Green
  return
}

$entries = Parse-StatusLines -Lines $statusLines
if ($entries.Count -eq 0) {
  Write-Host '[wip] No eligible files detected; skipping snapshot.' -ForegroundColor Yellow
  return
}

$snapshotDir = Resolve-SnapshotPath -RepoRoot $repoRoot -Name $Name
$patchPath = Join-Path $snapshotDir 'tracked.patch'
Write-TrackedPatch -RepoRoot $repoRoot -Destination $patchPath

$untracked = @($entries | Where-Object { $_.Kind -eq 'untracked' })
if ($untracked.Count -gt 0 -and -not $SkipUntrackedCopy) {
  $untrackedDir = Join-Path $snapshotDir 'untracked'
  New-Item -ItemType Directory -Path $untrackedDir -Force | Out-Null
  Copy-UntrackedItems -RepoRoot $repoRoot -Items $untracked -Destination $untrackedDir
}

$metadata = [ordered]@{
  schema      = 'wip-snapshot/v1'
  generatedAt = (Get-Date).ToString('o')
  repoRoot    = $repoRoot
  snapshot    = Split-Path -Leaf $snapshotDir
  trackedPatch= 'tracked.patch'
  copiedUntracked = if ($untracked.Count -gt 0 -and -not $SkipUntrackedCopy) { $true } else { $false }
  entries     = $entries
}
$metadataPath = Join-Path $snapshotDir 'snapshot.json'
$metadata | ConvertTo-Json -Depth 6 | Out-File -FilePath $metadataPath -Encoding utf8

Write-Host ("[wip] Snapshot saved to {0}" -f $snapshotDir) -ForegroundColor Cyan
