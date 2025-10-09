param(
  [string]$RequirementsDir = 'docs/requirements',
  [string]$AdrDir = 'docs/adr'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path '.').Path
$reqPath = if ([IO.Path]::IsPathRooted($RequirementsDir)) { $RequirementsDir } else { Join-Path $root $RequirementsDir }
$adrPath = if ([IO.Path]::IsPathRooted($AdrDir)) { $AdrDir } else { Join-Path $root $AdrDir }

if (-not (Test-Path -LiteralPath $reqPath -PathType Container)) {
  Write-Error "Requirements directory not found: $reqPath"
  exit 1
}
if (-not (Test-Path -LiteralPath $adrPath -PathType Container)) {
  Write-Error "ADR directory not found: $adrPath"
  exit 1
}

$adrFiles = Get-ChildItem -LiteralPath $adrPath -File -Filter '*.md' -ErrorAction Stop
$adrNames = $adrFiles | ForEach-Object { $_.Name }

$requirements = Get-ChildItem -LiteralPath $reqPath -File -Filter '*.md' -Recurse -ErrorAction Stop
$errors = New-Object System.Collections.Generic.List[string]

foreach ($req in $requirements) {
  $content = Get-Content -LiteralPath $req.FullName -Raw
  if ($content -notmatch '##\s*Traceability') {
    continue
  }
  $matches = [regex]::Matches($content, '\.\./adr/(?<file>[0-9A-Za-z\-_]+\.md)')
  if ($matches.Count -eq 0) {
    $errors.Add("Requirement missing ADR reference: $($req.FullName)") | Out-Null
    continue
  }
  foreach ($match in $matches) {
    $file = $match.Groups['file'].Value
    if ($adrNames -notcontains $file) {
      $errors.Add("Requirement references missing ADR '$file' in $($req.FullName)") | Out-Null
    }
  }
}

if ($errors.Count -gt 0) {
  Write-Host 'ADR link validation failed:' -ForegroundColor Red
  $errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  exit 1
}

Write-Host 'ADR link validation passed.' -ForegroundColor Green
exit 0
