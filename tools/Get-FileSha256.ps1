#Requires -Version 7.0
<#
.SYNOPSIS
  Compute the SHA-256 digest for a file.

.PARAMETER Path
  Path to the file to hash.

.PARAMETER AsBase64
  Emit the digest as a Base64 string instead of hexadecimal.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory, Position=0)]
  [string]$Path,

  [switch]$AsBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
  throw "File not found: $Path"
}

$fullPath = (Resolve-Path -LiteralPath $Path).Path
$stream = [System.IO.File]::OpenRead($fullPath)
try {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $hash = $sha.ComputeHash($stream)
} finally {
  $stream.Dispose()
  if ($sha) { $sha.Dispose() }
}

if ($AsBase64) {
  [Convert]::ToBase64String($hash)
} else {
  ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}
