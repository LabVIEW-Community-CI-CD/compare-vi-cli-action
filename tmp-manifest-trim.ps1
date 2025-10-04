$p = Resolve-Path -LiteralPath './fixtures.manifest.json'
$c = Get-Content -LiteralPath $p -Raw
# Trim trailing whitespace and blank lines
$trimmed = ($c -replace "[\r\n]+\z","`r`n").TrimEnd()
Set-Content -LiteralPath $p -Value $trimmed -Encoding UTF8
(Get-Content -LiteralPath $p -Raw) | Write-Output