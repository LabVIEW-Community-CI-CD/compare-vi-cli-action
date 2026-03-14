[CmdletBinding()]
param(
  [string]$ContractPath = 'tools/policy/promotion-contract.json',
  [string]$BranchRequiredChecksPath = 'tools/policy/branch-required-checks.json',
  [string]$PriorityPolicyPath = 'tools/priority/policy.json',
  [string]$DevelopBranchName = 'develop',
  [string]$ReleaseBranchName = 'release/*',
  [string]$DevelopRulesetId = 'develop',
  [string]$ReleaseRulesetId = '8614172',
  [string]$OutputJsonPath = 'tests/results/promotion-contract/alignment.json',
  [string]$StepSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 50)
}

function Normalize-CheckList {
  param([AllowNull()][object]$Value)
  $list = @()
  if ($null -ne $Value) {
    $list = @($Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }
  return @($list | Sort-Object -Unique)
}

function Resolve-RulesetRequiredChecks {
  param(
    [Parameter(Mandatory)][object]$PriorityPolicy,
    [Parameter(Mandatory)][string[]]$Candidates
  )

  foreach ($candidate in $Candidates) {
    $node = $PriorityPolicy.rulesets.PSObject.Properties[$candidate]
    if ($node) {
      return @($node.Value.required_status_checks)
    }
  }

  return @()
}

function Compare-CheckSets {
  param(
    [string[]]$Expected,
    [string[]]$Actual
  )

  $exp = Normalize-CheckList -Value $Expected
  $act = Normalize-CheckList -Value $Actual
  $missing = @($exp | Where-Object { $_ -notin $act })
  $extra = @($act | Where-Object { $_ -notin $exp })
  return [pscustomobject]@{
    missing = $missing
    extra = $extra
    ok = ($missing.Count -eq 0 -and $extra.Count -eq 0)
  }
}

$contract = Read-JsonFile -Path $ContractPath
$branchPolicy = Read-JsonFile -Path $BranchRequiredChecksPath
$priorityPolicy = Read-JsonFile -Path $PriorityPolicyPath

$expectedDevelop = @($contract.required_status_checks.$DevelopBranchName)
$expectedRelease = @($contract.required_status_checks.$ReleaseBranchName)
$checkContext = [string]$contract.check_context
$checkContextRequiredInBranchProtection = $true
if ($contract.PSObject.Properties.Name -contains 'require_check_context_in_branch_protection') {
  $checkContextRequiredInBranchProtection = [bool]$contract.require_check_context_in_branch_protection
}

$developBranchChecks = @($branchPolicy.branches.$DevelopBranchName)
$releaseBranchChecks = @($branchPolicy.branches.$ReleaseBranchName)
$developPriorityChecks = @($priorityPolicy.branches.$DevelopBranchName.required_status_checks)
$releasePriorityChecks = @($priorityPolicy.branches.$ReleaseBranchName.required_status_checks)
$developRulesetChecks = @(Resolve-RulesetRequiredChecks -PriorityPolicy $priorityPolicy -Candidates @($DevelopRulesetId, '8811898'))
$releaseRulesetChecks = @($priorityPolicy.rulesets.$ReleaseRulesetId.required_status_checks)

$comparisons = [ordered]@{
  contract_vs_branch_develop = Compare-CheckSets -Expected $expectedDevelop -Actual $developBranchChecks
  contract_vs_branch_release = Compare-CheckSets -Expected $expectedRelease -Actual $releaseBranchChecks
  contract_vs_priority_develop = Compare-CheckSets -Expected $expectedDevelop -Actual $developPriorityChecks
  contract_vs_priority_release = Compare-CheckSets -Expected $expectedRelease -Actual $releasePriorityChecks
  contract_vs_ruleset_develop = Compare-CheckSets -Expected $expectedDevelop -Actual $developRulesetChecks
  contract_vs_ruleset_release = Compare-CheckSets -Expected $expectedRelease -Actual $releaseRulesetChecks
}

$allOk = $true
foreach ($entry in $comparisons.GetEnumerator()) {
  if (-not $entry.Value.ok) {
    $allOk = $false
    break
  }
}

$expectedDevelopNorm = Normalize-CheckList -Value $expectedDevelop
$expectedReleaseNorm = Normalize-CheckList -Value $expectedRelease
$checkContextPresent = (($checkContext -in $expectedDevelopNorm) -and ($checkContext -in $expectedReleaseNorm))
if ($checkContextRequiredInBranchProtection -and -not $checkContextPresent) {
  $allOk = $false
}

$summary = [ordered]@{
  schema = 'promotion-contract-alignment/v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  contractPath = $ContractPath
  checkContext = $checkContext
  checkContextRequiredInBranchProtection = $checkContextRequiredInBranchProtection
  checkContextPresent = $checkContextPresent
  result = if ($allOk) { 'ok' } else { 'fail' }
  comparisons = $comparisons
}

$outDir = Split-Path -Parent $OutputJsonPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputJsonPath -NoNewline

if ($StepSummaryPath) {
  $lines = @(
    '## Promotion Contract Alignment',
    '',
    ('- Contract path: `{0}`' -f $ContractPath),
    ('- Check context: `{0}`' -f $checkContext),
    ('- Result: **{0}**' -f $summary.result),
    ('- Evidence: `{0}`' -f $OutputJsonPath)
  )
  Add-Content -LiteralPath $StepSummaryPath -Value ($lines -join [Environment]::NewLine)
}

if (-not $allOk) {
  throw "Promotion contract alignment failed. See $OutputJsonPath for details."
}

Write-Host ("[promotion-contract] alignment OK ({0})" -f $checkContext) -ForegroundColor Green
