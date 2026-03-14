#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$node = if ($env:HOOKS_NODE) { $env:HOOKS_NODE } else { 'node' }
$core = Join-Path $scriptRoot 'core' 'post-commit.mjs'

$nodePathLike = $node -match '[:\\/]'
if ($nodePathLike) {
  if (-not (Test-Path -LiteralPath $node -PathType Leaf)) {
    Write-Warning "[hooks] Node binary not executable at '$node'; skipping post-commit."
    exit 0
  }
} elseif (-not (Get-Command $node -ErrorAction SilentlyContinue)) {
  Write-Warning "[hooks] Node binary '$node' not found; skipping post-commit."
  exit 0
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $node
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $false
$psi.RedirectStandardError = $false
$psi.ArgumentList.Add($core)
$psi.WorkingDirectory = (git rev-parse --show-toplevel)

$process = [System.Diagnostics.Process]::Start($psi)
$process.WaitForExit()
exit $process.ExitCode
