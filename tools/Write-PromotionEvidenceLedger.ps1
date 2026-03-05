[CmdletBinding()]
param(
  [string]$OutputPath = 'tests/results/promotion-contract/promotion-evidence-ledger.json',
  [string]$ContractPath = 'tools/policy/promotion-contract.json',
  [string]$WorkflowName = '',
  [string]$Stream = 'unknown',
  [string]$Channel = 'unknown',
  [string]$Version = 'unknown',
  [ValidateSet('pass', 'fail', 'blocked')]
  [string]$GateStatus = 'pass',
  [string]$GateReason = '',
  [string]$CheckContext = 'Promotion Contract / promotion-contract',
  [string]$SummaryPath = '',
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Safe-ReadText {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return (Get-Content -LiteralPath $Path -Raw)
}

function Normalize-String {
  param([string]$Value, [string]$Fallback = 'unknown')
  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Fallback
  }
  return $Value.Trim()
}

$workflowNameResolved = if ([string]::IsNullOrWhiteSpace($WorkflowName)) {
  Normalize-String -Value $env:GITHUB_WORKFLOW -Fallback 'unknown-workflow'
} else {
  Normalize-String -Value $WorkflowName -Fallback 'unknown-workflow'
}

$contractRaw = Safe-ReadText -Path $ContractPath
if (-not $contractRaw) {
  throw "Promotion contract file not found: $ContractPath"
}
$contract = $contractRaw | ConvertFrom-Json -Depth 50
$contractHash = (Get-FileHash -LiteralPath $ContractPath -Algorithm SHA256).Hash.ToLowerInvariant()

$refName = Normalize-String -Value $env:GITHUB_REF_NAME -Fallback (Normalize-String -Value $env:GITHUB_REF)
$repo = Normalize-String -Value $env:GITHUB_REPOSITORY
$server = Normalize-String -Value $env:GITHUB_SERVER_URL -Fallback 'https://github.com'
$runId = Normalize-String -Value $env:GITHUB_RUN_ID
$runAttempt = Normalize-String -Value $env:GITHUB_RUN_ATTEMPT
$workflowUrl = if ($repo -ne 'unknown' -and $runId -ne 'unknown') {
  "$server/$repo/actions/runs/$runId"
} else {
  'unknown'
}

$ledger = [ordered]@{
  schema = 'promotion-evidence-ledger/v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  workflow = [ordered]@{
    name = $workflowNameResolved
    runId = $runId
    runAttempt = $runAttempt
    event = Normalize-String -Value $env:GITHUB_EVENT_NAME
    ref = $refName
    sha = Normalize-String -Value $env:GITHUB_SHA
    url = $workflowUrl
  }
  promotion = [ordered]@{
    stream = Normalize-String -Value $Stream
    channel = Normalize-String -Value $Channel
    version = Normalize-String -Value $Version
  }
  gate = [ordered]@{
    status = $GateStatus
    reason = Normalize-String -Value $GateReason -Fallback 'n/a'
    checkContext = Normalize-String -Value $CheckContext
  }
  contract = [ordered]@{
    path = $ContractPath
    sha256 = $contractHash
    requiredStatusChecks = [ordered]@{
      develop = @($contract.required_status_checks.develop)
      release = @($contract.required_status_checks.'release/*')
    }
  }
  artifacts = [ordered]@{
    summaryPath = Normalize-String -Value $SummaryPath -Fallback ''
    outputPath = $OutputPath
  }
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
$ledger | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputPath -NoNewline

if ($StepSummaryPath) {
  $summary = @(
    '## Promotion Evidence Ledger',
    '',
    ('- Stream: `{0}`' -f $ledger.promotion.stream),
    ('- Channel: `{0}`' -f $ledger.promotion.channel),
    ('- Version: `{0}`' -f $ledger.promotion.version),
    ('- Gate status: **{0}**' -f $ledger.gate.status),
    ('- Check context: `{0}`' -f $ledger.gate.checkContext),
    ('- Ledger artifact: `{0}`' -f $OutputPath)
  )
  Add-Content -LiteralPath $StepSummaryPath -Value ($summary -join [Environment]::NewLine)
}

Write-Host ("[promotion-ledger] wrote {0}" -f $OutputPath) -ForegroundColor Green
