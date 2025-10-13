#Requires -Version 7.0
<#!
.SYNOPSIS
  Invoke g-cli with provided arguments, capture output, and optionally append a step summary.

.PARAMETER Args
  Argument string to pass to g-cli (exact, space-delimited). Example: '--version' or 'labview close'.

.PARAMETER AppendStepSummary
  When set, append a concise block to $env:GITHUB_STEP_SUMMARY.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$Args,
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
  throw 'g-cli executable not found. Set GCLI_PATH or install g-cli in PATH.'
}

$gcli = Resolve-GCliPath
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $gcli
foreach ($tok in ($Args -split '\s+')) { if ($tok) { $psi.ArgumentList.Add($tok) } }
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
$null = $proc.Start()
$null = $proc.WaitForExit(60000)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$exit  = $proc.ExitCode

if ($AppendStepSummary -and $env:GITHUB_STEP_SUMMARY) {
  $lines = @('### g-cli Invocation','',
    "- Path: $gcli",
    "- Args: $Args",
    "- Exit: $exit")
  if ($stdout) { $lines += ("- Stdout: `n```text`n{0}`n```" -f ($stdout.Trim())) }
  if ($stderr) { $lines += ("- Stderr: `n```text`n{0}`n```" -f ($stderr.Trim())) }
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($exit -ne 0) {
  Write-Error ("g-cli exited with {0}. stderr: {1}" -f $exit, ($stderr.Trim()))
  exit $exit
}

Write-Output ($stdout.Trim())
exit 0

