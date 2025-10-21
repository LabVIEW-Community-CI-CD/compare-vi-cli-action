#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$PlanOnly,
  [switch]$Force,
  [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Args')]
    [string[]]$GitArgs,
    [string]$RepoRoot
  )
  Push-Location $RepoRoot
  try {
    $output = & git @GitArgs 2>&1
    $exit = $LASTEXITCODE
    [pscustomobject]@{
      ExitCode = $exit
      Output   = if ($output -is [System.Array]) { @($output) } elseif ($null -eq $output) { @() } else { @($output) }
    }
  } finally {
    Pop-Location
  }
}

function Get-GitSingleLine {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Args')]
    [string[]]$GitArgs,
    [string]$RepoRoot
  )
  $result = Invoke-Git -GitArgs $GitArgs -RepoRoot $RepoRoot
  if ($result.ExitCode -ne 0) { return $null }
  ($result.Output -join "`n").Trim()
}

function Get-RepoRoot {
  param([string]$RepositoryRoot)
  if ($RepositoryRoot) {
    return (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
  }
  $result = & git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $result) {
    throw 'Not inside a git repository.'
  }
  return $result.Trim()
}

function Should-SkipPath {
  param([string]$Path)
  $patterns = @(
    '^tests/results/',
    '^tests\\results\\',
    '^tmp/',
    '^tmp\\',
    '^\.tmp/',
    '^tests/results/_agent/wip/'
  )
  foreach ($pattern in $patterns) {
    if ($Path -match $pattern) { return $true }
  }
  return $false
}

function Get-DirtyEntries {
  param([string]$RepoRoot)
  $status = Invoke-Git -RepoRoot $RepoRoot -GitArgs @('status','--porcelain=1')
  if ($status.ExitCode -ne 0) { return @() }
  $entries = @()
  foreach ($line in ($status.Output | Where-Object { $_ })) {
    $code = $line.Substring(0,2)
    $path = $line.Substring(3).Trim()
    if (Should-SkipPath -Path $path) { continue }
    $entries += [pscustomobject]@{
      Status = $code.Trim()
      Path   = $path
    }
  }
  return $entries
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

$repoRoot = Get-RepoRoot -RepositoryRoot $RepositoryRoot
$analysis = [ordered]@{
  repoRoot  = $repoRoot
  generated = (Get-Date).ToString('o')
  dirtyFiles = @()
  aheadCount = 0
  reasons    = @()
  commitPlan = $null
  postCommit = $null
  summary    = $null
}

$dirty = @((Get-DirtyEntries -RepoRoot $repoRoot))
if (@($dirty).Count -gt 0) {
  $analysis.dirtyFiles = $dirty
  $analysis.reasons += 'working-tree-dirty'
}

$ahead = Invoke-Git -RepoRoot $repoRoot -GitArgs @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
if ($ahead.ExitCode -eq 0 -and $ahead.Output) {
  $aheadCount = Invoke-Git -RepoRoot $repoRoot -GitArgs @('rev-list','@{u}..HEAD','--count')
  if ($aheadCount.ExitCode -eq 0) {
    $countValue = 0
    [int]::TryParse(($aheadCount.Output -join '').Trim(), [ref]$countValue) | Out-Null
    $analysis.aheadCount = $countValue
    if ($countValue -gt 0) {
      $analysis.reasons += 'local-commits-pending-push'
    }
  }
}

$commitPlanPath = Join-Path $repoRoot 'tests/results/_agent/commit-plan.json'
$commitPlan = Read-JsonFile -Path $commitPlanPath
if ($commitPlan) {
  $analysis.commitPlan = $commitPlan
  if ($commitPlan.autoCommitted -ne $true) {
    $analysis.reasons += 'commit-not-created'
  }
  if ($commitPlan.commitMessageStatus -and $commitPlan.commitMessageStatus.needsEdit) {
    $analysis.reasons += 'commit-message-review-needed'
  }
  if ($commitPlan.tests -and $commitPlan.tests.decision -eq 'required') {
    $analysis.reasons += 'tests-required-before-push'
  }
  if ($commitPlan.staged -and @($commitPlan.staged).Count -gt 0 -and $commitPlan.autoCommitted -ne $true) {
    $analysis.reasons += 'staged-files-pending'
  }
} else {
  if (@($dirty).Count -gt 0) {
    $analysis.reasons += 'commit-plan-missing'
  }
}

$postCommitPath = Join-Path $repoRoot 'tests/results/_agent/post-commit.json'
$postCommit = Read-JsonFile -Path $postCommitPath
if ($postCommit) {
  $analysis.postCommit = $postCommit
  if ($postCommit.pushFollowup -and $postCommit.pushFollowup.action -eq 'review') {
    $analysis.reasons += 'push-followup-review'
  }
  if ($postCommit.prFollowup -and $postCommit.prFollowup.action -eq 'review') {
    $analysis.reasons += 'pr-followup-review'
  }
  if ($postCommit.issue -and (-not $postCommit.issueClosed)) {
    $analysis.reasons += 'issue-not-closed'
  }
} else {
  if (@($analysis.reasons).Count -gt 0 -or $analysis.aheadCount -gt 0) {
    $analysis.reasons += 'post-commit-summary-missing'
  }
}

$shouldRun = $Force -or (@($analysis.reasons | Select-Object -Unique)).Count -gt 0
$analysis.summary = [ordered]@{
  shouldRun = [bool]$shouldRun
  force     = [bool]$Force
  planOnly  = [bool]$PlanOnly
}

$resultPath = Join-Path $repoRoot 'tests/results/_agent/standing-workflow.json'
if (-not (Test-Path -LiteralPath (Split-Path -Parent $resultPath))) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force | Out-Null
}
$analysis | ConvertTo-Json -Depth 10 | Out-File -FilePath $resultPath -Encoding utf8

if (-not $shouldRun) {
  Write-Host '[standing] Workflow not required; reasons were not detected.' -ForegroundColor Green
  if (@($analysis.dirtyFiles).Count -eq 0 -and $analysis.aheadCount -eq 0) {
    Write-Host '[standing] Working tree is clean and branch is up to date.' -ForegroundColor Gray
  }
  $global:LASTEXITCODE = 0
  return
}

Write-Host '[standing] Standing-priority workflow recommended.' -ForegroundColor Yellow
Write-Host ("[standing] Reasons: {0}" -f ((@($analysis.reasons | Select-Object -Unique)) -join ', ')) -ForegroundColor Yellow

if ($PlanOnly) {
  Write-Host '[standing] Plan-only mode active; not executing Run-LocalBackbone.' -ForegroundColor Cyan
  $global:LASTEXITCODE = 0
  return
}

$runScript = Join-Path $repoRoot 'tools' 'Run-LocalBackbone.ps1'
if (-not (Test-Path -LiteralPath $runScript)) {
  throw "Run-LocalBackbone.ps1 not found at $runScript."
}

Write-Host '[standing] Invoking standing-priority workflow...' -ForegroundColor Cyan

& pwsh '-NoLogo' '-NoProfile' '-File' $runScript
$exit = $LASTEXITCODE
if ($exit -ne 0) {
  throw "Standing workflow failed with exit code $exit."
}

Write-Host '[standing] Standing-priority workflow completed.' -ForegroundColor Green
$global:LASTEXITCODE = 0
