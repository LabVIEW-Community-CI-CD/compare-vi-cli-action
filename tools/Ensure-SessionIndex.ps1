param(
  [Parameter(Mandatory=$false)] [string]$ResultsDir = 'tests/results',
  [Parameter(Mandatory=$false)] [string]$SummaryJson = 'pester-summary.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
  if (-not (Test-Path -LiteralPath $ResultsDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
  }
  $idxPath = Join-Path $ResultsDir 'session-index.json'
  if (Test-Path -LiteralPath $idxPath -PathType Leaf) { return }

  $idx = [ordered]@{
    schema           = 'session-index/v1'
    schemaVersion    = '1.0.0'
    generatedAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
    resultsDir       = $ResultsDir
    status           = 'unknown'
    files            = [ordered]@{}
  }
  $sumPath = Join-Path $ResultsDir $SummaryJson
  if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
    try {
      $s = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json -ErrorAction Stop
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
      $idx['stepSummary'] = ($lines -join "`n")
    } catch { }
  }
  $idx | ConvertTo-Json -Depth 5 | Out-File -FilePath $idxPath -Encoding utf8
  Write-Host ("Fallback session index created at: {0}" -f $idxPath)
} catch {
  Write-Host "::warning::Ensure-SessionIndex failed: $_"
}

