#Requires -Version 7.0
<#!
.SYNOPSIS
  Write text to the GitHub Actions step summary (with safe fallback).
.DESCRIPTION
  Resolves the step summary path using Get-StepSummaryPath.ps1, then writes
  the provided content. Falls back to a local file when not running in GH.
.PARAMETER Text
  Text to write. Mutually exclusive with -Lines.
.PARAMETER Lines
  Collection of lines to write. Mutually exclusive with -Text.
.PARAMETER Append
  Append to existing file (default replaces content).
.PARAMETER FallbackFile
  Filename to use when GITHUB_STEP_SUMMARY is not set.
#>
[CmdletBinding()] param(
  [string] $Text,
  [string[]] $Lines,
  [switch] $Append,
  [string] $FallbackFile = 'step-summary.md'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (($Text -and $Lines) -or (-not $Text -and -not $Lines)) {
  throw 'Provide either -Text or -Lines.'
}
$content = if ($Text) { $Text } else { $Lines -join [Environment]::NewLine }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$resolver = Join-Path $here 'Get-StepSummaryPath.ps1'
$path = & $resolver -FallbackFile $FallbackFile
if ($Append) { Add-Content -LiteralPath $path -Value $content -Encoding utf8 } else { Set-Content -LiteralPath $path -Value $content -Encoding utf8 }
Write-Output $path

