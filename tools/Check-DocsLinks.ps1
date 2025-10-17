#Requires -Version 7.0
<#!
.SYNOPSIS
  Quick link check across Markdown files.
.DESCRIPTION
  Scans *.md for links and validates local relative targets exist. Optional HTTP HEAD checks for external links.
.PARAMETER Path
  Root directory to scan (default: repo root).
.PARAMETER External
  Also check http/https links with a short timeout. (Alias for -Http)
.PARAMETER Http
  Also check http/https links with a short timeout.
.PARAMETER HttpTimeoutSec
  Timeout seconds for HTTP HEAD checks (default: 5).
.PARAMETER Ignore
  Glob patterns to ignore (e.g., node_modules/**, bin/**).
.PARAMETER AllowListPath
  Optional allowlist file for links to ignore, one per line (default: .ci/link-allowlist.txt).
.PARAMETER OutputJson
  Optional path to write a JSON report.
.PARAMETER Quiet
  Reduce output noise; still returns non-zero exit for failures.
#>
param(
  [string]$Path = '.',
  [switch]$External,
  [switch]$Http,
  [object]$HttpTimeoutSec = 5,
  [string[]]$Ignore,
  [string]$AllowListPath = '.ci/link-allowlist.txt',
  [string]$OutputJson,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$httpTimeoutInput = $HttpTimeoutSec
if ($httpTimeoutInput -is [System.Array] -and $httpTimeoutInput.Length -gt 0) {
  # Accept first value when callers accidentally pass multiple entries (e.g., via native command arg flattening)
  $httpTimeoutInput = $httpTimeoutInput[0]
}

if ($null -eq $httpTimeoutInput -or ($httpTimeoutInput -is [string] -and [string]::IsNullOrWhiteSpace($httpTimeoutInput))) {
  $HttpTimeoutSec = 5
} elseif ($httpTimeoutInput -is [int]) {
  $HttpTimeoutSec = $httpTimeoutInput
} else {
  $timeoutText = $httpTimeoutInput.ToString().Trim()
  $parsedTimeout = 0
  if (-not [int]::TryParse($timeoutText, [ref]$parsedTimeout)) {
    throw "HttpTimeoutSec expects an integer number of seconds. Received '$timeoutText'."
  }
  $HttpTimeoutSec = $parsedTimeout
}

function Match-Any($value,[string[]]$patterns){
  if (-not $patterns -or $patterns.Count -eq 0) { return $false }
  # Normalize to forward slashes for cross-OS matching
  $norm = ($value -replace '\\','/')
  foreach ($pat in $patterns) {
    if (-not $pat) { continue }
    $p = ($pat -replace '\\','/')
    # Treat consecutive wildcards as single and ensure loose matching
    $p = ($p -replace '\*{2,}','*')
    if ($p -notmatch '^\*') { $p = "*$p" }
    if ($p -notmatch '\*$') { $p = "$p*" }
    if ($norm -like $p) { return $true }
  }
  return $false
}
function Write-Info($msg){ if (-not $Quiet) { Write-Host $msg -ForegroundColor DarkGray } }

$checkHttp = $External -or $Http
$root = Resolve-Path -LiteralPath $Path
$skipPattern = '(?:[\\/]\.git[\\/]|[\\/]node_modules[\\/]|[\\/]\.venv[\\/]|[\\/]dist[\\/]|[\\/]build[\\/]|[\\/]coverage[\\/])'
$md = Get-ChildItem -LiteralPath $root -Recurse -File -Include *.md -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch $skipPattern }
$autoIgnore = @(
  '*/bin/*','*\\bin\\*',
  '*/vendor/*','*\\vendor\\*',
  '*/node_modules/*','*\\node_modules\\*'
)
$md = $md | Where-Object { $p = $_.FullName; -not (Match-Any $p $autoIgnore) }
if ($Ignore) {
  $md = $md | Where-Object { $p = $_.FullName; -not (Match-Any $p $Ignore) }
}

$allow = @()
if ($AllowListPath -and (Test-Path -LiteralPath $AllowListPath -PathType Leaf)) {
  $allow = Get-Content -LiteralPath $AllowListPath -ErrorAction SilentlyContinue | Where-Object { $_ -and -not ($_.Trim().StartsWith('#')) } | ForEach-Object { $_.Trim() }
}

$missing = @(); $badHttp = @()

foreach ($f in $md) {
  $text = Get-Content -LiteralPath $f.FullName -Raw
  # crude link extraction: [label](target)
  $matches = [regex]::Matches($text, '\[[^\]]+\]\(([^)]+)\)')
  foreach ($m in $matches) {
    $target = $m.Groups[1].Value.Trim()
    if ($target -match '^(mailto:|#)') { continue }
    if ($target -match '^(https?://)') {
      if (-not $checkHttp) { continue }
      try {
        $req = [System.Net.HttpWebRequest]::Create($target)
        $req.Method = 'HEAD'
        $req.Timeout = 1000 * [Math]::Max(1,$HttpTimeoutSec)
        $resp = $req.GetResponse(); $code = 200
        try { $code = $resp.StatusCode.Value__ } catch {}
        $resp.Close()
        if ($code -ge 400) { $badHttp += [pscustomobject]@{ file=$f.FullName; link=$target; code=$code } }
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
      if (-not (Match-Any $candidate $allow)) {
        $missing += [pscustomobject]@{ file=$f.FullName; link=$target }
      }
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

if ($OutputJson) {
  $out = [ordered]@{ schema='docs-links/v1'; generatedAtUtc=(Get-Date).ToUniversalTime().ToString('o'); errors=@{ local=$missing; http=$badHttp } }
  $dir = Split-Path -Parent $OutputJson
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $out | ConvertTo-Json -Depth 6 | Out-File -FilePath $OutputJson -Encoding utf8
}

if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @('### Docs Links','',"Local errors: $($missing.Count)","HTTP errors: $($badHttp.Count)")
  ($missing | Select-Object -First 5) | ForEach-Object { $lines += ('- ' + $_.file + ' -> ' + $_.link) }
  ($badHttp | Select-Object -First 5) | ForEach-Object { $lines += ('- ' + $_.file + ' -> ' + $_.link + ' (HTTP)') }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($missing.Count -gt 0 -or $badHttp.Count -gt 0) { exit 2 }
Write-Info 'All links look good.'
