[CmdletBinding()]
param(
  [string]$ContractReportPath = 'tests/results/session-index-v2-contract/session-index-v2-contract.json',
  [string]$DispositionReportPath = 'tests/results/session-index-v2-contract/session-index-v2-disposition.json',
  [string]$ConsumerMatrixPath = 'docs/SESSION_INDEX_V2_CONSUMER_MATRIX.md',
  [string]$DeprecationPolicyPath = 'docs/SESSION_INDEX_V1_DEPRECATION.md',
  [string]$OutputPath = 'tests/results/session-index-v2-contract/session-index-v2-cutover-readiness.json',
  [int]$NoRegressionThreshold = 5,
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "JSON file not found: $Path"
  }

  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50)
}

function Get-ChecklistSummary {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Deprecation policy not found: $Path"
  }

  $remainingItems = [System.Collections.Generic.List[string]]::new()
  $completedItems = [System.Collections.Generic.List[string]]::new()
  $inChecklist = $false

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^## Removal checklist') {
      $inChecklist = $true
      continue
    }

    if ($inChecklist -and $line -match '^## ') {
      break
    }

    if ($inChecklist -and $line -match '^- \[[ xX]\] (.+)$') {
      $item = [string]$Matches[1]
      if ([string]::IsNullOrWhiteSpace($item)) {
        throw "Malformed removal checklist entry in ${Path}: $line"
      }

      if ($line -match '^- \[[xX]\]') {
        $completedItems.Add($item.Trim())
      } else {
        $remainingItems.Add($item.Trim())
      }
    }
  }

  if ($remainingItems.Count -eq 0 -and $completedItems.Count -eq 0) {
    throw "No removal checklist entries found in $Path"
  }

  return [ordered]@{
    remainingItems = @($remainingItems)
    completedItems = @($completedItems)
  }
}

function Get-ConsumerMatrixSummary {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Consumer matrix not found: $Path"
  }

  $inMatrix = $false
  $rows = [System.Collections.Generic.List[object]]::new()

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^## Matrix') {
      $inMatrix = $true
      continue
    }

    if ($inMatrix -and $line -match '^## ') {
      break
    }

    if ($inMatrix -and $line -match '^\|') {
      if ($line -match '^\|\s*Consumer\s*\|' -or $line -match '^\|\s*-+\s*\|') {
        continue
      }
      $parts = @($line.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
      if ($parts.Count -lt 5) {
        throw "Malformed consumer matrix row in ${Path}: $line"
      }
      $rows.Add([ordered]@{
        consumer = $parts[0]
        area = $parts[1]
        v2FirstStatus = $parts[2]
        v1Fallback = $parts[3]
        notes = $parts[4]
      })
    }
  }

  if ($rows.Count -le 0) {
    throw "No critical consumer rows found in $Path"
  }

  # Only explicit v2-first-ready markers count toward cutover readiness.
  $readyToken = 'v2-first-ready'
  $notReadyConsumers = @(
    foreach ($row in $rows) {
      $normalizedStatus = [string]$row.v2FirstStatus
      if ($normalizedStatus) {
        $normalizedStatus = $normalizedStatus.Trim()
        if ($normalizedStatus.StartsWith('`') -and $normalizedStatus.EndsWith('`') -and $normalizedStatus.Length -ge 2) {
          $normalizedStatus = $normalizedStatus.Substring(1, $normalizedStatus.Length - 2)
        }
        $normalizedStatus = $normalizedStatus.Trim()
      }
      if ($normalizedStatus -cne $readyToken) {
        [string]$row.consumer
      }
    }
  )

  return [ordered]@{
    criticalConsumerCount = $rows.Count
    readyConsumerCount = ($rows.Count - $notReadyConsumers.Count)
    allV2FirstReady = ($notReadyConsumers.Count -eq 0)
    notReadyConsumers = @($notReadyConsumers)
  }
}

function Write-GitHubOutputValue {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    return
  }

  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value ("{0}={1}" -f $Name, $Value)
}

$contract = Read-JsonFile -Path $ContractReportPath
$disposition = Read-JsonFile -Path $DispositionReportPath
$checklist = Get-ChecklistSummary -Path $DeprecationPolicyPath
$consumerMatrixSummary = Get-ConsumerMatrixSummary -Path $ConsumerMatrixPath

$promotionReady = [bool]$contract.burnIn.promotionReady
$consecutiveSuccess = [int]$contract.burnIn.consecutiveSuccess
$burnInThreshold = [int]$contract.burnIn.threshold
$contractStatus = [string]$contract.status
$dispositionValue = [string]$disposition.disposition

$guardStatus = if ($contractStatus -ne 'pass') {
  'blocked'
} elseif ($consecutiveSuccess -ge $NoRegressionThreshold) {
  'satisfied'
} else {
  'pending'
}

$guardReason = switch ($guardStatus) {
  'blocked' { 'session-index-v2-contract is currently failing, so the no-regression guard is blocked.' }
  'satisfied' { 'The current consecutive-success evidence meets the no-regression guard threshold.' }
  default { "Only $consecutiveSuccess consecutive successful runs are recorded; $NoRegressionThreshold are required." }
}

$reasons = [System.Collections.Generic.List[string]]::new()
if (-not $promotionReady) {
  $reasons.Add("Promotion gate is not ready ($consecutiveSuccess/$burnInThreshold consecutive successful runs).")
}
if ($guardStatus -ne 'satisfied') {
  $reasons.Add($guardReason)
}
if ($checklist.remainingItems.Count -gt 0) {
  $reasons.Add(("{0} deprecation checklist item(s) remain incomplete." -f $checklist.remainingItems.Count))
}
if (-not $consumerMatrixSummary.allV2FirstReady) {
  $reasons.Add(
    ("Critical consumers are still not marked v2-first in the matrix: {0}." -f ($consumerMatrixSummary.notReadyConsumers -join ', '))
  )
}

$cutoverReady = (
  $promotionReady -and
  $guardStatus -eq 'satisfied' -and
  $checklist.remainingItems.Count -eq 0 -and
  $consumerMatrixSummary.allV2FirstReady
)
$status = if ($cutoverReady) { 'ready' } else { 'not-ready' }

$report = [ordered]@{
  schema = 'session-index-v2-cutover-readiness@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  status = $status
  cutoverReady = $cutoverReady
  promotionGate = [ordered]@{
    promotionReady = $promotionReady
    threshold = $burnInThreshold
    consecutiveSuccess = $consecutiveSuccess
    burnInStatus = [string]$contract.burnIn.status
    contractStatus = $contractStatus
    disposition = $dispositionValue
  }
  consumerRegressionGuard = [ordered]@{
    threshold = $NoRegressionThreshold
    consecutiveSuccess = $consecutiveSuccess
    status = $guardStatus
    reason = $guardReason
  }
  consumerMatrix = [ordered]@{
    path = $ConsumerMatrixPath
    criticalConsumerCount = $consumerMatrixSummary.criticalConsumerCount
    readyConsumerCount = $consumerMatrixSummary.readyConsumerCount
    allV2FirstReady = $consumerMatrixSummary.allV2FirstReady
    notReadyConsumers = @($consumerMatrixSummary.notReadyConsumers)
  }
  deprecationChecklist = [ordered]@{
    path = $DeprecationPolicyPath
    remainingCount = $checklist.remainingItems.Count
    remainingItems = @($checklist.remainingItems)
    completedItems = @($checklist.completedItems)
  }
  evidence = [ordered]@{
    contractReportPath = $ContractReportPath
    dispositionReportPath = $DispositionReportPath
    consumerMatrixPath = $ConsumerMatrixPath
    deprecationPolicyPath = $DeprecationPolicyPath
  }
  reasons = @($reasons)
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host ("session-index-v2 cutover readiness report written: {0}" -f $OutputPath)

Write-GitHubOutputValue -Name 'session-index-v2-cutover-status' -Value ([string]$report.status)
Write-GitHubOutputValue -Name 'session-index-v2-cutover-ready' -Value (([string]$report.cutoverReady).ToLowerInvariant())
Write-GitHubOutputValue -Name 'session-index-v2-cutover-regression-guard-status' -Value ([string]$report.consumerRegressionGuard.status)
Write-GitHubOutputValue -Name 'session-index-v2-cutover-remaining-checklist-count' -Value ([string]$report.deprecationChecklist.remainingCount)
Write-GitHubOutputValue -Name 'session-index-v2-cutover-report-path' -Value ([string]$OutputPath)

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $summary = @(
    '### Session Index v2 Cutover Readiness',
    '',
    ("- Status: **{0}**" -f $report.status),
    ("- Cutover ready: **{0}**" -f $report.cutoverReady),
    ("- Promotion ready: **{0}**" -f $report.promotionGate.promotionReady),
    ("- No-regression guard: **{0}** ({1}/{2})" -f $report.consumerRegressionGuard.status, $report.consumerRegressionGuard.consecutiveSuccess, $report.consumerRegressionGuard.threshold),
    ("- Remaining deprecation checklist items: **{0}**" -f $report.deprecationChecklist.remainingCount),
    ('- Contract report: `{0}`' -f $ContractReportPath),
    ('- Disposition report: `{0}`' -f $DispositionReportPath),
    ('- Cutover report: `{0}`' -f $OutputPath)
  )

  if ($report.reasons.Count -gt 0) {
    $summary += ''
    $summary += '#### Reasons'
    foreach ($reason in $report.reasons) {
      $summary += ("- {0}" -f $reason)
    }
  }

  $summary -join "`n" | Set-Content -LiteralPath $StepSummaryPath -Encoding utf8
}
