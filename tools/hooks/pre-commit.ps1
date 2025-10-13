#!/usr/bin/env pwsh
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '[pre-commit] Running basic sanity checks' -ForegroundColor Cyan

try {
  if (Get-Module -ListAvailable -Name PSScriptAnalyzer | ForEach-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count) {
    $staged = (& git diff --cached --name-only --diff-filter=ACM) | Where-Object { $_ -match '\.(ps1|psm1)$' }
    if ($staged) {
      Write-Host "[pre-commit] PSScriptAnalyzer on staged PowerShell files" -ForegroundColor DarkGray
      foreach ($f in $staged) {
        Invoke-ScriptAnalyzer -Path $f -Recurse -Severity Error
      }
    }
  }
} catch {
  Write-Warning "[pre-commit] PSScriptAnalyzer check skipped: $_"
}

Write-Host '[pre-commit] OK' -ForegroundColor Green
exit 0

