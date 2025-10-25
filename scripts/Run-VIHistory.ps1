param(
  [Parameter(Mandatory = $true)]
  [string]$ViPath,
  [string]$StartRef = 'HEAD',
  [int]$MaxPairs = 10,
  [switch]$HtmlReport = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$historyResultsDir = Join-Path $repoRoot 'tests' 'results' 'ref-compare' 'history'

Push-Location $repoRoot
try {
  $repoRelativePath = ($ViPath -replace '\\','/').Trim('/')
  $refToCheck = if ([string]::IsNullOrWhiteSpace($StartRef)) { 'HEAD' } else { $StartRef }

  & git --no-pager cat-file -e "${refToCheck}:${repoRelativePath}" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "VI '$ViPath' was not found at ref '$refToCheck'. Choose a commit/branch where the file exists."
    return
  }

  try {
    pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Compare-VIHistory.ps1') `
      -TargetPath $ViPath `
      -StartRef $StartRef `
      -MaxPairs $MaxPairs `
      -Detailed `
      -RenderReport:$HtmlReport.IsPresent
  } catch {
    Write-Error "Compare-VIHistory.ps1 failed. Confirm '$ViPath' exists across the selected history range. Details: $($_.Exception.Message)"
    return
  }

  $manifestPath = Join-Path $historyResultsDir 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Warning "Manifest not generated at expected path: $manifestPath"
    return
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 8
  if (-not $manifest.PSObject.Properties['modes']) {
    Write-Warning 'History manifest does not contain mode data; skipping summary preview.'
    return
  }

  $modeSummaryJson = ($manifest.modes | ConvertTo-Json -Depth 4)

  pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'Publish-VICompareSummary.ps1') `
    -ManifestPath $manifestPath `
    -ModeSummaryJson $modeSummaryJson `
    -Issue 0 `
    -DryRun
} finally {
  Pop-Location
}
