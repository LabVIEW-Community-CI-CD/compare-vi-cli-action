<#!
.SYNOPSIS
  Enumerate historical blob sizes for VI fixtures to identify largest valid versions.
.DESCRIPTION
  Traverses commit history affecting each specified VI file (default VI1.vi, VI2.vi) and prints
  a sorted table (descending) of unique blob sizes with associated commit and blob SHA.
  Use output to decide which historical versions to restore if current binaries are truncated.
.PARAMETER Path
  One or more VI paths (relative to repo root) to analyze. Defaults to VI1.vi, VI2.vi.
#>
param(
  [string[]]$Path = @('VI1.vi','VI2.vi'),
  [int]$MaxCommits = 200
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ViHistorySizes([string]$file,[int]$limit){
  $logOutput = git log --format='%H' -- $file 2>$null
  if (-not $logOutput) { return @() }
  $commits = $logOutput | Select-Object -First $limit
  $seenBlobs = [System.Collections.Generic.HashSet[string]]::new()
  $rows = @()
  foreach ($c in $commits) {
    $ls = git ls-tree $c -- $file 2>$null
    if (-not $ls) { continue }
    # Format: 100644 blob <blobsha>\t<path>
    $parts = $ls -split "\s+"
    if ($parts.Length -lt 4) { continue }
    $blob = $parts[2]
    if (-not $seenBlobs.Add($blob)) { continue }
    $tmp = New-TemporaryFile
  git show "$c`:$file" > $tmp
    $len = (Get-Item -LiteralPath $tmp).Length
    Remove-Item -LiteralPath $tmp -Force
    $rows += [pscustomobject]@{ File=$file; Size=$len; Commit=$c; Blob=$blob }
  }
  $rows | Sort-Object Size -Descending
}

$all = @()
foreach($p in $Path){ $all += Get-ViHistorySizes -file $p -limit $MaxCommits }
if (-not $all) { Write-Warning 'No history data collected.'; return }

$all | Sort-Object File,Size -Descending | Format-Table -AutoSize

# Emit concise JSON for automation
$json = $all | Sort-Object File,Size -Descending | ConvertTo-Json -Depth 4
Set-Content -Path 'vi-history-sizes.json' -Value $json -Encoding utf8
Write-Host "History written to vi-history-sizes.json"