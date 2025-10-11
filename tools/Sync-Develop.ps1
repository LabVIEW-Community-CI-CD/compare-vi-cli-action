#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Remote = 'origin',
  [string]$Branch = 'develop',
  [switch]$NoFastForward
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:SKIP_SYNC_DEVELOP -and $env:SKIP_SYNC_DEVELOP -notin @('0', 'false', 'False')) {
  Write-Host "SKIP_SYNC_DEVELOP is set; skipping fetch for $Remote/$Branch." -ForegroundColor Yellow
  return
}

$repoRoot = Split-Path -Parent $PSCommandPath
$git = Get-Command git -ErrorAction Stop

Push-Location $repoRoot
try {
  Write-Host "Fetching $Remote/$Branch..." -ForegroundColor Cyan
  & $git.Source 'fetch' $Remote $Branch
  if ($LASTEXITCODE -ne 0) {
    throw "git fetch $Remote $Branch failed with exit code $LASTEXITCODE."
  }

  if ($NoFastForward) {
    Write-Host "Fast-forward disabled (-NoFastForward); leaving local branches unchanged." -ForegroundColor DarkGray
    return
  }

  $currentBranch = (& $git.Source 'rev-parse' '--abbrev-ref' 'HEAD').Trim()
  if ($currentBranch -ne $Branch) {
    Write-Host "Current branch '$currentBranch' differs from '$Branch'; remote tracking is updated, local branch untouched." -ForegroundColor DarkGray
    return
  }

  Write-Host "Fast-forwarding $Branch to $Remote/$Branch (if possible)..." -ForegroundColor Cyan
  & $git.Source 'merge' '--ff-only' "$Remote/$Branch"
  if ($LASTEXITCODE -eq 0) {
    Write-Host "$Branch is up to date with $Remote/$Branch." -ForegroundColor Green
  } else {
    Write-Warning "Unable to fast-forward $Branch. Resolve manually if local commits are present."
  }
} finally {
  Pop-Location
}
