#Requires -Version 7.0
<#!
.SYNOPSIS
  Quick link check across Markdown files.
.DESCRIPTION
  Scans *.md for links and validates local relative targets exist. Optional -External checks http/https with HEAD.
.PARAMETER Path
  Root directory to scan (default: repo root).
.PARAMETER External
  Also check http/https links with a short timeout.
.PARAMETER Quiet
  Reduce output noise; still returns non-zero exit for failures.
#>
param(
  [string]$Path = '.',
  [switch]$External,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Resolve-Path -LiteralPath $Path
$md = Get-ChildItem -LiteralPath $root -Recurse -File -Include *.md -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch "\\\.git\\|\\node_modules\\|\\.venv\\|\\dist\\|\\build\\|\\coverage\\" }
$missing = @(); $badHttp = @()

function Write-Info($msg){ if (-not $Quiet) { Write-Host $msg -ForegroundColor DarkGray } }

foreach ($f in $md) {
  $text = Get-Content -LiteralPath $f.FullName -Raw
  # crude link extraction: [label](target)
  $matches = [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')
  foreach ($m in $matches) {
    $target = $m.Groups[1].Value.Trim()
    if ($target -match '^(mailto:|#)') { continue }
    if ($target -match '^(https?://)') {
      if (-not $External) { continue }
      try {
        $resp = Invoke-WebRequest -Method Head -Uri $target -TimeoutSec 5 -UseBasicParsing
        if (-not $resp.StatusCode -or $resp.StatusCode -ge 400) { $badHttp += [pscustomobject]@{ file=$f.FullName; link=$target; code=$resp.StatusCode } }
      } catch { $badHttp += [pscustomobject]@{ file=$f.FullName; link=$target; code='ERR' } }
      continue
    }
    # local/relative link
    $p = $target
    # strip anchors like file.md#section
    if ($p -match '^(.*?)(#.*)?$') { $p = $Matches[1] }
    if (-not $p) { continue }
    $candidate = Join-Path (Split-Path -Parent $f.FullName) $p
    if (-not (Test-Path -LiteralPath $candidate)) {
      $missing += [pscustomobject]@{ file=$f.FullName; link=$target }
    }
  }
}

if ($missing.Count -gt 0) {
  Write-Host "Broken local links: $($missing.Count)" -ForegroundColor Yellow
  $missing | ForEach-Object { Write-Host "- $($_.file): $($_.link)" }
}
if ($badHttp.Count -gt 0) {
  Write-Host "Unhealthy external links: $($badHttp.Count)" -ForegroundColor Yellow
  $badHttp | ForEach-Object { Write-Host "- $($_.file): $($_.link) [code=$($_.code)]" }
}

if ($missing.Count -gt 0 -or $badHttp.Count -gt 0) { exit 2 }
Write-Info 'All links look good.'
