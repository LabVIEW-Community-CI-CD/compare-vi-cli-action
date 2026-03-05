[CmdletBinding()]
param(
  [string]$WorkflowPath = '.github/workflows/verification.yml',
  [string]$BranchRequiredChecksPath = 'tools/policy/branch-required-checks.json',
  [string]$PriorityPolicyPath = 'tools/priority/policy.json',
  [string]$BranchName = 'develop',
  [string]$RulesetId = '8811898',
  [string]$WorkflowName = 'Requirements Verification',
  [string]$JobId = 'verification',
  [string]$JobName = 'requirements-verification'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
$expectedCheckName = "$WorkflowName / $JobName"

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
$branchHasExpectedCheck = $false
if (-not $branchPolicy.branches) {
  Add-ContractError "Missing branches node in $BranchRequiredChecksPath."
} else {
  $developChecks = @($branchPolicy.branches.$BranchName)
  if ($developChecks.Count -eq 0) {
    Add-ContractError "Missing required checks for branch '$BranchName' in $BranchRequiredChecksPath."
  }
  $branchHasExpectedCheck = $developChecks -contains $expectedCheckName
}

$priorityPolicy = Read-JsonFile -Path $PriorityPolicyPath
$priorityBranchChecks = @($priorityPolicy.branches.$BranchName.required_status_checks)
$priorityBranchHasExpectedCheck = $priorityBranchChecks -contains $expectedCheckName
if ($priorityBranchChecks.Count -eq 0) {
  Add-ContractError "Missing priority branch checks for '$BranchName' in $PriorityPolicyPath."
}

$rulesetChecks = @($priorityPolicy.rulesets.$RulesetId.required_status_checks)
$rulesetHasExpectedCheck = $rulesetChecks -contains $expectedCheckName
if ($rulesetChecks.Count -eq 0) {
  Add-ContractError "Missing ruleset '$RulesetId' required checks in $PriorityPolicyPath."
}

$presenceCount = @($branchHasExpectedCheck, $priorityBranchHasExpectedCheck, $rulesetHasExpectedCheck | Where-Object { $_ }).Count
if ($presenceCount -gt 0 -and $presenceCount -lt 3) {
  Add-ContractError "Check '$expectedCheckName' appears in only part of the contract set (branch policy, priority branch, ruleset). Keep all three in sync."
}

if ($errors.Count -gt 0) {
  foreach ($errorMessage in $errors) {
    Write-Error $errorMessage
  }
  exit 1
}

Write-Host "[verification-check-contract] OK: $expectedCheckName" -ForegroundColor Green
