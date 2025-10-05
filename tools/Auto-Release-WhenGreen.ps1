#Requires -Version 7.0
<#!
.SYNOPSIS
  Polls GitHub Actions for a green Pester run on the RC branch and, when green, merges to main and tags vX.Y.Z.

.PARAMETER RcBranch
  The release candidate branch to watch (default: release/v0.5.0-rc.1).

.PARAMETER WorkflowFile
  The workflow filename to monitor (default: test-pester.yml).

.PARAMETER TargetBranch
  The target branch to merge into (default: main).

.PARAMETER Tag
  The tag to create on success (default: v0.5.0).

.PARAMETER PollSeconds
  Seconds between polls (default: 20).

.PARAMETER TimeoutMinutes
  Max time to wait before exiting non-zero (default: 60).
#>
param(
  [string]$RcBranch = 'release/v0.5.0-rc.1',
  [string]$WorkflowFile = 'test-pester.yml',
  [string]$TargetBranch = 'main',
  [string]$Tag = 'v0.5.0',
  [int]$PollSeconds = 10,
  [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-LatestRun($repo, $workflowFile, $branch){
  $url = "https://api.github.com/repos/$repo/actions/workflows/$workflowFile/runs?branch=$([uri]::EscapeDataString($branch))&per_page=1"
  try {
    $res = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 15
    $j = $res.Content | ConvertFrom-Json
    return $j.workflow_runs | Select-Object -First 1
  } catch {
    return $null
  }
}

function Write-Info($msg){ Write-Host ("[auto-release] {0}" -f $msg) -ForegroundColor DarkGray }

$repo = $env:GITHUB_REPOSITORY
if ([string]::IsNullOrWhiteSpace($repo)) {
  # Derive from git remote
  $origin = git remote get-url origin
  if ($origin -match 'github.com[:/](.+?/.+?)(?:\.git)?$') { $repo = $Matches[1] }
}
if (-not $repo) { throw 'Could not resolve repository (set GITHUB_REPOSITORY or configure git remote origin)' }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
Write-Info "Watching '$WorkflowFile' on '$RcBranch' until green or $TimeoutMinutes min timeout (poll ${PollSeconds}s)..."

while($true){
  if ((Get-Date) -gt $deadline) { Write-Host 'Timeout waiting for green Pester run.'; exit 3 }
  $run = Get-LatestRun -repo $repo -workflowFile $WorkflowFile -branch $RcBranch
  if (-not $run) { Start-Sleep -Seconds $PollSeconds; continue }
  Write-Info ("Status={0} Conclusion={1} URL={2}" -f $run.status,$run.conclusion,$run.html_url)
  if ($run.status -eq 'completed' -and $run.conclusion -eq 'success') { break }
  Start-Sleep -Seconds $PollSeconds
}

Write-Info 'Pester is green. Proceeding to merge and tag.'

git fetch origin $TargetBranch $RcBranch
git checkout $TargetBranch
git pull --ff-only origin $TargetBranch
git merge --no-ff $RcBranch -m "Release $Tag"
git push origin $TargetBranch

# Tag and push
git tag -a $Tag -m "Release $Tag"
git push origin $Tag

Write-Host "Done: merged $RcBranch -> $TargetBranch and tagged $Tag" -ForegroundColor Green
