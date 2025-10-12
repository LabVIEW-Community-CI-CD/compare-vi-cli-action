#!/usr/bin/env pwsh
param([string]$CommitMsgPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CommitMsgPath -PathType Leaf)) { exit 0 }
$lines = Get-Content -LiteralPath $CommitMsgPath -Encoding utf8
if (-not $lines) { exit 0 }
$subject = $lines[0]

if ($subject -match '^\s*WIP\b') { exit 0 }

if ($subject.Length -gt 100) {
  Write-Error "commit-msg: subject too long ($($subject.Length) > 100)"
  exit 1
}

if ($subject -notmatch '\(#\d+\)') {
  Write-Error "commit-msg: subject must include issue reference e.g. '(#88)'"
  exit 1
}

exit 0

