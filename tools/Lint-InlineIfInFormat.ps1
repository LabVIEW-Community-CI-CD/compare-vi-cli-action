Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$fail = $false
$files = Get-ChildItem -Recurse -File -Include *.ps1,*.psm1,*.psd1,*.yml,*.yaml | Where-Object { -not ($_.FullName -match '\\node_modules\\') }
foreach ($f in $files) {
  $i = 0
  foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
    $i++
    $t = $line.Trim()
    if ($t -like '*-f*' -and ($t -match '\(\s*if\s*\(' -or $t -match ' -f \(\s*if\s*\(')) {
      Write-Host ("::error file={0},line={1}::Inline 'if' inside format (-f) is not allowed; precompute the value then pass to -f" -f $f.FullName,$i)
      Write-Host ("  >> {0}" -f $t)
      $fail = $true
    }
  }
}

if ($fail) { exit 2 } else { Write-Host 'Inline-if-in-format lint: OK' }

