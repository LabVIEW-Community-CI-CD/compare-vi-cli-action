#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Resolve')]
param(
  [Parameter(ParameterSetName = 'Resolve')]
  [string]$Scenario,
  [Parameter(ParameterSetName = 'List')]
  [switch]$ListScenarios,
  [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'GitHubIntake.psm1') -Force

if ($ListScenarios.IsPresent) {
  $result = Get-GitHubIntakeScenarios | ForEach-Object { Resolve-GitHubIntakeRoute -Scenario $_ }
} else {
  if ([string]::IsNullOrWhiteSpace($Scenario)) {
    throw 'Provide -Scenario <name> or use -ListScenarios.'
  }

  $result = Resolve-GitHubIntakeRoute -Scenario $Scenario
}

if ($AsJson.IsPresent) {
  $result | ConvertTo-Json -Depth 8
  return
}

$result
