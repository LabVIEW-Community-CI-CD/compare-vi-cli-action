# Runs the unified orchestrated workflow with convenience defaults.
# Usage examples:
#   pwsh -File tools/Dispatch-Orchestrated.ps1 -Strategy matrix -IncludeIntegration true -Ref develop
#   pwsh -File tools/Dispatch-Orchestrated.ps1 -Strategy single -IncludeIntegration true -Ref develop -Open

[CmdletBinding()]param(
  [ValidateSet('matrix','single')][string]$Strategy = 'matrix',
  [bool]$IncludeIntegration = $true,
  [string]$Ref = 'develop',
  [string]$SampleId,
  [switch]$Open,
  [switch]$Watch
)

$ErrorActionPreference = 'Stop'
if (-not $SampleId) { $SampleId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-oc' }
$wf = 'ci-orchestrated.yml'
$inc = if ($IncludeIntegration) { 'true' } else { 'false' }

Write-Host "Dispatching $wf ref=$Ref strategy=$Strategy include_integration=$inc sample_id=$SampleId"

try {
  gh workflow run $wf -r $Ref -f include_integration=$inc -f strategy=$Strategy -f sample_id=$SampleId | Out-Null
} catch {
  Write-Host 'gh workflow run failed; trying REST fallback'
  $repo = $env:GITHUB_REPOSITORY
  if (-not $repo) { $repo = (git config --get remote.origin.url) }
  $payload = @{ ref=$Ref; inputs=@{ include_integration=$inc; strategy=$Strategy; sample_id=$SampleId } } | ConvertTo-Json -Compress
  gh api "repos/$repo/actions/workflows/$wf/dispatches" -X POST -F ref=$Ref -f inputs[include_integration]=$inc -f inputs[strategy]=$Strategy -f inputs[sample_id]=$SampleId | Out-Null
}

Start-Sleep -Seconds 3
$runs = gh run list -w 'CI Orchestrated (deterministic chain)' -b $Ref -L 5
$runs | Write-Host
if ($Open) {
  $id = ($runs | Select-String -Pattern 'workflow_dispatch\s+(\d+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
  if ($id) { gh run view $id --web | Out-Null }
}
if ($Watch) {
  gh run watch | Out-Null
}

