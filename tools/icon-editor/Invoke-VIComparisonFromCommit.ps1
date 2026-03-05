#Requires -Version 7.0

param(
  [string]$Commit,
  [string]$RepoPath,
  [string]$RepoSlug = 'LabVIEW-Community-CI-CD/labview-icon-editor',
  [string]$Branch = 'develop',
  [string]$WorkspaceRoot,
  [string]$StageName,
  [switch]$SkipSync,
  [switch]$SkipValidate,
  [switch]$SkipLVCompare,
  [switch]$DryRun,
  [switch]$SkipBootstrapForValidate,
  [string[]]$IncludePaths,
  [string[]]$ExcludePaths,
  [string]$HeadlessCompareScript,
  [string]$LabVIEWExePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim()
  } catch {
    return $StartPath
  }
}

$repoRoot = Resolve-RepoRoot
$vendorModulePath = Join-Path $repoRoot 'tools/VendorTools.psm1'
if (Test-Path -LiteralPath $vendorModulePath -PathType Leaf) {
  Import-Module $vendorModulePath -Force
}

function Normalize-RepoPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $normalized = $Path.Replace('\', '/')
  while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
  if ($normalized.StartsWith('/')) { $normalized = $normalized.Substring(1) }
  return $normalized
}

function Ensure-Repo {
  param(
    [string]$TargetPath,
    [string]$RepoSlug,
    [string]$Branch,
    [switch]$SkipSync
  )
  $syncScript = Join-Path $repoRoot 'tools/icon-editor/Sync-IconEditorFork.ps1'
  if (-not $TargetPath) {
    $TargetPath = Join-Path $repoRoot 'tmp/icon-editor/repo'
  }
  if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    if ($SkipSync.IsPresent) {
      throw "Repository path '$TargetPath' not found; run Sync-IconEditorFork.ps1 or omit -SkipSync."
    }
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
      throw "Sync helper not available at '$syncScript'. Provide -RepoPath."
    }
    Write-Information ("==> Cloning icon-editor repo to {0}" -f $TargetPath)
    & $syncScript -RepoSlug $RepoSlug -Branch $Branch -WorkingPath $TargetPath | Out-Null
  } elseif (-not $SkipSync.IsPresent -and (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    Write-Information ("==> Refreshing {0} from {1}" -f $TargetPath, $RepoSlug)
    & $syncScript -RepoSlug $RepoSlug -Branch $Branch -WorkingPath $TargetPath | Out-Null
  }
  if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
    throw "Repository path '$TargetPath' not found after sync attempt."
  }
  return $TargetPath
}

$repoResolved = Ensure-Repo -TargetPath $RepoPath -RepoSlug $RepoSlug -Branch $Branch -SkipSync:$SkipSync

$resolved2025 = $null
if (Get-Command -Name Resolve-LabVIEW2025Environment -ErrorAction SilentlyContinue) {
  $resolved2025 = Resolve-LabVIEW2025Environment -ThrowOnMissing:([string]::IsNullOrWhiteSpace($LabVIEWExePath))
  if (-not $LabVIEWExePath -and $resolved2025) {
    $LabVIEWExePath = $resolved2025.LabVIEWExePath
  }
  if ($resolved2025 -and $resolved2025.LabVIEWCliPath) {
    [System.Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $resolved2025.LabVIEWCliPath, 'Process')
  }
  if ($resolved2025 -and $resolved2025.LVComparePath) {
    [System.Environment]::SetEnvironmentVariable('LVCOMPARE_PATH', $resolved2025.LVComparePath, 'Process')
  }
}
if ($LabVIEWExePath) {
  [System.Environment]::SetEnvironmentVariable('LABVIEW_PATH', $LabVIEWExePath, 'Process')
  if (-not (Test-Path -LiteralPath $LabVIEWExePath -PathType Leaf)) {
    throw "LabVIEW 2025 (64-bit) executable not found at '$LabVIEWExePath'."
  }
  if ($LabVIEWExePath -match '(?i)Program Files \(x86\)') {
    throw "LabVIEW 2025 (64-bit) required. The provided path '$LabVIEWExePath' appears to target the 32-bit installation."
  }
} elseif ($resolved2025 -and $resolved2025.LabVIEWExePath) {
  $LabVIEWExePath = $resolved2025.LabVIEWExePath
  if (-not (Test-Path -LiteralPath $LabVIEWExePath -PathType Leaf)) {
    throw "LabVIEW 2025 (64-bit) executable not found at '$LabVIEWExePath'."
  }
  [System.Environment]::SetEnvironmentVariable('LABVIEW_PATH', $LabVIEWExePath, 'Process')
} else {
  throw 'LabVIEW 2025 (64-bit) executable not resolved. Provide -LabVIEWExePath, set LABVIEW_PATH, or update configs/labview-paths(.local).json.'
}

if (-not $Commit) {
  throw 'Commit hash (or ref) must be provided.'
}

function Resolve-GitHash {
  param(
    [string]$Repo,
    [string]$Ref,
    [switch]$Optional
  )
  $args = @('-C', $Repo, 'rev-parse', '--verify', $Ref)
  $output = & git @args 2>&1
  if ($LASTEXITCODE -ne 0) {
    if ($Optional.IsPresent) {
      return $null
    }
    throw "git $($args -join ' ') failed: $output"
  }
  return ($output -split "`n")[0].Trim()
}

$commitFull = Resolve-GitHash -Repo $repoResolved -Ref $Commit
$parentFull = $null
$parentFull = Resolve-GitHash -Repo $repoResolved -Ref "$Commit^" -Optional
if (-not $parentFull) {
  Write-Information ("Commit {0} has no parent (likely initial commit); skipping staging." -f $commitFull.Substring(0,8))
  return [pscustomobject]@{
    commit         = $commitFull
    parent         = $null
    overlayRoot    = $null
    files          = @()
    staged         = $false
    stageSummary   = $null
  }
}

$overlayRoot = Join-Path $repoRoot ("tmp/icon-editor/overlays/{0}" -f $commitFull.Substring(0,8))
Write-Information ("==> Preparing overlay at {0}" -f $overlayRoot)

$prepareOverlay = Join-Path $repoRoot 'tools/icon-editor/Prepare-OverlayFromRepo.ps1'
$prepareParams = @{
  RepoPath   = $repoResolved
  BaseRef    = $parentFull
  HeadRef    = $commitFull
  OverlayRoot= $overlayRoot
  Force      = $true
}

$overlaySummary = & $prepareOverlay @prepareParams
if ($overlaySummary.files.Count -eq 0) {
  Write-Information ("No VI changes detected for commit {0}; skipping snapshot staging." -f $commitFull.Substring(0,8))
  return [pscustomobject]@{
    commit         = $commitFull
    parent         = $parentFull
    overlayRoot    = $overlaySummary.overlayRoot
    files          = @()
    staged         = $false
    stageSummary   = $null
  }
}

$stageScript = Join-Path $repoRoot 'tools/icon-editor/Stage-IconEditorSnapshot.ps1'
$workspace = if ($WorkspaceRoot) { $WorkspaceRoot } else { Join-Path $repoRoot 'tests/results/_agent/icon-editor/snapshots' }
$stageNameResolved = if ($StageName) { $StageName } else { "commit-{0}" -f $commitFull.Substring(0,8) }

$effectiveFiles = @()
if ($overlaySummary.files) {
  $effectiveFiles = @($overlaySummary.files)
}

if ($IncludePaths -and $IncludePaths.Count -gt 0) {
  $includeSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($raw in $IncludePaths) {
    $norm = Normalize-RepoPath -Path $raw
    if ($norm) { $includeSet.Add($norm) | Out-Null }
  }
  $effectiveFiles = @(
    foreach ($rel in $effectiveFiles) {
      $norm = Normalize-RepoPath -Path $rel
      if ($norm -and $includeSet.Contains($norm)) { $rel }
    }
  )
}

if ($ExcludePaths -and $ExcludePaths.Count -gt 0 -and $effectiveFiles.Count -gt 0) {
  $excludeSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($raw in $ExcludePaths) {
    $norm = Normalize-RepoPath -Path $raw
    if ($norm) { $excludeSet.Add($norm) | Out-Null }
  }
  $effectiveFiles = @(
    foreach ($rel in $effectiveFiles) {
      $norm = Normalize-RepoPath -Path $rel
      if ($norm -and -not $excludeSet.Contains($norm)) { $rel }
    }
  )
}

if ($effectiveFiles.Count -eq 0) {
  Write-Information ("Filtered commit {0}; no VI files selected for comparison." -f $commitFull.Substring(0,8))
  return [pscustomobject]@{
    commit         = $commitFull
    parent         = $parentFull
    overlayRoot    = $overlaySummary.overlayRoot
    files          = @()
    staged         = $false
    stageSummary   = $null
  }
}

Write-Information ("==> Staging snapshot '{0}' (workspace: {1})" -f $stageNameResolved, $workspace)
$stageParams = @{
  SourcePath          = $repoResolved
  ResourceOverlayRoot = $overlaySummary.overlayRoot
  StageName           = $stageNameResolved
  WorkspaceRoot       = $workspace
}
if ($SkipValidate.IsPresent) { $stageParams['SkipValidate'] = $true }
if ($SkipLVCompare.IsPresent) { $stageParams['SkipLVCompare'] = $true }
if ($DryRun.IsPresent) { $stageParams['DryRun'] = $true }
if ($SkipBootstrapForValidate.IsPresent) { $stageParams['SkipBootstrapForValidate'] = $true }

$stageSummary = & $stageScript @stageParams

# Also attempt raw commit-to-commit VI comparisons to produce captures even when the VIP baseline lacks a file.
$compareScript = if ($HeadlessCompareScript) { $HeadlessCompareScript } else { Join-Path $repoRoot 'tools/Run-HeadlessCompare.ps1' }
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  Write-Warning ("Headless compare script not found at '{0}'; skipping raw comparisons." -f $compareScript)
} else {
  $rawRoot = Join-Path $stageSummary.stageRoot 'manual-compare'
  if (-not (Test-Path -LiteralPath $rawRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $rawRoot -Force) }

  # Extensions that LVCompare can consume directly
  $viExts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($e in @('.vi','.vim','.vit','.ctl','.ctt')) { [void]$viExts.Add($e) }

  $index = 0
  foreach ($relPath in $effectiveFiles) {
    $ext = [System.IO.Path]::GetExtension($relPath)
    if (-not $viExts.Contains($ext)) { continue }
    $index++
    $destRoot = Join-Path $rawRoot ('vi-{0:000}' -f $index)
    [void](New-Item -ItemType Directory -Path $destRoot -Force)

    # Head path comes from the overlay we just produced; copy to ensure distinct leaf names
    $headOverlay = Join-Path $overlaySummary.overlayRoot ($relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $headOverlay -PathType Leaf)) { continue }
    $headLeaf = (Split-Path -Path $relPath -Leaf)
    $headAbs = Join-Path $destRoot ([System.IO.Path]::GetFileNameWithoutExtension($headLeaf) + '-head' + $ext)
    Copy-Item -LiteralPath $headOverlay -Destination $headAbs -Force

    # Base file: materialize from parent commit as a real file alongside
    $baseAbs = Join-Path $destRoot ([System.IO.Path]::GetFileNameWithoutExtension($headLeaf) + '-base' + $ext)
    try {
      $psi = New-Object System.Diagnostics.ProcessStartInfo 'git'
      foreach ($arg in @('-C', $repoResolved, 'show', '--no-textconv', "$parentFull`:$relPath")) { [void]$psi.ArgumentList.Add($arg) }
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $proc = [System.Diagnostics.Process]::Start($psi)
      $fs = [System.IO.File]::Open($baseAbs, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
      try {
        $proc.StandardOutput.BaseStream.CopyTo($fs)
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
          $stderr = $proc.StandardError.ReadToEnd()
          Write-Warning ("git show {0}:{1} failed: {2}" -f $parentFull, $relPath, $stderr)
          continue
        }
      } finally {
        $fs.Dispose()
        if ($null -ne $proc) { $proc.Dispose() }
      }
    } catch {
      Write-Warning ("Failed to materialize base for {0}: {1}" -f $relPath, $_.Exception.Message)
      continue
    }

    # Invoke headless compare with raw paths
    $outRoot = Join-Path $destRoot 'captures'
    try {
      $hcParams = @{
        BaseVi = $baseAbs
        HeadVi = $headAbs
        OutputRoot = $outRoot
        UseRawPaths = $true
        WarmupMode = 'skip'
        NoiseProfile = 'full'
        TimeoutSeconds = 900
      }
      if ($LabVIEWExePath) { $hcParams['LabVIEWExePath'] = $LabVIEWExePath }
      & $compareScript @hcParams | Out-Null
    } catch {
      Write-Warning ("Headless compare failed for {0}: {1}" -f $relPath, $_.Exception.Message)
    }
  }
}

return [pscustomobject]@{
  commit         = $commitFull
  parent         = $parentFull
  overlayRoot    = $overlaySummary.overlayRoot
  files          = $effectiveFiles
  staged         = $true
  stageSummary   = $stageSummary
}
