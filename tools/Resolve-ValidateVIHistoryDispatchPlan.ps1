#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$EventName = '',
  [string]$Repository = '',
  [bool]$IsForkRepository = $false,
  [string]$HistoryScenarioSet = 'smoke',
  [bool]$AllowNonCanonical = $false,
  [bool]$AllowNonCanonicalHistoryCore = $false,
  [string]$GitHubOutputPath = '',
  [string]$StepSummaryPath = '',
  [string]$JsonPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-HistoryScenarioSet {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return 'smoke'
  }

  $normalized = $Value.Trim().ToLowerInvariant()
  $allowed = @('none', 'smoke', 'history-core')
  if ($allowed -notcontains $normalized) {
    throw ("Unsupported history_scenario_set '{0}'. Allowed: {1}" -f $Value, ($allowed -join ', '))
  }

  return $normalized
}

$requestedHistoryScenarioSet = Normalize-HistoryScenarioSet -Value $HistoryScenarioSet
$resolvedHistoryScenarioSet = $requestedHistoryScenarioSet
$executeLanes = $false
$skipReason = 'event-not-workflow-dispatch'
$downgradedHistoryCore = $false

if ($EventName -eq 'workflow_dispatch') {
  if ($IsForkRepository -and -not $AllowNonCanonical) {
    $skipReason = 'noncanonical-disabled'
  } else {
    if ($IsForkRepository -and $resolvedHistoryScenarioSet -eq 'history-core' -and -not $AllowNonCanonicalHistoryCore) {
      $resolvedHistoryScenarioSet = 'smoke'
      $downgradedHistoryCore = $true
    }

    if ($resolvedHistoryScenarioSet -eq 'none') {
      $skipReason = 'history-scenario-set-none'
    } else {
      $executeLanes = $true
      $skipReason = 'enabled'
    }
  }
}

$plan = [ordered]@{
  schema = 'validate-vi-history-dispatch-plan@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  eventName = $EventName
  repository = $Repository
  isForkRepository = [bool]$IsForkRepository
  requestedHistoryScenarioSet = $requestedHistoryScenarioSet
  historyScenarioSet = $resolvedHistoryScenarioSet
  executeLanes = [bool]$executeLanes
  skipReason = $skipReason
  downgradedHistoryCore = [bool]$downgradedHistoryCore
  allowNonCanonical = [bool]$AllowNonCanonical
  allowNonCanonicalHistoryCore = [bool]$AllowNonCanonicalHistoryCore
}

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
  $jsonDir = Split-Path -Parent $JsonPath
  if ($jsonDir -and -not (Test-Path -LiteralPath $jsonDir -PathType Container)) {
    New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
  }
  $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonPath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  "execute_lanes=$($plan.executeLanes.ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "skip_reason=$($plan.skipReason)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "history_scenario_set=$($plan.historyScenarioSet)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "requested_history_scenario_set=$($plan.requestedHistoryScenarioSet)" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
  "downgraded_history_core=$($plan.downgradedHistoryCore.ToString().ToLowerInvariant())" | Out-File -FilePath $GitHubOutputPath -Append -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $lines = @(
    '### VI History Dispatch Plan',
    '',
    ('- event_name: `{0}`' -f $plan.eventName),
    ('- repository: `{0}`' -f $plan.repository),
    ('- is_fork_repository: `{0}`' -f $plan.isForkRepository.ToString().ToLowerInvariant()),
    ('- requested_history_scenario_set: `{0}`' -f $plan.requestedHistoryScenarioSet),
    ('- history_scenario_set: `{0}`' -f $plan.historyScenarioSet),
    ('- execute_lanes: `{0}`' -f $plan.executeLanes.ToString().ToLowerInvariant()),
    ('- skip_reason: `{0}`' -f $plan.skipReason),
    ('- downgraded_history_core: `{0}`' -f $plan.downgradedHistoryCore.ToString().ToLowerInvariant())
  )
  $lines -join "`n" | Out-File -FilePath $StepSummaryPath -Append -Encoding utf8
}

$plan | ConvertTo-Json -Depth 8
