param(
  [string]$Group = 'pester-selfhosted',
  [string]$ResultsRoot = (Join-Path (Resolve-Path '.').Path 'tests/results'),
  [string]$OutputRoot = (Join-Path (Resolve-Path '.').Path 'tests/results/dev-dashboard'),
  [switch]$JsonOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutputRoot)) {
  New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
}

$cliPath = Join-Path (Split-Path -Parent $PSCommandPath) 'Dev-Dashboard.ps1'
$htmlPath = Join-Path $OutputRoot 'dashboard.html'
$jsonPath = Join-Path $OutputRoot 'dashboard.json'

$argsHashtable = @{
  Group        = $Group
  ResultsRoot  = $ResultsRoot
  Quiet        = $true
  Json         = $true
}
if (-not $JsonOnly) {
  $argsHashtable['Html'] = $true
  $argsHashtable['HtmlPath'] = $htmlPath
}

$json = & $cliPath @argsHashtable
$json | Out-File -FilePath $jsonPath -Encoding utf8

if ($JsonOnly) {
  Write-Host "Dashboard JSON saved to $jsonPath"
} else {
  Write-Host "Dashboard HTML saved to $htmlPath"
  Write-Host "Dashboard JSON saved to $jsonPath"
}
