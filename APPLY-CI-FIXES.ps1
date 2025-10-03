#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Apply CI stabilization fixes from copilot branch to release/v0.4.0-rc.1

.DESCRIPTION
    This script cherry-picks the test stabilization fixes to the release branch.
    Run this from the repository root after reviewing the CI-FIX-SUMMARY.md.

.EXAMPLE
    pwsh -File APPLY-CI-FIXES.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "=== Applying CI Stabilization Fixes to release/v0.4.0-rc.1 ===" -ForegroundColor Cyan

# Verify we're in a git repo
if (-not (Test-Path .git)) {
    Write-Error "Not in a git repository root. Run this from the repo root."
}

# Check current branch
$currentBranch = git rev-parse --abbrev-ref HEAD
Write-Host "Current branch: $currentBranch" -ForegroundColor Yellow

# Fetch latest
Write-Host "Fetching latest changes..." -ForegroundColor Cyan
git fetch origin

# Checkout release branch
Write-Host "Checking out release/v0.4.0-rc.1..." -ForegroundColor Cyan
git checkout release/v0.4.0-rc.1

# Pull latest
Write-Host "Pulling latest release branch..." -ForegroundColor Cyan
git pull origin release/v0.4.0-rc.1

# Cherry-pick the fix commit (not the planning commit, not the summary doc commit)
$fixCommit = "f00653f"  # The actual test fix commit
Write-Host "Cherry-picking fix commit $fixCommit..." -ForegroundColor Cyan
Write-Host "(Schema version, performance thresholds, cross-platform paths)" -ForegroundColor Gray

try {
    git cherry-pick $fixCommit
    Write-Host "✅ Fix applied successfully!" -ForegroundColor Green
    
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "1. Review changes: git show HEAD" -ForegroundColor Gray
    Write-Host "2. Run tests: pwsh -File ./Invoke-PesterTests.ps1" -ForegroundColor Gray
    Write-Host "3. Push to origin: git push origin release/v0.4.0-rc.1" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Expected test results: 117 passed, 0 failed" -ForegroundColor Green
    
} catch {
    Write-Host "❌ Cherry-pick failed. This might happen if:" -ForegroundColor Red
    Write-Host "  - The fixes were already applied" -ForegroundColor Yellow
    Write-Host "  - There are merge conflicts" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To resolve:" -ForegroundColor Yellow
    Write-Host "  1. Review conflict: git status" -ForegroundColor Gray
    Write-Host "  2. Fix conflicts manually" -ForegroundColor Gray
    Write-Host "  3. Continue: git cherry-pick --continue" -ForegroundColor Gray
    Write-Host "  OR abort: git cherry-pick --abort" -ForegroundColor Gray
    exit 1
}
