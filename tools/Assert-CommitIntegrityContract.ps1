[CmdletBinding()]
param(
  [string]$WorkflowPath = '.github/workflows/commit-integrity.yml',
  [string]$BranchRequiredChecksPath = 'tools/policy/branch-required-checks.json',
  [string]$PriorityPolicyPath = 'tools/priority/policy.json',
  [string]$PolicyPath = 'tools/policy/commit-integrity-policy.json',
  [string]$SchemaPath = 'docs/schemas/commit-integrity-report-v1.schema.json',
  [string]$RuntimeScriptPath = 'tools/priority/commit-integrity.mjs',
  [string]$WorkflowName = 'commit-integrity',
  [string]$JobId = 'commit-integrity',
  [string]$JobName = 'commit-integrity',
  [string]$DevelopBranch = 'develop',
  [string]$MainBranch = 'main',
  [string]$DevelopRulesetId = 'develop',
  [string]$MainRulesetId = '8614140',
  [string]$ExpectedObservedCheck = 'commit-integrity',
  [string]$ExpectedReportPath = 'tests/results/_agent/commit-integrity/commit-integrity-report.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$errors = New-Object System.Collections.Generic.List[string]

function Add-ContractError {
  param([string]$Message)
  $errors.Add($Message) | Out-Null
}

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20)
}

function Resolve-RulesetObservedChecks {
  param(
    [Parameter(Mandatory)][object]$PriorityPolicy,
    [Parameter(Mandatory)][string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    $node = $PriorityPolicy.rulesets.PSObject.Properties[$candidate]
    if ($node) {
      return @($node.Value.observed_status_checks)
    }
  }

  return @()
}

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Workflow file not found: $WorkflowPath"
}
if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
  Add-ContractError "Schema file missing: $SchemaPath"
}
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
  Add-ContractError "Policy file missing: $PolicyPath"
}
if (-not (Test-Path -LiteralPath $RuntimeScriptPath -PathType Leaf)) {
  Add-ContractError "Runtime script missing: $RuntimeScriptPath"
}

$workflowContent = Get-Content -LiteralPath $WorkflowPath -Raw

$workflowNamePattern = '(?m)^name:\s*' + [regex]::Escape($WorkflowName) + '\s*$'
if (-not [regex]::IsMatch($workflowContent, $workflowNamePattern)) {
  Add-ContractError "Workflow name mismatch in $WorkflowPath (expected '$WorkflowName')."
}

$jobIdPattern = '(?m)^\s{2}' + [regex]::Escape($JobId) + ':\s*$'
if (-not [regex]::IsMatch($workflowContent, $jobIdPattern)) {
  Add-ContractError "Workflow job id '$JobId' is missing in $WorkflowPath."
}

$jobNamePattern = '(?m)^\s{4}name:\s*' + [regex]::Escape($JobName) + '\s*$'
if (-not [regex]::IsMatch($workflowContent, $jobNamePattern)) {
  Add-ContractError "Workflow job name mismatch in $WorkflowPath (expected '$JobName')."
}

$reportPathPattern = '(?m)' + [regex]::Escape($ExpectedReportPath)
if (-not [regex]::IsMatch($workflowContent, $reportPathPattern)) {
  Add-ContractError "Workflow does not reference expected report path '$ExpectedReportPath'."
}

$branchPolicy = Read-JsonFile -Path $BranchRequiredChecksPath
$branchObserved = $branchPolicy.observed
if (-not $branchObserved) {
  Add-ContractError "Missing observed node in $BranchRequiredChecksPath."
} else {
  foreach ($branchName in @($DevelopBranch, $MainBranch)) {
    $checks = @($branchObserved.$branchName)
    if ($checks.Count -eq 0) {
      Add-ContractError "Missing observed checks for branch '$branchName' in $BranchRequiredChecksPath."
      continue
    }
    if (-not ($checks -contains $ExpectedObservedCheck)) {
      Add-ContractError "Observed branch checks for '$branchName' missing '$ExpectedObservedCheck' in $BranchRequiredChecksPath."
    }
  }
}

$priorityPolicy = Read-JsonFile -Path $PriorityPolicyPath
foreach ($branchName in @($DevelopBranch, $MainBranch)) {
  $checks = @($priorityPolicy.branches.$branchName.observed_status_checks)
  if ($checks.Count -eq 0) {
    Add-ContractError "Priority policy branch '$branchName' missing observed_status_checks."
    continue
  }
  if (-not ($checks -contains $ExpectedObservedCheck)) {
    Add-ContractError "Priority policy branch '$branchName' observed_status_checks missing '$ExpectedObservedCheck'."
  }
}

foreach ($rulesetId in @($DevelopRulesetId, $MainRulesetId)) {
  $candidates = if ($rulesetId -eq 'develop') { @('develop', '8811898') } else { @($rulesetId) }
  $checks = @(Resolve-RulesetObservedChecks -PriorityPolicy $priorityPolicy -Candidates $candidates)
  if ($checks.Count -eq 0) {
    Add-ContractError "Priority policy ruleset '$rulesetId' missing observed_status_checks."
    continue
  }
  if (-not ($checks -contains $ExpectedObservedCheck)) {
    Add-ContractError "Priority policy ruleset '$rulesetId' observed_status_checks missing '$ExpectedObservedCheck'."
  }
}

$ownerHardcodePattern = '(?i)LabVIEW-Community-CI-CD|svelderrainruiz'
foreach ($pathToScan in @($RuntimeScriptPath, $PolicyPath)) {
  if (-not (Test-Path -LiteralPath $pathToScan -PathType Leaf)) {
    continue
  }
  $content = Get-Content -LiteralPath $pathToScan -Raw
  if ([regex]::IsMatch($content, $ownerHardcodePattern)) {
    Add-ContractError "Owner hardcode detected in $pathToScan. Runtime/policy must remain defork-safe."
  }
}

if ($errors.Count -gt 0) {
  foreach ($errorMessage in $errors) {
    Write-Error $errorMessage
  }
  exit 1
}

Write-Host "[commit-integrity-contract] OK: $ExpectedObservedCheck" -ForegroundColor Green
