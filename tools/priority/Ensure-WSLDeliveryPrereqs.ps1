#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [string]$NodeVersion = 'v24.13.1',
  [string]$ReportPath = 'tests/results/_agent/runtime/wsl-delivery-prereqs.json'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeliveryAgentWrapper.Build.psm1') -Force
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$distScript = Join-Path $repoRoot 'dist\tools\priority\delivery-agent.js'
Initialize-DeliveryAgentDistScript -RepoRoot $repoRoot -DistScript $distScript -WrapperLabel 'delivery-agent prereq wrapper'

& node $distScript prereqs --wsl-distro $Distro --node-version $NodeVersion --report-path $ReportPath
exit $LASTEXITCODE
