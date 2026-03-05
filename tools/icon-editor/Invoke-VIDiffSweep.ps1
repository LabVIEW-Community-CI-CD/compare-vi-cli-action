#Requires -Version 7.0

param(
  [string]$RepoPath,
  [string]$RepoSlug = 'LabVIEW-Community-CI-CD/labview-icon-editor',
  [string]$Branch = 'develop',
  [string]$BaseRef,
  [string]$HeadRef,
  [int]$MaxCommits = 50,
  [string[]]$Kinds = @('vi'),
  [string[]]$IncludePatterns,
  [string[]]$Extensions,
  [string]$OutputPath,
  [int]$SummaryCount = 10,
  [switch]$SkipSync,
  [switch]$Quiet
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
$findScript = Join-Path $repoRoot 'tools/compare/Find-VIComparisonCandidates.ps1'
if (-not (Test-Path -LiteralPath $findScript -PathType Leaf)) {
  throw "Find-VIComparisonCandidates.ps1 not found at '$findScript'."
}

$syncScript = Join-Path $repoRoot 'tools/icon-editor/Sync-IconEditorFork.ps1'

if (-not $RepoPath) {
  $defaultRepo = Join-Path $repoRoot 'tmp/icon-editor/repo'
  if (-not (Test-Path -LiteralPath $defaultRepo -PathType Container)) {
    if ($SkipSync.IsPresent) {
      throw "Default sweep repository '$defaultRepo' not found. Run Sync-IconEditorFork.ps1 or provide -RepoPath."
    }
    if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
      throw "Sync helper not found at '$syncScript'. Provide -RepoPath explicitly."
    }
    Write-Information ("==> Syncing icon-editor fork to {0}" -f $defaultRepo)
    $syncArgs = @{
      RepoSlug    = $RepoSlug
      Branch      = $Branch
      WorkingPath = $defaultRepo
    }
    & $syncScript @syncArgs | Out-Null
  } elseif (-not $SkipSync.IsPresent) {
    if (Test-Path -LiteralPath $syncScript -PathType Leaf) {
      Write-Information ("==> Refreshing {0} from {1}" -f $defaultRepo, $RepoSlug)
      $syncArgs = @{
        RepoSlug    = $RepoSlug
        Branch      = $Branch
        WorkingPath = $defaultRepo
      }
      & $syncScript @syncArgs | Out-Null
    }
  }
  $RepoPath = $defaultRepo
}

if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
  throw "Repository path '$RepoPath' not found."
}

if (-not $HeadRef) {
  $HeadRef = "origin/$Branch"
}
if (-not $BaseRef) {
  $BaseRef = "$HeadRef~$MaxCommits"
}

if (-not $OutputPath) {
  $OutputPath = Join-Path $repoRoot 'tests/results/_agent/icon-editor/vi-changes.json'
}

$findParams = @{
  RepoPath        = $RepoPath
  BaseRef         = $BaseRef
  HeadRef         = $HeadRef
  MaxCommits      = $MaxCommits
  OutputPath      = $OutputPath
}
if ($Kinds) { $findParams['Kinds'] = $Kinds }
if ($IncludePatterns) { $findParams['IncludePatterns'] = $IncludePatterns }
if ($Extensions) { $findParams['Extensions'] = $Extensions }

$candidates = & $findScript @findParams

if (-not $Quiet.IsPresent) {
  Write-Host "==> VI comparison candidates"
  Write-Host ("    repo    : {0}" -f $candidates.repoPath)
  Write-Host ("    range   : {0}..{1}" -f $candidates.baseRef, $candidates.headRef)
  Write-Host ("    kinds   : {0}" -f ($candidates.kinds -join ', '))
  Write-Host ("    commits : {0}" -f $candidates.totalCommits)
  Write-Host ("    files   : {0}" -f $candidates.totalFiles)
  Write-Host ("    summary : {0}" -f $OutputPath)

  if ($candidates.totalCommits -eq 0) {
    Write-Host "    (no candidate VI changes detected)"
  } else {
    $rows = $candidates.commits | Select-Object -First ([math]::Max(1, [math]::Min($SummaryCount, $candidates.totalCommits)))
    foreach ($row in $rows) {
      $firstPath = $row.files[0].path
      $displayPath = if ($row.fileCount -gt 1) {
        "{0} (+{1} more)" -f $firstPath, ($row.fileCount - 1)
      } else {
        $firstPath
      }
      $line = "{0}  {1:yyyy-MM-dd}  {2}  {3}  {4}" -f ($row.commit.Substring(0,8)), ([datetime]::Parse($row.authorDate)), $row.author, $row.subject, $displayPath
      Write-Host ("    " + $line)
    }
  }
}

return [pscustomobject]@{
  candidates = $candidates
  outputPath = $OutputPath
}
