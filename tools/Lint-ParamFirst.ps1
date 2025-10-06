Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
  [string]$Root = (Get-Location).Path,
  [switch]$WarnOnly
)

function Get-ScriptFiles {
  param([string]$Base)
  Get-ChildItem -Path $Base -Recurse -File -Include *.ps1,*.psm1 |
    Where-Object { $_.FullName -notlike '*\node_modules\*' -and $_.FullName -notlike '*\.git\*' }
}

function Test-ParamFirst {
  param([string]$Path)
  $lines = Get-Content -LiteralPath $Path -ErrorAction Stop
  $inBlock = $false
  $firstIdx = $null
  $paramIdx = $null
  for ($i=0; $i -lt $lines.Count; $i++) {
    $raw = $lines[$i]
    $t = $raw.Trim()
    if (-not $inBlock) {
      if ($t -match '^<#') {
        $inBlock = $true
        if ($t -match '#>') { $inBlock = $false }
        continue
      }
      if ($t -eq '') { continue }
      if ($t -match '^(#|#requires\b)') { continue }
      if ($t -match '^(using\s+)') { continue }
      if (-not $firstIdx) { $firstIdx = $i }
      if ($t -match '^param\(') { $paramIdx = $i; break } else { break }
    } else {
      if ($t -match '#>') { $inBlock = $false }
    }
  }
  # If no param anywhere, it's fine
  if (-not ($lines -match '^param\(')) { return $true }
  # If first non-ignored line is param, OK
  if ($firstIdx -ne $null -and $lines[$firstIdx].Trim() -match '^param\(') { return $true }
  return $false
}

$violations = @()
foreach ($f in (Get-ScriptFiles -Base $Root)) {
  try {
    if (-not (Test-ParamFirst -Path $f.FullName)) { $violations += $f.FullName }
  } catch {
    Write-Host "::warning::param-first linter skipped: $($f.FullName): $_"
  }
}

if ($violations.Count -gt 0) {
  Write-Host 'Param-first linter: violations found:' -ForegroundColor Red
  foreach ($v in ($violations | Sort-Object)) { Write-Host (" - {0}" -f $v) -ForegroundColor Red }
  if (-not $WarnOnly) { exit 2 }
  else { exit 0 }
} else {
  Write-Host 'Param-first linter: OK' -ForegroundColor Green
}

