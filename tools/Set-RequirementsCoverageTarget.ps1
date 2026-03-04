[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [double]$Percent,
  [string]$PolicyPath = 'tools/policy/requirements-verification-baseline.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Percent -lt 0 -or $Percent -gt 100) {
  throw 'Percent must be between 0 and 100.'
}

if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
  throw "Policy path does not exist: $PolicyPath"
}

$resolvedPolicyPath = (Resolve-Path -LiteralPath $PolicyPath).Path
$policy = Get-Content -LiteralPath $resolvedPolicyPath -Raw | ConvertFrom-Json -Depth 20

if (-not ($policy.PSObject.Properties.Name -contains 'policy') -or -not $policy.policy) {
  $policy | Add-Member -MemberType NoteProperty -Name 'policy' -Value ([pscustomobject]@{}) -Force
}

$policy.policy | Add-Member -MemberType NoteProperty -Name 'minimumRequirementsCoveragePercent' -Value $Percent -Force
$policy | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $resolvedPolicyPath -Encoding utf8

Write-Host ("[requirements-coverage] minimumRequirementsCoveragePercent set to {0} in {1}" -f $Percent, $PolicyPath) -ForegroundColor Cyan
