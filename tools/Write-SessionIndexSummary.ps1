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
$branchSummaryEnv = $env:SESSION_INDEX_BRANCH_SUMMARY
$toggleSchemaEnv = $env:SESSION_INDEX_TOGGLE_SCHEMA
$toggleSchemaVersionEnv = $env:SESSION_INDEX_TOGGLE_SCHEMA_VERSION
$toggleGeneratedAtEnv = $env:SESSION_INDEX_TOGGLE_GENERATED_AT
$manifestDigestEnv = $env:SESSION_INDEX_TOGGLE_MANIFEST_DIGEST
$profilesEnv = $env:SESSION_INDEX_TOGGLE_PROFILES

if (-not $toggleSchemaEnv -or -not $toggleSchemaVersionEnv -or -not $toggleGeneratedAtEnv -or -not $manifestDigestEnv -or -not $profilesEnv) {
  $modulePath = Join-Path (Split-Path -Parent $PSCommandPath) 'AgentToggles.psm1'
  if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
    try {
      Import-Module $modulePath -Force -ErrorAction Stop
      $contract = Get-AgentToggleContract
      $valuesPayload = Get-AgentToggleValues
      if (-not $toggleSchemaEnv) { $toggleSchemaEnv = $contract.schema }
      if (-not $toggleSchemaVersionEnv) { $toggleSchemaVersionEnv = $contract.schemaVersion }
      if (-not $toggleGeneratedAtEnv) { $toggleGeneratedAtEnv = $contract.generatedAtUtc }
      if (-not $manifestDigestEnv) { $manifestDigestEnv = $contract.manifestDigest }
      if (-not $profilesEnv -and $valuesPayload -and $valuesPayload.profiles) {
        $profilesEnv = ($valuesPayload.profiles -join ',')
      }
    } catch {
      # Best-effort; fall back to whatever environment data is present
    }
  }
}

if ($branchSummaryEnv) { $lines += ("- Branch: {0}" -f $branchSummaryEnv) }
if ($toggleSchemaEnv) {
  $schemaLine = if ($toggleSchemaVersionEnv) {
    "{0} (v{1})" -f $toggleSchemaEnv, $toggleSchemaVersionEnv
  } else {
    $toggleSchemaEnv
  }
  $lines += ("- Toggle schema: {0}" -f $schemaLine)
}
if ($toggleGeneratedAtEnv) { $lines += ("- Toggle generated at: {0}" -f $toggleGeneratedAtEnv) }
if ($manifestDigestEnv) { $lines += ("- Toggle manifest digest: {0}" -f $manifestDigestEnv) }
if ($profilesEnv) { $lines += ("- Toggle profiles: {0}" -f $profilesEnv) }
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
