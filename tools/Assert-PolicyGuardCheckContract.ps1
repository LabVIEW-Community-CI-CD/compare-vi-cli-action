[CmdletBinding()]
param(
  [string]$WorkflowPath = '.github/workflows/policy-guard-upstream.yml',
  [string]$BranchRequiredChecksPath = 'tools/policy/branch-required-checks.json',
  [string]$PriorityPolicyPath = 'tools/priority/policy.json',
  [string]$WorkflowName = 'Policy Guard (Upstream)',
  [string]$JobId = 'policy-guard',
  [string]$JobName = 'Policy Guard (Upstream) / policy-guard',
  [string]$ExpectedCheckName = 'Policy Guard (Upstream) / policy-guard'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'BranchRequiredCheckProjection.psm1') -Force -DisableNameChecking

$errors = New-Object System.Collections.Generic.List[string]

function Add-ContractError {
  param([string]$Message)
  $errors.Add($Message) | Out-Null
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 20)
}

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
  throw "Workflow file not found: $WorkflowPath"
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

$branchPolicy = Read-JsonFile -Path $BranchRequiredChecksPath
$priorityPolicy = Read-JsonFile -Path $PriorityPolicyPath

$branchTargets = @('develop', 'main', 'release/*')
$rulesetTargets = @(
  @{ label = 'develop'; branchName = 'develop'; candidates = @('develop', '8811898') },
  @{ label = 'main'; branchName = 'main'; candidates = @('main', '8614140') },
  @{ label = 'release'; branchName = 'release/*'; candidates = @('release', '8614172') }
)

foreach ($branchName in $branchTargets) {
  $branchChecks = @((Resolve-BranchRequiredCheckProjection -BranchPolicy $branchPolicy -BranchName $branchName -BranchClassId $null).requiredChecks)
  if ($branchChecks.Count -eq 0) {
    Add-ContractError "Missing required checks for branch '$branchName' in $BranchRequiredChecksPath."
  } elseif (-not ($branchChecks -contains $ExpectedCheckName)) {
    Add-ContractError "Branch '$branchName' required checks missing '$ExpectedCheckName' in $BranchRequiredChecksPath."
  }

  $priorityBranchChecks = @(Resolve-PriorityPolicyBranchRequiredChecks -PriorityPolicy $priorityPolicy -BranchPolicy $branchPolicy -BranchName $branchName)
  if ($priorityBranchChecks.Count -eq 0) {
    Add-ContractError "Missing priority required checks for branch '$branchName' in $PriorityPolicyPath."
  } elseif (-not ($priorityBranchChecks -contains $ExpectedCheckName)) {
    Add-ContractError "Priority branch '$branchName' required checks missing '$ExpectedCheckName' in $PriorityPolicyPath."
  }
}

foreach ($rulesetTarget in $rulesetTargets) {
  $rulesetChecks = @(Resolve-PriorityPolicyRulesetRequiredChecks -PriorityPolicy $priorityPolicy -BranchPolicy $branchPolicy -Candidates $rulesetTarget.candidates -FallbackBranchName $rulesetTarget.branchName)
  if ($rulesetChecks.Count -eq 0) {
    Add-ContractError "Missing required checks for ruleset '$($rulesetTarget.label)' in $PriorityPolicyPath."
  } elseif (-not ($rulesetChecks -contains $ExpectedCheckName)) {
    Add-ContractError "Ruleset '$($rulesetTarget.label)' required checks missing '$ExpectedCheckName' in $PriorityPolicyPath."
  }
}

if ($errors.Count -gt 0) {
  foreach ($errorMessage in $errors) {
    Write-Error $errorMessage
  }
  exit 1
}

Write-Host "[policy-guard-check-contract] OK: $ExpectedCheckName" -ForegroundColor Green
