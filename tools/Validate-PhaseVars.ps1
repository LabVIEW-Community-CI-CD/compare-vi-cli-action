#Requires -Version 7.0
<#
.SYNOPSIS
  Validate a phase variables manifest and return the parsed object.
.PARAMETER Path
  Manifest path (defaults to tests/results/_phase/vars.json).
.PARAMETER RequireSchema
  Optional schema identifier to enforce (default: phase-vars/v1).
.PARAMETER Strict
  When set, throws if validation fails; otherwise emits warnings.
#>
[CmdletBinding()]
param(
  [string]$Path = 'tests/results/_phase/vars.json',
  [string]$RequireSchema = 'phase-vars/v1',
  [switch]$Strict
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

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  $msg = "Phase vars file not found: $Path"
  if ($Strict) { throw $msg } else { Write-Warning $msg; return $null }
}

try {
  $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  $doc = $content | ConvertFrom-Json -ErrorAction Stop
} catch {
  $msg = "Failed to parse phase vars JSON at $Path: $($_.Exception.Message)"
  if ($Strict) { throw $msg } else { Write-Warning $msg; return $null }
}

if ($RequireSchema -and ($doc.schema -ne $RequireSchema)) {
  $msg = "Unexpected phase vars schema. Expected '$RequireSchema', found '$($doc.schema)'"
  if ($Strict) { throw $msg } else { Write-Warning $msg; return $doc }
}

if (-not $doc.variables) {
  $msg = "Phase vars document missing 'variables' block."
  if ($Strict) { throw $msg } else { Write-Warning $msg }
}

$computed = Get-Sha256 -Input (($doc.variables | ConvertTo-Json -Depth 5 -Compress) ?? '')
if (-not $doc.digest.value -or $doc.digest.value -ne $computed) {
  $msg = "Phase vars digest mismatch (expected $($doc.digest.value); computed $computed)."
  if ($Strict) { throw $msg } else { Write-Warning $msg }
}

return $doc
