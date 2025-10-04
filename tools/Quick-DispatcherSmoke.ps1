#Requires -Version 7.0
<#
.SYNOPSIS
  Quick local smoke test for Invoke-PesterTests.ps1.

.DESCRIPTION
  Creates a temporary tests folder with a tiny passing test, runs the dispatcher,
  prints the JSON summary (selected fields and optionally raw), and cleans up by default.

.PARAMETER Raw
  Also print the raw JSON document.

.PARAMETER Keep
  Keep the temporary folder instead of deleting it.

.PARAMETER ResultsPath
  Optional explicit results path. Defaults to a temp subfolder.

.EXAMPLE
  tools/Quick-DispatcherSmoke.ps1

.EXAMPLE
  tools/Quick-DispatcherSmoke.ps1 -Raw -Keep
#>

param(
  [switch]$Raw,
  [switch]$Keep,
  [string]$ResultsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  $dispatcher = Join-Path $root 'Invoke-PesterTests.ps1'
  if (-not (Test-Path -LiteralPath $dispatcher -PathType Leaf)) { throw "Dispatcher not found: $dispatcher" }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
  $testsDir = Join-Path $tmp 'tests'
  New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
  $mini = @(
    "Describe 'Mini' {",
    "  It 'passes' { 1 | Should -Be 1 }",
    "}"
  ) -join [Environment]::NewLine
  Set-Content -LiteralPath (Join-Path $testsDir 'Mini.Tests.ps1') -Value $mini -Encoding UTF8

  if ([string]::IsNullOrWhiteSpace($ResultsPath)) { $ResultsPath = Join-Path $tmp 'results' }
  # Avoid writing to a GitHub step summary during local runs
  $env:DISABLE_STEP_SUMMARY = '1'

  & $dispatcher -TestsPath $testsDir -ResultsPath $ResultsPath | Out-Null
  Write-Host ('Exit: {0}' -f $LASTEXITCODE)

  $summaryPath = Join-Path $ResultsPath 'pester-summary.json'
  if (Test-Path -LiteralPath $summaryPath) {
    $json = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $json | Select-Object schemaVersion,total,passed,failed,errors,skipped,duration_s | Format-List
    if ($Raw) { $json | ConvertTo-Json -Depth 6 | Write-Output }
  } else {
    Write-Warning 'Summary JSON missing'
    if (Test-Path -LiteralPath $ResultsPath) {
      Get-ChildItem -Force $ResultsPath -ErrorAction SilentlyContinue | Format-List | Out-String | Write-Host
    }
  }

  if (-not $Keep) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
} catch {
  Write-Error $_
  if ($tmp -and -not $Keep) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
  exit 1
}
