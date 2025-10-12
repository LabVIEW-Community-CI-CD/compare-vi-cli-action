#Requires -Version 7.0
<#
.SYNOPSIS
  Produce a deterministic phase variables manifest for downstream jobs.
.DESCRIPTION
  Captures curated environment details (e.g., LVCompare path, deterministic toggles)
  and writes `tests/results/_phase/vars.json` with a digest that consumers must validate.
.PARAMETER OutputPath
  Destination for the manifest. Defaults to tests/results/_phase/vars.json.
#>
[CmdletBinding()]
param(
  [string]$OutputPath = 'tests/results/_phase/vars.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256 {
  param([string]$Input)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Input)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  } finally {
    $sha.Dispose()
  }
}

$outputFile = Resolve-Path -LiteralPath (Split-Path -Parent $PWD) -ErrorAction SilentlyContinue | Out-Null
$resolvedPath = $OutputPath
$dir = Split-Path -Parent $resolvedPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$vendorTools = Join-Path $PSScriptRoot 'VendorTools.psm1'
if (Test-Path -LiteralPath $vendorTools) {
  Import-Module $vendorTools -Force
}

$vars = [ordered]@{}

try {
  if (Get-Command Resolve-LVComparePath -ErrorAction SilentlyContinue) {
    $lvCompare = Resolve-LVComparePath
    $vars.LVComparePath = $lvCompare
  }
} catch {
  throw "Failed to resolve LVCompare path: $($_.Exception.Message)"
}

if ($env:DETERMINISTIC) { $vars.DETERMINISTIC = $env:DETERMINISTIC }
if ($env:INVOCATION_ID) { $vars.InvocationId = $env:INVOCATION_ID }

$metadata = [ordered]@{
  version     = 1
  schema      = 'phase-vars/v1'
  producedAt  = (Get-Date).ToString('o')
  producedBy  = [ordered]@{
    workflow = $env:GITHUB_WORKFLOW
    job      = $env:GITHUB_JOB
    runId    = $env:GITHUB_RUN_ID
    runAttempt = $env:GITHUB_RUN_ATTEMPT
  }
  variables   = $vars
}

$varsJson = ($vars | ConvertTo-Json -Depth 5 -Compress)
$metadata.digest = [ordered]@{
  algorithm = 'sha256'
  value     = Get-Sha256 -Input $varsJson
  source    = 'variables'
}

$metadata | ConvertTo-Json -Depth 10 | Out-File -FilePath $resolvedPath -Encoding utf8
Write-Host ("Phase vars written to {0}" -f (Resolve-Path -LiteralPath $resolvedPath -ErrorAction SilentlyContinue))
