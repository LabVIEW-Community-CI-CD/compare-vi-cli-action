Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fail = $false
$files = Get-ChildItem -Recurse -File -Include *.ps1,*.psm1,*.psd1,*.yml,*.yaml | Where-Object { -not ($_.FullName -match '\\node_modules\\') }
foreach ($f in $files) {
  if ($f.Name -eq 'Lint-InlineIfInFormat.ps1') { continue }
  $i = 0
  foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
    $i++
    $t = $line.Trim()
    if ($t -match '^#') { continue }
    # Detect the PowerShell format operator specifically: "..." -f ...
    # Flag only when immediately followed by a parenthesized inline 'if' without $() (problematic pattern): -f (if (...))
    if ($t -match '\-f\s*\((?!\$)\s*if\s*\(') {
      Write-Host ("::error file={0},line={1}::Inline 'if' directly after -f detected; precompute into a variable or use $()" -f $f.FullName,$i)
      Write-Host ("  >> {0}" -f $t)
      $fail = $true
    }
  }
}

if ($fail) { exit 2 } else { Write-Host 'Inline-if-in-format lint: OK' }
