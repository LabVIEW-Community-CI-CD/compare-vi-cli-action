<#
.SYNOPSIS
  Copy VI inputs into a temporary staging directory for safe LVCompare usage.

.DESCRIPTION
  Creates a temporary directory and copies the supplied Base/Head VI files into
  canonical filenames (`Base.vi` and `Head.vi`). Returns the staged paths plus
  the staging root so callers can clean up after the compare run. The helper
  guarantees the temp directory exists and surfaces actionable messages when
  the source files cannot be resolved.

.PARAMETER BaseVi
  Source path for the base VI (absolute or relative).

.PARAMETER HeadVi
  Source path for the head VI (absolute or relative).

.PARAMETER WorkingRoot
  Optional root directory used when allocating the staging directory. Defaults
  to the system temporary directory.

.OUTPUTS
  PSCustomObject with `Base`, `Head`, and `Root` properties that point to the
  staged files and directory.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BaseVi,
  [Parameter(Mandatory)][string]$HeadVi,
  [string]$WorkingRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsoluteFile {
  param([string]$Path,[string]$ParameterName)
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$ParameterName cannot be empty."
  }
  try {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
  } catch {
    throw "Unable to resolve $ParameterName path: $Path"
  }
  $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
  if ($item.PSIsContainer) {
    throw "$ParameterName refers to a directory, expected a VI file: $($item.FullName)"
  }
  return $item.FullName
}

$tempRoot = $null
try { $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()) } catch { $tempRoot = $null }
$relevantExtensions = @(
  '.vi', '.vit', '.ctl', '.ctt',
  '.lvlib', '.lvclass', '.lvproj', '.lvlibp', '.lvmodel',
  '.lvsc', '.lvtest', '.mnu', '.rtm', '.gvi', '.gviweb', '.gcomp'
)

function Should-MirrorSource {
  param([string]$SourcePath)
  $parent = Split-Path -Parent $SourcePath
  if (-not $parent) { return $false }
  if (-not (Test-Path -LiteralPath $parent -PathType Container)) { return $false }
  $parentFull = try { [System.IO.Path]::GetFullPath($parent) } catch { $parent }

  $entries = @()
  try { $entries = Get-ChildItem -LiteralPath $parent -Force -ErrorAction Stop } catch { $entries = @() }

  $hasSiblingArtifacts = $false
  foreach ($entry in $entries) {
    if ($entry.PSIsContainer) {
      if (-not ($entry.Name -match '^\.(git|svn)$')) {
        $hasSiblingArtifacts = $true
        break
      }
      continue
    }
    if ($entry.FullName -eq $SourcePath) { continue }
    $ext = $entry.Extension
    if ($ext -and ($relevantExtensions -contains $ext.ToLowerInvariant())) {
      $hasSiblingArtifacts = $true
      break
    }
  }

  if (-not $hasSiblingArtifacts) { return $false }
  if ($tempRoot -and $parentFull) {
    if ($parentFull.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $hasSiblingArtifacts
}

$baseSource = Resolve-AbsoluteFile -Path $BaseVi -ParameterName 'BaseVi'
$headSource = Resolve-AbsoluteFile -Path $HeadVi -ParameterName 'HeadVi'

$rootParent = if ([string]::IsNullOrWhiteSpace($WorkingRoot)) {
  [System.IO.Path]::GetTempPath()
} else {
  $WorkingRoot
}

try {
  if (-not (Test-Path -LiteralPath $rootParent -PathType Container)) {
    New-Item -ItemType Directory -Path $rootParent -Force | Out-Null
  }
} catch {
  throw "Unable to prepare staging working root: $rootParent"
}

$stagingRoot = Join-Path $rootParent ("comparevi-stage-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$mirrorBase = Should-MirrorSource -SourcePath $baseSource
$mirrorHead = Should-MirrorSource -SourcePath $headSource

$mirrorStage = $mirrorBase -or $mirrorHead

function Copy-Tree {
  param(
    [string]$SourceFile,
    [string]$StageRoot,
    [string]$Label
  )

  $parentDir = Split-Path -Parent $SourceFile
  $targetDir = Join-Path $StageRoot $Label
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  Copy-Item -LiteralPath $parentDir -Destination $targetDir -Recurse -Force
  $parentLeaf = Split-Path -Leaf $parentDir
  $candidate = Join-Path (Join-Path $targetDir $parentLeaf) (Split-Path -Leaf $SourceFile)
  try { return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path } catch { return $candidate }
}

if ($mirrorStage) {
  $stagedBase = if ($mirrorBase) {
    Copy-Tree -SourceFile $baseSource -StageRoot $stagingRoot -Label 'base'
  } else {
    $leafBase = Join-Path (Join-Path $stagingRoot 'base-single') 'Base.vi'
    New-Item -ItemType Directory -Path (Split-Path -Parent $leafBase) -Force | Out-Null
    Copy-Item -LiteralPath $baseSource -Destination $leafBase -Force
    try { (Resolve-Path -LiteralPath $leafBase -ErrorAction Stop).Path } catch { $leafBase }
  }

  $stagedHead = if ($mirrorHead) {
    Copy-Tree -SourceFile $headSource -StageRoot $stagingRoot -Label 'head'
  } else {
    $leafHead = Join-Path (Join-Path $stagingRoot 'head-single') 'Head.vi'
    New-Item -ItemType Directory -Path (Split-Path -Parent $leafHead) -Force | Out-Null
    Copy-Item -LiteralPath $headSource -Destination $leafHead -Force
    try { (Resolve-Path -LiteralPath $leafHead -ErrorAction Stop).Path } catch { $leafHead }
  }
} else {
  $stagedBase = Join-Path $stagingRoot 'Base.vi'
  $stagedHead = Join-Path $stagingRoot 'Head.vi'

  Copy-Item -LiteralPath $baseSource -Destination $stagedBase -Force
  Copy-Item -LiteralPath $headSource -Destination $stagedHead -Force
}

$finalBaseLeaf = Split-Path -Leaf $stagedBase
$finalHeadLeaf = Split-Path -Leaf $stagedHead
$allowSameLeaf =
  ($finalBaseLeaf -and $finalHeadLeaf -and
   [string]::Equals($finalBaseLeaf, $finalHeadLeaf, [System.StringComparison]::OrdinalIgnoreCase))

return [pscustomobject]@{
  Base = (Resolve-Path -LiteralPath $stagedBase).Path
  Head = (Resolve-Path -LiteralPath $stagedHead).Path
  Root = (Resolve-Path -LiteralPath $stagingRoot).Path
  Mode = if ($mirrorStage) { 'mirror' } else { 'single-file' }
  AllowSameLeaf = $allowSameLeaf
}
