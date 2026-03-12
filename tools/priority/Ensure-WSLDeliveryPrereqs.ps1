#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [string]$NodeVersion = 'v24.13.1',
  [string]$ReportPath = 'tests/results/_agent/runtime/wsl-delivery-prereqs.json'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$distScript = Join-Path $repoRoot 'dist\tools\priority\delivery-agent.js'
if (-not (Test-Path -LiteralPath $distScript -PathType Leaf)) {
  & node (Join-Path $repoRoot 'tools\npm\run-script.mjs') build
  if ($LASTEXITCODE -ne 0) {
    throw 'TypeScript build failed for delivery-agent prereq wrapper.'
  }
}

& node $distScript prereqs --wsl-distro $Distro --node-version $NodeVersion --report-path $ReportPath
exit $LASTEXITCODE
