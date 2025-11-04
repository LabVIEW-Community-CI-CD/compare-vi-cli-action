#Requires -Version 7.0

param(
  [Parameter(Mandatory)][string]$ResultsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-Directory {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Results root '$Path' does not exist or is not a directory."
  }
  return (Resolve-Path -LiteralPath $Path).Path
}

$root = Resolve-Directory -Path $ResultsRoot

function Ensure-Bucket {
  param(
    [string]$Root,
    [string]$Name
  )
  $bucketPath = Join-Path $Root $Name
  if (-not (Test-Path -LiteralPath $bucketPath -PathType Container)) {
    New-Item -ItemType Directory -Path $bucketPath -Force | Out-Null
  }
  return (Resolve-Path -LiteralPath $bucketPath).Path
}

function Normalize-Directory([string]$Path) {
  return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
}

$bucketPaths = [ordered]@{
  packages = Ensure-Bucket -Root $root -Name 'packages'
  reports  = Ensure-Bucket -Root $root -Name 'reports'
  logs     = Ensure-Bucket -Root $root -Name 'logs'
}

function Move-FileToBucket {
  param(
    [System.IO.FileInfo]$Item,
    [string]$BucketPath
  )
  $currentParent = Normalize-Directory $Item.DirectoryName
  if ($currentParent -eq (Normalize-Directory $BucketPath)) {
    return $Item.FullName
  }
  $destination = Join-Path $BucketPath $Item.Name
  Move-Item -LiteralPath $Item.FullName -Destination $destination -Force
  return (Resolve-Path -LiteralPath $destination).Path
}

function Copy-FileToBucket {
  param(
    [System.IO.FileInfo]$Item,
    [string]$BucketPath
  )
  $destination = Join-Path $BucketPath $Item.Name
  Copy-Item -LiteralPath $Item.FullName -Destination $destination -Force
  return (Resolve-Path -LiteralPath $destination).Path
}

function Move-DirectoryToBucket {
  param(
    [System.IO.DirectoryInfo]$Item,
    [string]$BucketPath,
    [string]$TargetName
  )
  $currentPath = Normalize-Directory $Item.FullName
  $targetPath = Normalize-Directory (Join-Path $BucketPath ($TargetName ?? $Item.Name))
  if ($currentPath -eq $targetPath) {
    return $Item.FullName
  }
  if (Test-Path -LiteralPath $targetPath) {
    Remove-Item -LiteralPath $targetPath -Recurse -Force
  }
  Move-Item -LiteralPath $Item.FullName -Destination $targetPath -Force
  return (Resolve-Path -LiteralPath $targetPath).Path
}

$movedFiles = [ordered]@{
  packages = New-Object System.Collections.Generic.List[string]
  reports  = New-Object System.Collections.Generic.List[string]
  logs     = New-Object System.Collections.Generic.List[string]
}

# Stage VIPs and LVLibp packages
foreach ($pattern in @('*.vip', '*.lvlibp')) {
  $items = Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue
  foreach ($item in $items) {
    try {
      $dest = Move-FileToBucket -Item $item -BucketPath $bucketPaths.packages
      $movedFiles.packages.Add($dest)
    } catch {
      Write-Warning "Failed to stage '$($item.FullName)' -> packages: $($_.Exception.Message)"
    }
  }
}

# Stage manifest/metadata reports
foreach ($name in @('manifest.json','metadata.json')) {
  $path = Join-Path $root $name
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    try {
      $item = Get-Item -LiteralPath $path
      $dest = Move-FileToBucket -Item $item -BucketPath $bucketPaths.reports
      $movedFiles.reports.Add($dest)
    } catch {
      Write-Warning "Failed to stage '$path' -> reports: $($_.Exception.Message)"
    }
  }
}

# Files that must never be removed from the results root
$preserveReportFiles = @('fixture-report.json', 'fixture-report.md')
$preserveFailures = @()

# Stage fixture reports (preserve originals for hook parity)
foreach ($name in @('fixture-report.json','fixture-report.md')) {
  $path = Join-Path $root $name
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    try {
      $item = Get-Item -LiteralPath $path
      $dest = Copy-FileToBucket -Item $item -BucketPath $bucketPaths.reports
      $movedFiles.reports.Add($dest)
    } catch {
      Write-Warning "Failed to copy '$path' -> reports: $($_.Exception.Message)"
    }
  }
}

# Ensure preserved report files still exist after staging
foreach ($name in $preserveReportFiles) {
  $path = Join-Path $root $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    $preserveFailures += $path
  }
}

if ($preserveFailures.Count -gt 0) {
  $missingList = $preserveFailures -join "', '"
  throw "Stage-BuildArtifacts.ps1 must preserve fixture reports. Missing file(s): '${missingList}'. Update the helper to copy (not move) these reports."
}

# Stage package smoke summary if present
$smokeSummary = Join-Path $root 'package-smoke-summary.json'
if (Test-Path -LiteralPath $smokeSummary -PathType Leaf) {
  try {
    $item = Get-Item -LiteralPath $smokeSummary
    $dest = Move-FileToBucket -Item $item -BucketPath $bucketPaths.logs
    $movedFiles.logs.Add($dest)
  } catch {
    Write-Warning "Failed to stage '$smokeSummary' -> logs: $($_.Exception.Message)"
  }
}

# Stage package smoke directory
$smokeDirPath = Join-Path $root 'package-smoke'
if (Test-Path -LiteralPath $smokeDirPath -PathType Container) {
  try {
    $dir = Get-Item -LiteralPath $smokeDirPath
    $dest = Move-DirectoryToBucket -Item $dir -BucketPath $bucketPaths.logs -TargetName 'package-smoke'
    $movedFiles.logs.Add($dest)
  } catch {
    Write-Warning "Failed to stage package-smoke directory -> logs: $($_.Exception.Message)"
  }
}

# Stage dev-mode integration results
$devModeDirPath = Join-Path $root 'dev-mode-integration'
if (Test-Path -LiteralPath $devModeDirPath -PathType Container) {
  try {
    $dir = Get-Item -LiteralPath $devModeDirPath
    $dest = Move-DirectoryToBucket -Item $dir -BucketPath $bucketPaths.logs -TargetName 'dev-mode-integration'
    $movedFiles.logs.Add($dest)
  } catch {
    Write-Warning "Failed to stage dev-mode-integration directory -> logs: $($_.Exception.Message)"
  }
}

function Get-FinalCount {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    return 0
  }
  return (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
}

$bucketSummaries = [ordered]@{}
foreach ($entry in $bucketPaths.GetEnumerator()) {
  $bucketSummaries[$entry.Key] = [ordered]@{
    path  = $entry.Value
    glob  = ('{0}\**' -f $entry.Value)
    count = Get-FinalCount -Path $entry.Value
  }
}

$result = [pscustomobject]@{
  root    = $root
  buckets = $bucketSummaries
}

return ($result | ConvertTo-Json -Depth 5)
