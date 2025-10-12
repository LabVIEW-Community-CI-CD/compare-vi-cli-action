#!/usr/bin/env pwsh
param([string]$CommitMsgPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $CommitMsgPath -PathType Leaf)) { exit 0 }
$raw = Get-Content -LiteralPath $CommitMsgPath -Encoding utf8 -Raw
if ([string]::IsNullOrEmpty($raw)) { exit 0 }

$normalized = ($raw -replace "`r", '')
$subject = $normalized.Split("`n", [System.StringSplitOptions]::None)[0]
$subject = [string]$subject
$subject = $subject.TrimEnd()

if ([string]::IsNullOrWhiteSpace($subject)) { exit 0 }

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
