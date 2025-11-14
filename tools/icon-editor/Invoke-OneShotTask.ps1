#Requires -Version 7.0
[CmdletBinding()]
param(
  [ValidateSet('Fast','Robust')]
  [string]$Preset = 'Fast',
  [int]$MinimumSupportedLVVersion = 2021,
[int]$PackageMinimumSupportedLVVersion = 2023,
  [ValidateSet(32,64)][int]$PackageSupportedBitness = 64,
  [string]$GhTokenPath = 'C:\github_token.txt',
  [string]$RepoSlug = 'LabVIEW-Community-CI-CD/labview-icon-editor',
  [string]$ResultsRootValidate = 'tests/results/_agent/icon-editor/local-validate',
  [switch]$PublishArtifacts,
  [switch]$SkipUpload
)

<#
.SYNOPSIS
Runs the common VS Code icon-editor one-shot task from the CLI.

.DESCRIPTION
The VS Code tasks “IconEditor: One-shot (Fast path)” and
“IconEditor: Build + Unit Tests (One-shot, Robust)” both shell into
`tools/icon-editor/Run-OneShotBuildAndTests.ps1` with slightly different
arguments.  Iterating on those tasks outside the editor required copying
their command line or re-triggering the task palette each time.

This helper mirrors those task presets so you can do:

```
pwsh -File tools/icon-editor/Invoke-OneShotTask.ps1 -Preset Robust
```

and the script will invoke the same pipeline the VS Code task would have
run.  Pass `-PublishArtifacts` to automatically zip (and optionally upload)
the freshly produced VIP/PPL files after the build completes.
#>

function Resolve-RepoRoot {
  param([string]$Start = (Get-Location).Path)
  try {
    $resolved = git -C $Start rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
      return $resolved.Trim()
    }
  } catch {}
  return (Resolve-Path -LiteralPath $Start).Path
}

$repoRoot = Resolve-RepoRoot
$oneShotScript = Join-Path $repoRoot 'tools/icon-editor/Run-OneShotBuildAndTests.ps1'
if (-not (Test-Path -LiteralPath $oneShotScript -PathType Leaf)) {
  throw "Unable to locate Run-OneShotBuildAndTests.ps1 at '$oneShotScript'."
}

$skipSyncValue = ''
$skipApplyValue = ''
$skipCloseValue = ''
switch ($Preset) {
  'Fast'   { $skipSyncValue = 'yes'; $skipApplyValue = 'yes' }
  'Robust' { }
}

$oneShotArgs = @(
  '-MinimumSupportedLVVersion', "$MinimumSupportedLVVersion",
  '-PackageMinimumSupportedLVVersion', "$PackageMinimumSupportedLVVersion",
  '-PackageSupportedBitness', "$PackageSupportedBitness",
  '-RepoSlug', $RepoSlug,
  '-ResultsRootValidate', $ResultsRootValidate,
  '-SkipSync', $skipSyncValue,
  '-SkipVipcApply', $skipApplyValue,
  '-SkipClose', $skipCloseValue
)
if ($GhTokenPath) {
  $oneShotArgs += @('-GhTokenPath', $GhTokenPath)
}

Write-Host ("[OneShot] Preset: {0} (LV {1} / Pkg {2}-{3}-bit)" -f $Preset, $MinimumSupportedLVVersion, $PackageMinimumSupportedLVVersion, $PackageSupportedBitness) -ForegroundColor Cyan
& pwsh -NoLogo -NoProfile -File $oneShotScript @oneShotArgs
$oneShotExit = $LASTEXITCODE
if ($oneShotExit -ne 0) {
  throw "Run-OneShotBuildAndTests.ps1 exited with $oneShotExit."
}

if ($PublishArtifacts) {
  $publishScript = Join-Path $repoRoot 'tools/icon-editor/Publish-LocalArtifacts.ps1'
  if (-not (Test-Path -LiteralPath $publishScript -PathType Leaf)) {
    throw "Publish-LocalArtifacts.ps1 not found at '$publishScript'."
  }

  $publishArgs = @()
  if ($GhTokenPath) { $publishArgs += @('-GhTokenPath', $GhTokenPath) }
  if ($SkipUpload)  { $publishArgs += '-SkipUpload' }

  Write-Host "[OneShot] Packaging local artifacts..." -ForegroundColor Cyan
  & pwsh -NoLogo -NoProfile -File $publishScript @publishArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Publish-LocalArtifacts.ps1 exited with $LASTEXITCODE."
  }
}
