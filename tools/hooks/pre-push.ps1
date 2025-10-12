#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '[pre-push] Running PrePush-Checks.ps1' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot '..' 'PrePush-Checks.ps1')
if ($LASTEXITCODE -ne 0) {
  Write-Error "PrePush checks failed (exit=$LASTEXITCODE). Aborting push."
  exit $LASTEXITCODE
}
Write-Host '[pre-push] OK' -ForegroundColor Green
exit 0

