param(
  [Parameter(Mandatory=$false)] [string]$ResultsDir = 'tests/results',
  [Parameter(Mandatory=$false)] [string]$SummaryJson = 'pester-summary.json',
  [Parameter(Mandatory=$false)] [switch]$DisableSessionIndexV2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
  }
  $idxPath = Join-Path $ResultsDir 'session-index.json'
  $v2Path = Join-Path $ResultsDir 'session-index-v2.json'

  $disableV2 = $DisableSessionIndexV2.IsPresent
  if (-not $disableV2) {
    $envToggle = [string]$env:SESSION_INDEX_V2_EMIT
    if (-not [string]::IsNullOrWhiteSpace($envToggle)) {
      if ($envToggle.Trim().ToLowerInvariant() -in @('0', 'false', 'off', 'no')) {
        $disableV2 = $true
      }
    }
  }

  $idxExists = Test-Path -LiteralPath $idxPath -PathType Leaf
  $v2Exists = Test-Path -LiteralPath $v2Path -PathType Leaf
  if ($idxExists -and ($disableV2 -or $v2Exists)) { return }

  if (-not $idxExists) {
    $idx = [ordered]@{
      schema             = 'session-index/v1'
      schemaVersion      = '1.0.0'
      generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
      resultsDir         = $ResultsDir
      includeIntegration = $false
      integrationMode    = $null
      integrationSource  = $null
      files              = [ordered]@{}
    }
    $sumPath = Join-Path $ResultsDir $SummaryJson
    if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
      try {
        $s = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $includeIntegration = $false
        if ($s.PSObject.Properties.Name -contains 'includeIntegration') {
          $includeIntegration = [bool]$s.includeIntegration
        }
        $integrationMode = $null
        if ($s.PSObject.Properties.Name -contains 'integrationMode') {
          $integrationMode = $s.integrationMode
        }
        $integrationSource = $null
        if ($s.PSObject.Properties.Name -contains 'integrationSource') {
          $integrationSource = $s.integrationSource
        }
        $idx.includeIntegration = $includeIntegration
        $idx.integrationMode = $integrationMode
        $idx.integrationSource = $integrationSource
        $idx['summary'] = [ordered]@{
          total      = $s.total
          passed     = $s.passed
          failed     = $s.failed
          errors     = $s.errors
          skipped    = $s.skipped
          duration_s = $s.duration_s
          schemaVersion = $s.schemaVersion
        }
        $idx.status = if (($s.failed -gt 0) -or ($s.errors -gt 0)) { 'fail' } else { 'ok' }
        $idx.files['pesterSummaryJson'] = (Split-Path -Leaf $SummaryJson)
        # Minimal step summary
        $lines = @()
        $lines += '### Session Overview (fallback)'
        $lines += ("- Status: {0}" -f $idx.status)
        $lines += ("- Total: {0} | Passed: {1} | Failed: {2} | Errors: {3} | Skipped: {4}" -f $s.total,$s.passed,$s.failed,$s.errors,$s.skipped)
        $lines += ("- Duration (s): {0}" -f $s.duration_s)
        $lines += ("- Include Integration: {0}" -f $includeIntegration)
        if ($integrationMode) { $lines += ("- Integration Mode: {0}" -f $integrationMode) }
        if ($integrationSource) { $lines += ("- Integration Source: {0}" -f $integrationSource) }
        $idx['stepSummary'] = ($lines -join "`n")
      } catch { }
    }
    $idx | ConvertTo-Json -Depth 5 | Out-File -FilePath $idxPath -Encoding utf8
    Write-Host ("Fallback session index created at: {0}" -f $idxPath)
  }

  if (-not $disableV2 -and -not (Test-Path -LiteralPath $v2Path -PathType Leaf)) {
    try {
      $cliPath = Join-Path $PSScriptRoot '..' 'dist' 'src' 'session-index' 'cli.js'
      if (Test-Path -LiteralPath $cliPath -PathType Leaf) {
        & node $cliPath --sample --out $v2Path
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $v2Path -PathType Leaf)) {
          Write-Host ("Session index v2 created at: {0}" -f $v2Path)
        } else {
          Write-Host "::warning::Session index v2 emission failed (node cli exited non-zero)."
        }
      } else {
        Write-Host "::warning::Session index v2 cli not found; skipped v2 emission."
      }
    } catch {
      Write-Host "::warning::Session index v2 emission failed: $_"
    }
  }
} catch {
  Write-Host "::warning::Ensure-SessionIndex failed: $_"
}
