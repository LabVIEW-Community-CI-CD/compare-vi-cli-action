<#
.SYNOPSIS
  Writes a condensed Pester test summary to the GitHub Actions step summary (GITHUB_STEP_SUMMARY).

.DESCRIPTION
  Consumes the dispatcher-generated summary sources (prefers JSON -> TXT fallback) inside tests/results.
  Produces a markdown section with totals, pass/fail counts, duration, and (if present) a table of failed tests.

.USAGE
  pwsh -File scripts/Write-PesterSummaryToStepSummary.ps1 -Verbose
  # In a workflow step AFTER tests run:
  # - name: Publish Pester Summary
  #   shell: pwsh
  #   run: pwsh -File scripts/Write-PesterSummaryToStepSummary.ps1

.NOTES
  Requires environment variable GITHUB_STEP_SUMMARY; if absent, script no-ops with a warning.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [ValidateSet('None','Details','DetailsOpen')][string]$FailedTestsCollapseStyle = 'Details',
  [switch]$IncludeFailedDurations = $true,
  [ValidateSet('None','Relative')][string]$FailedTestsLinkStyle = 'None',
  [switch]$EmitFailureBadge,
  [switch]$Compact,
  [string]$CommentPath,
  [string]$BadgeJsonPath,
  [string]$OperatorOutcomePath = 'pester-operator-outcome.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failurePayloadTool = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools' 'PesterFailurePayload.ps1'
if (Test-Path -LiteralPath $failurePayloadTool -PathType Leaf) {
  . $failurePayloadTool
}

function Get-SummaryValue {
  param(
    $InputObject,
    [string[]]$PropertyNames
  )

  if (-not $InputObject) { return $null }

  foreach ($name in $PropertyNames) {
    if (-not $name) { continue }

    if ($InputObject -is [hashtable]) {
      if ($InputObject.ContainsKey($name)) { return $InputObject[$name] }
      continue
    }

    $prop = $InputObject.PSObject.Properties[$name]
    if ($prop) { return $prop.Value }
  }

  return $null
}

function Get-OperatorOutcome {
  param(
    [Parameter(Mandatory = $true)][string]$ResultsDir,
    [string]$OutcomePath
  )

  if ([string]::IsNullOrWhiteSpace($OutcomePath)) {
    return $null
  }

  $resolvedPath = if ([System.IO.Path]::IsPathRooted($OutcomePath)) {
    $OutcomePath
  } else {
    Join-Path $ResultsDir $OutcomePath
  }

  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    Write-Warning ("Failed to parse operator outcome: {0}" -f $_.Exception.Message)
    return $null
  }
}

if (-not $env:GITHUB_STEP_SUMMARY -and -not $CommentPath) {
  Write-Warning 'GITHUB_STEP_SUMMARY not set and no -CommentPath provided; skipping summary emission.'
  return
}

$summaryPath = Join-Path $ResultsDir 'pester-summary.json'
$txtPath = Join-Path $ResultsDir 'pester-summary.txt'
$xmlPath = Join-Path $ResultsDir 'pester-results.xml'
$operatorOutcome = Get-OperatorOutcome -ResultsDir $ResultsDir -OutcomePath $OperatorOutcomePath

$_accumulatedLines = [System.Collections.Generic.List[string]]::new()
function Add-Line($s) { $_accumulatedLines.Add([string]$s) | Out-Null }
function Flush-Outputs {
  param()
  if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($_accumulatedLines -join [Environment]::NewLine) -Encoding UTF8
  }
  if ($CommentPath) {
    $dir = Split-Path -Parent $CommentPath
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    Set-Content -Path $CommentPath -Value ($_accumulatedLines -join [Environment]::NewLine) -Encoding UTF8
  }
}

Write-Verbose "Using summary target: $env:GITHUB_STEP_SUMMARY"

$summary = $null
if (Test-Path $summaryPath) {
  try { $summary = Get-Content $summaryPath -Raw | ConvertFrom-Json } catch { Write-Warning ("Failed to parse {0}: {1}" -f $summaryPath, $_.Exception.Message) }
}

$totals = $null
if ($summary) {
  $totals = $summary | Select-Object -First 1
}
elseif (Test-Path $txtPath) {
  # Fallback: parse minimal metrics from text summary lines
  $lines = Get-Content $txtPath -ErrorAction SilentlyContinue
  $hash = @{}
  foreach ($l in $lines) { if ($l -match '^(Total Tests|Passed|Failed|Errors|Skipped):\s+(\d+)') { $hash[$matches[1]] = [int]$matches[2] } }
  if ($hash.Count) { $totals = [pscustomobject]@{ Total=$hash['Total Tests']; Passed=$hash['Passed']; Failed=$hash['Failed']; Errors=$hash['Errors']; Skipped=$hash['Skipped'] } }
}

Add-Line '## Pester Test Summary'

# Optional badge line for quick copy into PR comments
if ($EmitFailureBadge -or $Compact) {
  $failedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Failed','failed')
  $totalCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Total','total')
  $badge = if ($failedCount -gt 0) {
    "**❌ Tests Failed:** $failedCount of $totalCount"
  } else {
    "**✅ All Tests Passed:** $totalCount"
  }
  Add-Line ''
  Add-Line $badge
  if ($BadgeJsonPath) {
    $passedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Passed','passed')
    $errorsCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Errors','errors')
    $skippedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Skipped','skipped')
    $duration = Get-SummaryValue -InputObject $totals -PropertyNames @('Duration','duration')
    $status = if ($failedCount -gt 0) { 'failed' } else { 'passed' }
    $failJsonFile = Join-Path $ResultsDir 'pester-failures.json'
    $failedNames = @()
    $failureDetailsStatus = [string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsStatus'))
    $failureDetailsReason = [string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsReason'))
    if (Test-Path $failJsonFile) {
      try {
        $fj = Get-Content $failJsonFile -Raw | ConvertFrom-Json
        $detailState = Get-PesterFailureDetailState -FailurePayload $fj -Summary $totals
        $failureDetailsStatus = $detailState.detailStatus
        $failureDetailsReason = $detailState.unavailableReason
        $failedNames = @($detailState.entries | Where-Object { $_.result -eq 'Failed' } | ForEach-Object { $_.name })
      } catch { }
    }
    $badgeObj = [pscustomobject]@{
      status = $status
      total = $totalCount
      passed = $passedCount
      failed = $failedCount
      errors = $errorsCount
      skipped = $skippedCount
      durationSeconds = $duration
      badgeMarkdown = $badge
      badgeText = ($badge -replace '\*','')
      failedTests = $failedNames
      failureDetailsStatus = $failureDetailsStatus
      failureDetailsReason = $failureDetailsReason
      classification = if ($operatorOutcome) { [string]$operatorOutcome.classification } else { '' }
      gateStatus = if ($operatorOutcome) { [string]$operatorOutcome.gateStatus } else { '' }
      nextActionId = if ($operatorOutcome) { [string]$operatorOutcome.nextActionId } else { '' }
      nextAction = if ($operatorOutcome) { [string]$operatorOutcome.nextAction } else { '' }
      reasons = if ($operatorOutcome) { @($operatorOutcome.reasons) } else { @() }
      generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    try {
      $badgeDir = Split-Path -Parent $BadgeJsonPath
      if ($badgeDir -and -not (Test-Path $badgeDir)) { New-Item -ItemType Directory -Path $badgeDir | Out-Null }
      Set-Content -Path $BadgeJsonPath -Value ($badgeObj | ConvertTo-Json -Depth 6) -Encoding UTF8
    } catch {
      Write-Warning ("Failed to write badge JSON: {0}" -f $_.Exception.Message)
    }
  }
}

if (-not $totals) {
  Add-Line '> No Pester summary data found.'
  Flush-Outputs
  return
}

# Compact mode: single concise block, no tables
if ($Compact) {
  $failedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Failed','failed')
  $passedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Passed','passed')
  $skippedCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Skipped','skipped')
  $errorsCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Errors','errors')
  $duration = Get-SummaryValue -InputObject $totals -PropertyNames @('Duration','duration')
  $totalCount = Get-SummaryValue -InputObject $totals -PropertyNames @('Total','total')
  $pieces = @()
  $pieces += "$totalCount total"
  $pieces += "$passedCount passed"
  $pieces += "$failedCount failed"
  if ($errorsCount -ne $null) { $pieces += "$errorsCount errors" }
  if ($skippedCount -ne $null) { $pieces += "$skippedCount skipped" }
  if ($duration -ne $null) { $pieces += ("{0}s" -f $duration) }
  Add-Line ''
  Add-Line ("**Totals:** {0}" -f ($pieces -join ' • '))
  $executionPack = Get-SummaryValue -InputObject $totals -PropertyNames @('executionPack','ExecutionPack')
  if ($executionPack) {
    Add-Line ("**Pack:** {0}" -f $executionPack)
  }
  if ($failedCount -gt 0) {
    # failed test names (short)
    $failJsonPath = Join-Path $ResultsDir 'pester-failures.json'
    if (Test-Path $failJsonPath) {
      try {
        $failData = Get-Content $failJsonPath -Raw | ConvertFrom-Json
        $detailState = Get-PesterFailureDetailState -FailurePayload $failData -Summary $totals
        $failedNames = @($detailState.entries | Where-Object { $_.result -eq 'Failed' } | ForEach-Object { $_.name })
        if ($failedNames.Count) {
          Add-Line ("**Failures:** {0}" -f ($failedNames -join ', '))
        } elseif ($detailState.detailStatus -eq 'unavailable') {
          $reasonSuffix = if ($detailState.unavailableReason) { " ({0})" -f $detailState.unavailableReason } else { '' }
          Add-Line ("**Failure Details:** unavailable{0}" -f $reasonSuffix)
        }
      } catch { Write-Warning 'Compact mode: failed to parse failure names.' }
    } elseif ([string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsStatus')) -eq 'unavailable') {
      $reasonValue = [string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsReason'))
      $reasonSuffix = if ($reasonValue) { " ({0})" -f $reasonValue } else { '' }
      Add-Line ("**Failure Details:** unavailable{0}" -f $reasonSuffix)
    }
  }
  if ($operatorOutcome -and [string]$operatorOutcome.classification -ne 'ok') {
    Add-Line ("**Gate Outcome:** {0} ({1})" -f [string]$operatorOutcome.classification, [string]$operatorOutcome.gateStatus)
    Add-Line ("**Next Action:** {0}" -f [string]$operatorOutcome.nextAction)
  }
  Flush-Outputs
  Write-Host 'Pester summary (compact) written.' -ForegroundColor Green
  return
}

Add-Line ''
Add-Line '| Metric | Value |'
Add-Line '|--------|-------|'
Add-Line ("| Total | {0} |" -f (Get-SummaryValue -InputObject $totals -PropertyNames @('Total','total','Tests')))
Add-Line ("| Passed | {0} |" -f (Get-SummaryValue -InputObject $totals -PropertyNames @('Passed','passed')))
Add-Line ("| Failed | {0} |" -f (Get-SummaryValue -InputObject $totals -PropertyNames @('Failed','failed')))
$errorsValue = Get-SummaryValue -InputObject $totals -PropertyNames @('Errors','errors')
if ($errorsValue -ne $null) { Add-Line ("| Errors | {0} |" -f $errorsValue) }
$skippedValue = Get-SummaryValue -InputObject $totals -PropertyNames @('Skipped','skipped')
if ($skippedValue -ne $null) { Add-Line ("| Skipped | {0} |" -f $skippedValue) }
$durationValue = Get-SummaryValue -InputObject $totals -PropertyNames @('Duration','duration')
if ($durationValue -ne $null) { Add-Line ("| Duration (s) | {0} |" -f $durationValue) }
$executionPackValue = Get-SummaryValue -InputObject $totals -PropertyNames @('executionPack','ExecutionPack')
if ($executionPackValue) { Add-Line ("| Execution Pack | {0} |" -f $executionPackValue) }

if ($operatorOutcome -and [string]$operatorOutcome.classification -ne 'ok') {
  Add-Line ''
  Add-Line '### Operator Outcome'
  Add-Line ''
  Add-Line ("- Gate status: {0}" -f [string]$operatorOutcome.gateStatus)
  Add-Line ("- Classification: {0}" -f [string]$operatorOutcome.classification)
  if (@($operatorOutcome.reasons).Count -gt 0) {
    Add-Line ("- Reasons: {0}" -f ((@($operatorOutcome.reasons)) -join ', '))
  }
  Add-Line ("- Next action: {0}" -f [string]$operatorOutcome.nextAction)
}

# Optional failed test details from failures JSON if present
$failJson = Join-Path $ResultsDir 'pester-failures.json'
if (Test-Path $failJson) {
  try {
    $failData = Get-Content $failJson -Raw | ConvertFrom-Json
    $detailState = Get-PesterFailureDetailState -FailurePayload $failData -Summary $totals
    $failed = @($detailState.entries | Where-Object { $_.result -eq 'Failed' })
    if ($failed.Count) {
      Add-Line ''
      switch ($FailedTestsCollapseStyle) {
        'None' {
          Add-Line '### Failed Tests'
          Add-Line ''
        }
        'Details' {
          Add-Line '<details><summary><strong>Failed Tests</strong></summary>'
          Add-Line ''
        }
        'DetailsOpen' {
          Add-Line '<details open><summary><strong>Failed Tests</strong></summary>'
          Add-Line ''
        }
      }
      if ($IncludeFailedDurations) {
        Add-Line '| Name | Duration (s) |'
        Add-Line '|------|--------------|'
      } else {
        Add-Line '| Name |'
        Add-Line '|------|'
      }
      foreach ($f in $failed) {
        $name = $f.Name
        if ($FailedTestsLinkStyle -eq 'Relative') {
          $candidate = ($name -replace '::','.') -replace '\s+','.'
            $leaf = ($candidate -split '[\s]')[0]
            $fileRel = "tests/$leaf.Tests.ps1"
            $name = "[$($f.Name)]($fileRel)"
        }
        if ($IncludeFailedDurations) {
          Add-Line ("| {0} | {1} |" -f ($name -replace '\|','/'), ($f.Duration ?? $f.duration))
        } else {
          Add-Line ("| {0} |" -f ($name -replace '\|','/'))
        }
      }
      if ($FailedTestsCollapseStyle -like 'Details*') { Add-Line '</details>' }
    } elseif ($detailState.detailStatus -eq 'unavailable') {
      Add-Line ''
      $reasonSuffix = if ($detailState.unavailableReason) { " ({0})" -f $detailState.unavailableReason } else { '' }
      Add-Line ("Failure details unavailable{0}." -f $reasonSuffix)
    }
  } catch { Write-Warning ("Failed to parse failure JSON: {0}" -f $_.Exception.Message) }
} elseif ([string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsStatus')) -eq 'unavailable') {
  Add-Line ''
  $reasonValue = [string](Get-SummaryValue -InputObject $totals -PropertyNames @('failureDetailsReason'))
  $reasonSuffix = if ($reasonValue) { " ({0})" -f $reasonValue } else { '' }
  Add-Line ("Failure details unavailable{0}." -f $reasonSuffix)
}

Flush-Outputs
Write-Host 'Pester summary written.' -ForegroundColor Green
