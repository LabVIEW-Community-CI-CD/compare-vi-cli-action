#Requires -Version 7.0

[CmdletBinding()]
param(
  [int]$MinimumSupportedLVVersion = 2021,
[int]$PackageMinimumSupportedLVVersion = 2023,
  [ValidateSet(32,64)][int]$PackageSupportedBitness = 64,
  [string]$SkipSync,
  [string]$SkipVipcApply,
  [string]$SkipClose,
  [string]$RepoSlug = 'LabVIEW-Community-CI-CD/labview-icon-editor',
  [string]$GhTokenPath,
  [string]$ResultsRootValidate = 'tests/results/_agent/icon-editor/local-validate'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

$repoRoot = Resolve-RepoRoot
Push-Location $repoRoot
try {
  $ts = Get-Date -Format 'yyyyMMddTHHmmssfff'
  $logRoot = Join-Path $repoRoot 'tests\results\_agent\icon-editor\logs'
  if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
  }
  $logPath = Join-Path $logRoot ("oneshot-{0}.log" -f $ts)
  Start-Transcript -Path $logPath -Force | Out-Null

  $env:LV_SUPPRESS_UI = '1'
  $env:LV_NO_ACTIVATE = '1'
  $env:LV_CURSOR_RESTORE = '1'
  $env:LV_IDLE_WAIT_SECONDS = '2'
  $env:LV_IDLE_MAX_WAIT_SECONDS = '5'

  if (Test-Path -LiteralPath 'tools/priority/bootstrap.ps1' -PathType Leaf) {
    pwsh -NoLogo -NoProfile -File 'tools/priority/bootstrap.ps1' | Out-Null
  }
  if (Test-Path -LiteralPath 'tools/Detect-RogueLV.ps1' -PathType Leaf) {
    pwsh -NoLogo -NoProfile -File 'tools/Detect-RogueLV.ps1' -FailOnRogue | Out-Null
  }

  if ($GhTokenPath -and (Test-Path -LiteralPath $GhTokenPath -PathType Leaf)) {
    try { $env:GH_TOKEN = Get-Content -LiteralPath $GhTokenPath -Raw } catch {}
  }

  $skipSyncFlag   = ($SkipSync) -and ($SkipSync.Trim().ToLower() -eq 'yes')
  $skipApplyFlag  = ($SkipVipcApply) -and ($SkipVipcApply.Trim().ToLower() -eq 'yes')
  $skipCloseFlag  = ($SkipClose) -and ($SkipClose.Trim().ToLower() -eq 'yes')

  $buildArgs = @(
    '-RepoSlug', $RepoSlug,
    '-MinimumSupportedLVVersion', "$MinimumSupportedLVVersion",
    '-PackageMinimumSupportedLVVersion', "$PackageMinimumSupportedLVVersion",
    '-PackageSupportedBitness', "$PackageSupportedBitness"
  )
  if ($skipSyncFlag)  { $buildArgs += '-SkipSync' }
  if ($skipApplyFlag) { $buildArgs += '-SkipVipcApply' }
  if ($skipCloseFlag) { $buildArgs += '-SkipClose' }

  pwsh -NoLogo -NoProfile -File 'tools/icon-editor/Invoke-VipmCliBuild.ps1' @buildArgs
  $vipmExit = $LASTEXITCODE
  if ($vipmExit -ne 0) {
    throw "Invoke-VipmCliBuild.ps1 failed with exit code $vipmExit. See transcript $logPath for details."
  }

  pwsh -NoLogo -NoProfile -File 'tools/icon-editor/Invoke-IconEditorBuild.ps1' `
    -RunUnitTests `
    -SkipPackaging `
    -ResultsRoot $ResultsRootValidate
  $unitExit = $LASTEXITCODE
  if ($unitExit -ne 0) {
    throw "Invoke-IconEditorBuild.ps1 (unit tests) failed with exit code $unitExit. See transcript $logPath for details."
  }

  if (Test-Path -LiteralPath 'tools/Detect-RogueLV.ps1' -PathType Leaf) {
    pwsh -NoLogo -NoProfile -File 'tools/Detect-RogueLV.ps1' | Out-Null
  }

  $resultsIndex = Join-Path $repoRoot 'tests\results\results-index.html'
  if (Test-Path -LiteralPath $resultsIndex -PathType Leaf) {
    try { Start-Process $resultsIndex } catch {}
  }
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
  try {
    if ($logPath -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
      $resolvedLog = (Resolve-Path -LiteralPath $logPath).Path
      $pointerFile = Join-Path (Split-Path -Parent $logPath) 'latest-logpath.txt'
      Set-Content -LiteralPath $pointerFile -Value $resolvedLog -Encoding UTF8 -Force
      Write-Host ("Transcript log: {0}" -f $resolvedLog)
    }
  } catch {}
  Pop-Location
}


