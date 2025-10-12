#Requires -Version 7.0
<#
.SYNOPSIS
  Validates g-cli availability and reports version; fails fast if missing.

.PARAMETER AppendStepSummary
  When set, append a summary block to $env:GITHUB_STEP_SUMMARY.
#>
[CmdletBinding()]
param(
  [switch]$AppendStepSummary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-GCliPath {
  if ($env:GCLI_PATH -and (Test-Path -LiteralPath $env:GCLI_PATH -PathType Leaf)) { return (Resolve-Path -LiteralPath $env:GCLI_PATH).Path }
  foreach ($name in @('g-cli','gcli','g-cli.exe','gcli.exe')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
  }
  return $null
}

$ok = $true
$notes = @()
$errors = @()

$path = Resolve-GCliPath
if (-not $path) {
  $ok = $false
  $errors += 'g-cli not found in PATH and GCLI_PATH not set.'
} else {
  $notes += ('Path: {0}' -f $path)
  try {
    $p = Start-Process -FilePath $path -ArgumentList '--version' -NoNewWindow -PassThru -RedirectStandardOutput (New-TemporaryFile) -RedirectStandardError (New-TemporaryFile)
    $null = $p.WaitForExit(5000)
    $ver = Get-Content -LiteralPath $p.RedirectStandardOutput -Raw -ErrorAction SilentlyContinue
    if ($ver) { $notes += ('Version: {0}' -f ($ver.Trim())) }
  } catch { $notes += 'Version: (unavailable)' }
}

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  $lines = @('### g-cli Preflight','')
  $status = if ($ok) { 'ok' } else { 'fail' }
  $lines += ('- Status: {0}' -f $status)
  foreach ($n in $notes)  { $lines += ('- {0}' -f $n) }
  foreach ($e in $errors) { $lines += ('- error: {0}' -f $e) }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if (-not $ok) { exit 1 } else { exit 0 }

