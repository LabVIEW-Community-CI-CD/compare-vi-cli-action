#Requires -Version 7.0
[CmdletBinding()]
param(
  [string[]]$StagedFiles
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

function Invoke-PSScriptAnalyzerIfAvailable {
  param([string[]]$Paths)
  try {
    if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
      Write-Output '[pre-commit] Running PSScriptAnalyzer on staged PowerShell files'
      $res = @()
      foreach ($path in $Paths) {
        $res += Invoke-ScriptAnalyzer -Path $path -Severity Error,Warning -ErrorAction Stop
      }
      if ($res) {
        $res | Format-Table -AutoSize | Out-String | Write-Output
        throw "PSScriptAnalyzer detected issues."
      }
    } else {
      Write-Output '[pre-commit] PSScriptAnalyzer not installed; skipping analyzer step'
    }
  } catch {
    throw
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

Invoke-PSScriptAnalyzerIfAvailable -Paths $psFiles
Invoke-LocalLinter -Paths $psFiles

Write-Output '[pre-commit] PowerShell validation completed.'
