<#
.SYNOPSIS
  Append a concise Session block from tests/results/session-index.json.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$FileName = 'session-index.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_STEP_SUMMARY) { return }

$path = if ($ResultsDir) { Join-Path $ResultsDir $FileName } else { $FileName }
if (-not (Test-Path -LiteralPath $path)) {
  ("### Session`n- File: (missing) {0}" -f $path) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  return
}
try { $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -ErrorAction Stop } catch { $j = $null }

$lines = @('### Session','')
if ($j) {
  function Add-LineIfPresent {
    param(
      [Parameter(Mandatory)][pscustomobject]$Object,
      [Parameter(Mandatory)][string]$Property,
      [Parameter(Mandatory)][string]$Label,
      [Parameter(Mandatory)][ref]$Target
    )
    $prop = $Object.PSObject.Properties[$Property]
    if ($prop -and $prop.Value -ne $null) {
      $Target.Value += ('- {0}: {1}' -f $Label, $prop.Value)
    }
  }

  Add-LineIfPresent -Object $j -Property 'status' -Label 'Status' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'total' -Label 'Total' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'passed' -Label 'Passed' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'failed' -Label 'Failed' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'errors' -Label 'Errors' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'skipped' -Label 'Skipped' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'duration_s' -Label 'Duration (s)' -Target ([ref]$lines)
  $lines += ('- File: {0}' -f $path)
} else {
  $lines += ('- File: failed to parse: {0}' -f $path)
}

$lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8

