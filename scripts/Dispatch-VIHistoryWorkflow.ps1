param(
  [Parameter(Mandatory = $true)]
  [string]$ViPath,
  [string]$CompareRef = '',
  [int]$CompareDepth = 10,
  [switch]$FailFast,
  [switch]$FailOnDiff,
  [string]$Modes = 'default',
  [string]$IgnoreFlags = 'none',
  [string]$NotifyIssue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$arguments = @(
  'workflow', 'run', 'vi-compare-refs.yml',
  '-f', "vi_path=$ViPath",
  '-f', "compare_depth=$CompareDepth",
  '-f', "compare_modes=$Modes",
  '-f', "compare_ignore_flags=$IgnoreFlags"
)

if (-not [string]::IsNullOrWhiteSpace($CompareRef)) {
  $arguments += @('-f', "compare_ref=$CompareRef")
}
if ($FailFast.IsPresent) {
  $arguments += @('-f', 'compare_fail_fast=true')
}
if ($FailOnDiff.IsPresent) {
  $arguments += @('-f', 'compare_fail_on_diff=true')
}
if (-not [string]::IsNullOrWhiteSpace($NotifyIssue)) {
  $arguments += @('-f', "notify_issue=$NotifyIssue")
}

Write-Host "gh $($arguments -join ' ')"
$runDispatch = gh @arguments
Write-Host $runDispatch

if ($LASTEXITCODE -ne 0) { return }

try {
  $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
} catch {
  $branch = ''
}

$runListArgs = @('run','list','--workflow','vi-compare-refs.yml','--limit','1','--json','databaseId,url,headBranch,status,createdAt,displayTitle')
if ($branch) { $runListArgs += @('--branch', $branch) }

function Write-TrackingHint {
  Write-Host 'Workflow dispatched; use "gh run list --workflow vi-compare-refs.yml" to track progress.' -ForegroundColor Yellow
}

try {
  $runJson = gh @runListArgs 2>$null
  if ($runJson) {
    $runInfo = $runJson | ConvertFrom-Json
    if ($runInfo.Count -gt 0) {
      $run = $runInfo[0]
      Write-Host "Latest run for branch '$($run.headBranch)': $($run.url)" -ForegroundColor Cyan
    } else {
      Write-TrackingHint
    }
  } else {
    Write-TrackingHint
  }
} catch {
  Write-TrackingHint
}
