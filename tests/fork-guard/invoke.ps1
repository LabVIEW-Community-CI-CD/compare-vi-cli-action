#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Simulates fetching a pull request head for workflows that use the fork
  checkout helper. Intended for CI smoke to ensure helper keeps working.
#>

param(
    [Parameter(Mandatory)]
    [string]$WorkflowPath,

    [int]$PullNumber = 987
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    throw "Workflow not found: $WorkflowPath"
}

$headSha = git rev-parse HEAD
$refDir = ".git/refs/remotes/origin/pull/$PullNumber"
New-Item -ItemType Directory -Path $refDir -Force | Out-Null
Set-Content -LiteralPath "$refDir/head" -Value $headSha -Encoding ASCII

Write-Host "Created simulated ref pull/$PullNumber/head -> $headSha"
