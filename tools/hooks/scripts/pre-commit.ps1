#Requires -Version 7.0
[CmdletBinding()]
param(
  [string[]]$StagedFiles,
  [switch]$SkipPSScriptAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$envPayload = $env:HOOKS_STAGED_FILES_JSON
if ($envPayload) {
  try {
    $fromEnv = $envPayload | ConvertFrom-Json -ErrorAction Stop
    if ($fromEnv) {
      $StagedFiles = @()
      foreach ($item in @($fromEnv)) {
        if ($item) { $StagedFiles += [string]$item }
      }
    }
  } catch {
    Write-Warning "[pre-commit] Failed to parse HOOKS_STAGED_FILES_JSON: $($_.Exception.Message)"
  }
}

$StagedFiles = @($StagedFiles | Where-Object { $_ })

Write-Verbose "[hook] Pre-commit script received $($StagedFiles.Count) staged file(s)."

if (-not $StagedFiles -or $StagedFiles.Count -eq 0) {
  return
}

$psFiles = @($StagedFiles | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' })
if ($psFiles.Count -eq 0) {
  return
}

function Invoke-PSScriptAnalyzerGate {
  param([string[]]$Paths)
  $skipAnalyzer = $SkipPSScriptAnalyzer -or ($env:PRECOMMIT_SKIP_PSSCRIPTANALYZER -match '^(1|true|yes|on)$')
  if ($skipAnalyzer) {
    Write-Output '[pre-commit] Skipping PSScriptAnalyzer by request'
    return
  }

  if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer not installed; install the module or rerun with -SkipPSScriptAnalyzer (or PRECOMMIT_SKIP_PSSCRIPTANALYZER=1).'
  }

  Import-Module PSScriptAnalyzer -ErrorAction Stop | Out-Null
  Write-Output '[pre-commit] Running PSScriptAnalyzer on staged PowerShell files'
  $res = @()
  foreach ($path in $Paths) {
    $res += Invoke-ScriptAnalyzer -Path $path -Severity Error,Warning -ErrorAction Stop
  }
  if ($res) {
    $res | Format-Table -AutoSize | Out-String | Write-Output
    throw "PSScriptAnalyzer detected issues."
  }
}

function Invoke-LocalLinter {
  param([string[]]$Paths)

  $root = git rev-parse --show-toplevel
  Push-Location $root
  try {
    if ($Paths.Count -gt 0) {
      Write-Output '[pre-commit] Linting PowerShell patterns (inline-if, dot-sourcing)'
      $inlineIfPath = Join-Path $root 'tools' 'Lint-InlineIfInFormat.ps1'
      $dotSourcingPath = Join-Path $root 'tools' 'Lint-DotSourcing.ps1'
      try { & $inlineIfPath } catch { throw 'Inline-if lint failed' }
      try { & $dotSourcingPath -WarnOnly } catch { Write-Warning 'Dot-sourcing lint warning' }
    }
  } finally {
    Pop-Location
  }
}

Invoke-PSScriptAnalyzerGate -Paths $psFiles
Invoke-LocalLinter -Paths $psFiles

Write-Output '[pre-commit] PowerShell validation completed.'
