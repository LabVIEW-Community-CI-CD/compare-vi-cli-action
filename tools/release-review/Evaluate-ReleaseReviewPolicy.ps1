#Requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string]$ScenarioRoot,
  [Parameter(Mandatory)]
  [string]$ProfilePath,
  [Parameter(Mandatory)]
  [string]$PolicyPath,
  [Parameter(Mandatory)]
  [string]$Tag,
  [Parameter(Mandatory)]
  [string]$OutputIndexPath,
  [Parameter(Mandatory)]
  [string]$OutputCommentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ProfilePath -PathType Leaf)) {
  throw "Profile file not found: $ProfilePath"
}
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
  throw "Policy file not found: $PolicyPath"
}
if (-not (Test-Path -LiteralPath $ScenarioRoot -PathType Container)) {
  throw "Scenario root not found: $ScenarioRoot"
}

$profiles = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json -Depth 20
$policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json -Depth 20

$tagClass = 'other'
$scenarioSet = $policy.defaultRequiredScenarioSet
foreach ($classNode in @($policy.tagClasses)) {
  if (-not $classNode) { continue }
  $pattern = [string]$classNode.pattern
  if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
  if ($Tag -match $pattern) {
    $tagClass = [string]$classNode.name
    $scenarioSet = [string]$classNode.requiredScenarioSet
    break
  }
}

if ([string]::IsNullOrWhiteSpace($scenarioSet)) {
  $scenarioSet = [string]$profiles.defaultSet
}
if ([string]::IsNullOrWhiteSpace($scenarioSet)) {
  throw 'Unable to resolve scenario set from policy/profiles.'
}

$setNode = $profiles.sets.$scenarioSet
if (-not $setNode) {
  throw "Scenario set '$scenarioSet' not found in profile manifest."
}

$requiredScenarios = @($setNode.scenarios)
$requiredOs = @($policy.requiredOs)

$summaryFiles = @(Get-ChildItem -LiteralPath $ScenarioRoot -Filter '*.json' -File | Sort-Object Name)
if ($summaryFiles.Count -eq 0) {
  throw "No scenario summary JSON files found in $ScenarioRoot"
}

$summaries = @()
foreach ($file in $summaryFiles) {
  $payload = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 20
  $summaries += [pscustomobject]@{
    file = $file.FullName
    os = [string]$payload.os
    overall = [string]$payload.overall
    scenarios = @($payload.scenarios)
    payload = $payload
  }
}

$failureList = @()
foreach ($requiredOsName in $requiredOs) {
  $osSummary = $summaries | Where-Object { $_.os -eq $requiredOsName } | Select-Object -First 1
  if (-not $osSummary) {
    $failureList += "Missing required OS summary: $requiredOsName"
    continue
  }

  foreach ($scenarioId in $requiredScenarios) {
    $scenario = @($osSummary.scenarios | Where-Object { $_.id -eq $scenarioId }) | Select-Object -First 1
    if (-not $scenario) {
      $failureList += "Missing required scenario '$scenarioId' for $requiredOsName"
      continue
    }
    if ([string]$scenario.status -ne 'pass') {
      $failureList += "Scenario '$scenarioId' failed for $requiredOsName (status=$($scenario.status))"
    }
  }
}

$decision = if ($failureList.Count -eq 0) { 'pass' } else { 'fail' }

$index = [ordered]@{
  schema = 'release-review-index-v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  tag = $Tag
  tagClass = $tagClass
  scenarioSet = $scenarioSet
  decision = $decision
  requiredOs = $requiredOs
  requiredScenarios = $requiredScenarios
  osSummaries = @($summaries | ForEach-Object {
      [ordered]@{
        os = $_.os
        overall = $_.overall
        scenarios = @($_.scenarios)
      }
    })
  failures = $failureList
  sourceFiles = @($summaryFiles.FullName)
}

$indexDir = Split-Path -Parent $OutputIndexPath
if (-not [string]::IsNullOrWhiteSpace($indexDir) -and -not (Test-Path -LiteralPath $indexDir -PathType Container)) {
  New-Item -ItemType Directory -Path $indexDir -Force | Out-Null
}
$index | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputIndexPath -Encoding utf8

$commentLines = @()
$commentLines += '## Release Review Summary'
$commentLines += ''
$commentLines += ('- Tag: `' + $Tag + '`')
$commentLines += ('- Tag class: `' + $tagClass + '`')
$commentLines += ('- Scenario set: `' + $scenarioSet + '`')
$commentLines += "- Policy decision: **$decision**"
$commentLines += ''
$commentLines += '| OS | Overall | checksum | smoke-cli |'
$commentLines += '|---|---|---|---|'

foreach ($requiredOsName in $requiredOs) {
  $osSummary = $summaries | Where-Object { $_.os -eq $requiredOsName } | Select-Object -First 1
  if (-not $osSummary) {
    $commentLines += "| $requiredOsName | missing | missing | missing |"
    continue
  }

  $checksumStatus = 'missing'
  $smokeStatus = 'missing'

  $checksumNode = @($osSummary.scenarios | Where-Object { $_.id -eq 'checksum' }) | Select-Object -First 1
  if ($checksumNode) { $checksumStatus = [string]$checksumNode.status }

  $smokeNode = @($osSummary.scenarios | Where-Object { $_.id -eq 'smoke-cli' }) | Select-Object -First 1
  if ($smokeNode) { $smokeStatus = [string]$smokeNode.status }

  $commentLines += "| $requiredOsName | $($osSummary.overall) | $checksumStatus | $smokeStatus |"
}

if ($failureList.Count -gt 0) {
  $commentLines += ''
  $commentLines += '### Policy Failures'
  foreach ($failure in $failureList) {
    $commentLines += "- $failure"
  }
}

$commentDir = Split-Path -Parent $OutputCommentPath
if (-not [string]::IsNullOrWhiteSpace($commentDir) -and -not (Test-Path -LiteralPath $commentDir -PathType Container)) {
  New-Item -ItemType Directory -Path $commentDir -Force | Out-Null
}
$commentLines -join "`n" | Set-Content -LiteralPath $OutputCommentPath -Encoding utf8

Write-Host ("Release review index written: {0}" -f $OutputIndexPath)
Write-Host ("Reviewer comment markdown written: {0}" -f $OutputCommentPath)
