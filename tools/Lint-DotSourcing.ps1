Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
  [string]$Root = (Get-Location).Path,
  [switch]$WarnOnly
)

function Get-RepoFiles {
  param([string]$Base)
  Get-ChildItem -Path $Base -Recurse -File -Include *.ps1,*.psm1 | Where-Object {
    $_.FullName -notlike "*node_modules*" -and $_.FullName -notlike "*.git*"
  }
}

$issues = @()
foreach ($f in (Get-RepoFiles -Base $Root)) {
  $i = 0
  Get-Content -LiteralPath $f.FullName | ForEach-Object {
    $i++
    $line = $_
    $trim = $line.Trim()
    if ($trim -match '^#') { return }
    if ($trim -match '^\.(\s+)(.+)$') {
      $rhs = $Matches[2]
      # Allow explicit anchored patterns using Join-Path or Resolve-Path
      if ($rhs -notmatch '(?i:Join-Path|Resolve-Path)') {
        $issues += [pscustomobject]@{ file=$f.FullName; line=$i; text=$line }
      }
    }
  }
}

if ($issues.Count -gt 0) {
  Write-Host 'Unanchored dot-sourcing detected:' -ForegroundColor Red
  foreach ($i in $issues) { Write-Host (" - {0}:{1}: {2}" -f $i.file,$i.line,$i.text.Trim()) -ForegroundColor Red }
  if (-not $WarnOnly) { exit 2 }
  else { exit 0 }
} else {
  Write-Host 'Dot-sourcing lint passed (no unanchored dot-sourcing found).' -ForegroundColor Green
}

