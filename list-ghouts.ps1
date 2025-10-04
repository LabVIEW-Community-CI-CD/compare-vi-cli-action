$tmp = Join-Path ([IO.Path]::GetTempPath()) 'compare-vi-loop'
Write-Host "TempDir=$tmp"
if (Test-Path $tmp) {
  Get-ChildItem -Path $tmp -File | ForEach-Object {
    Write-Host ("FILE: " + $_.FullName)
    try { Get-Content -LiteralPath $_.FullName -Encoding utf8 | ForEach-Object { '  '+$_ } } catch { Write-Warning $_ }
  }
} else { Write-Host 'No temp dir present.' }