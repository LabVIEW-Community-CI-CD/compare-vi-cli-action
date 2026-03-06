#Requires -Version 7.0
<#
.SYNOPSIS
  Local pre-push checks: run actionlint against workflows.
.DESCRIPTION
  Ensures a valid actionlint binary is used per-OS and runs it against .github/workflows.
  On Windows, explicitly prefers bin/actionlint.exe to avoid invoking the non-Windows binary.
.PARAMETER ActionlintVersion
  Optional version to install if missing (default: 1.7.7). Only used when auto-installing.
.PARAMETER InstallIfMissing
  Attempt to install actionlint if not found (default: true).
#>
param(
  [string]$ActionlintVersion = '1.7.7',
  [bool]$InstallIfMissing = $true,
  [switch]$SkipNiImageFlagScenarios,
  [switch]$SkipIconEditorFixtureChecks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'VendorTools.psm1') -Force

function Write-Info([string]$msg){ Write-Host $msg -ForegroundColor DarkGray }

function Get-RepoRoot {
  $here = Split-Path -Parent $PSCommandPath
  return (Resolve-Path -LiteralPath (Join-Path $here '..'))
}

function Get-ActionlintPath([string]$repoRoot){ return Resolve-ActionlintPath }

function Install-Actionlint([string]$repoRoot,[string]$version){
  $bin = Join-Path $repoRoot 'bin'
  if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Force -Path $bin | Out-Null }

  if ($IsWindows) {
    # Determine arch
    $arch = ($env:PROCESSOR_ARCHITECTURE ?? 'AMD64').ToUpperInvariant()
    $asset = if ($arch -like '*ARM64*') { "actionlint_${version}_windows_arm64.zip" } else { "actionlint_${version}_windows_amd64.zip" }
    $url = "https://github.com/rhysd/actionlint/releases/download/v${version}/${asset}"
    $zip = Join-Path $bin 'actionlint.zip'
    Write-Info "Downloading actionlint ${version} (${asset})..."
    try {
      Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $bin, $true)
    } finally { if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue } }
  } else {
    # Try vendored downloader if available
  $dlCandidates = @(
    (Join-Path -Path $bin -ChildPath 'dl-actionlint.sh'),
    (Join-Path -Path $repoRoot -ChildPath 'tools/dl-actionlint.sh')
  )
  $dl = $dlCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
  if ($dl) {
    Write-Info "Installing actionlint ${version} via dl-actionlint.sh (${dl})..."
    & bash $dl $version $bin
  } else {
      # Generic fallback using upstream script
      Write-Info "Installing actionlint ${version} via upstream script..."
      $script = "https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash"
      bash -lc "curl -sSL ${script} | bash -s -- ${version} ${bin}"
    }
  }
}

function Invoke-NodeTestSanitized {
  param(
    [string[]]$Args
  )

  $output = & node @Args 2>&1
  $exitCode = $LASTEXITCODE
  if ($output) {
    $normalized = $output | ForEach-Object {
      $_ -replace 'duration_ms: \d+(?:\.\d+)?', 'duration_ms: <sanitized>' -replace '# duration_ms \d+(?:\.\d+)?', '# duration_ms <sanitized>'
    }
    $normalized | ForEach-Object { Write-Host $_ }
  }
  return $exitCode
}

function Invoke-Actionlint([string]$repoRoot){
  $exe = Get-ActionlintPath -repoRoot $repoRoot
  if (-not $exe) {
    if ($InstallIfMissing) {
      Install-Actionlint -repoRoot $repoRoot -version $ActionlintVersion | Out-Null
      $exe = Get-ActionlintPath -repoRoot $repoRoot
    }
  }
  if (-not $exe) { throw "actionlint not found after attempted install under '${repoRoot}/bin'" }

  # Explicitly resolve .exe on Windows to avoid picking the non-Windows binary
  if ($IsWindows -and (Split-Path -Leaf $exe) -eq 'actionlint') {
    $winExe = Join-Path (Split-Path -Parent $exe) 'actionlint.exe'
    if (Test-Path -LiteralPath $winExe -PathType Leaf) { $exe = $winExe }
  }

  Write-Host "[pre-push] Running: $exe -color" -ForegroundColor Cyan
  Push-Location $repoRoot
  try {
    & $exe -color
    return [int]$LASTEXITCODE
  } finally {
    Pop-Location | Out-Null
  }
}

function Invoke-WorkspaceHealthGate([string]$repoRoot){
  $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'check-workspace-health.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw ("workspace health gate script not found: {0}" -f $scriptPath)
  }

  $reportPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'health' 'pre-push-workspace-health.json'
  Write-Host '[pre-push] Verifying workspace health gate' -ForegroundColor Cyan
  & node $scriptPath `
    --repo-root $repoRoot `
    --report $reportPath `
    --lease-mode optional
  if ($LASTEXITCODE -ne 0) {
    throw ("workspace health gate failed (exit={0}). See {1}" -f $LASTEXITCODE, $reportPath)
  }
  Write-Host '[pre-push] workspace health gate OK' -ForegroundColor Green
}

function Invoke-SafeGitReliabilitySummary([string]$repoRoot){
  $scriptPath = Join-Path $repoRoot 'tools' 'priority' 'summarize-safe-git-telemetry.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw ("safe-git reliability summary script not found: {0}" -f $scriptPath)
  }

  $inputPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'reliability' 'safe-git-events.jsonl'
  $outputPath = Join-Path $repoRoot 'tests' 'results' '_agent' 'reliability' 'safe-git-trend-summary.json'
  Write-Host '[pre-push] Summarizing safe-git reliability telemetry' -ForegroundColor Cyan
  $args = @(
    $scriptPath,
    '--input', $inputPath,
    '--output', $outputPath
  )
  if ($env:GITHUB_STEP_SUMMARY) {
    $args += @('--step-summary', $env:GITHUB_STEP_SUMMARY)
  }
  & node @args
  if ($LASTEXITCODE -ne 0) {
    throw ("safe-git reliability summary failed (exit={0})." -f $LASTEXITCODE)
  }
  Write-Host '[pre-push] safe-git reliability summary OK' -ForegroundColor Green
}

$root = (Get-RepoRoot).Path
Invoke-WorkspaceHealthGate -repoRoot $root
$guardScript = Join-Path (Split-Path -Parent $PSCommandPath) 'Assert-NoAmbiguousRemoteRefs.ps1'

Push-Location $root
try {
  Write-Host '[pre-push] Verifying remote refs are unambiguous' -ForegroundColor Cyan
  & $guardScript
  Write-Host '[pre-push] remote references OK' -ForegroundColor Green
} finally {
  Pop-Location | Out-Null
}

$code = Invoke-Actionlint -repoRoot $root
if ($code -ne 0) {
  Write-Error "actionlint reported issues (exit=$code)."
  exit $code
}
Write-Host '[pre-push] actionlint OK' -ForegroundColor Green

Write-Host '[pre-push] Validating safe PR watch task contract' -ForegroundColor Cyan
$safeWatchContractExit = Invoke-NodeTestSanitized -Args @('--test','tools/priority/__tests__/safe-watch-task-contract.test.mjs')
if ($safeWatchContractExit -ne 0) {
  throw "safe-watch task contract validation failed (exit=$safeWatchContractExit)."
}
Write-Host '[pre-push] safe-watch task contract OK' -ForegroundColor Green

$verificationContractScript = Join-Path $root 'tools' 'Assert-RequirementsVerificationCheckContract.ps1'
if (Test-Path -LiteralPath $verificationContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying requirements-verification check naming contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $verificationContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-RequirementsVerificationCheckContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] requirements-verification check contract OK' -ForegroundColor Green
}

$policyGuardContractScript = Join-Path $root 'tools' 'Assert-PolicyGuardCheckContract.ps1'
if (Test-Path -LiteralPath $policyGuardContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying policy-guard check naming contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $policyGuardContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-PolicyGuardCheckContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] policy-guard check contract OK' -ForegroundColor Green
}

$commitIntegrityContractScript = Join-Path $root 'tools' 'Assert-CommitIntegrityContract.ps1'
if (Test-Path -LiteralPath $commitIntegrityContractScript -PathType Leaf) {
  Write-Host '[pre-push] Verifying commit-integrity contract' -ForegroundColor Cyan
  Push-Location $root
  try {
    pwsh -NoLogo -NonInteractive -NoProfile -File $commitIntegrityContractScript
    if ($LASTEXITCODE -ne 0) {
      throw "Assert-CommitIntegrityContract.ps1 failed (exit=$LASTEXITCODE)."
    }
  } finally {
    Pop-Location | Out-Null
  }
  Write-Host '[pre-push] commit-integrity contract OK' -ForegroundColor Green
}

Invoke-SafeGitReliabilitySummary -repoRoot $root

$skipNiImageChecks = $SkipNiImageFlagScenarios `
  -or $SkipIconEditorFixtureChecks `
  -or ($env:PREPUSH_SKIP_NI_IMAGE_FLAG_SCENARIOS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_LEGACY_FIXTURE_CHECKS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_ICON_EDITOR_FIXTURE_CHECKS -match '^(1|true|yes|on)$')
if ($skipNiImageChecks) {
  Write-Host '[pre-push] Skipping NI image known-flag scenarios by request' -ForegroundColor Yellow
  return
}

$niCompareScript = Join-Path $root 'tools' 'Run-NIWindowsContainerCompare.ps1'
if (-not (Test-Path -LiteralPath $niCompareScript -PathType Leaf)) {
  throw ("NI image compare script not found: {0}" -f $niCompareScript)
}
$baseVi = Join-Path $root 'VI1.vi'
$headVi = Join-Path $root 'VI2.vi'
if (-not (Test-Path -LiteralPath $baseVi -PathType Leaf)) {
  throw ("Base VI not found for NI image known-flag scenario: {0}" -f $baseVi)
}
if (-not (Test-Path -LiteralPath $headVi -PathType Leaf)) {
  throw ("Head VI not found for NI image known-flag scenario: {0}" -f $headVi)
}

$expectedImage = 'nationalinstruments/labview:2026q1-windows'
$knownFlags = @('-noattr', '-nofppos', '-nobdcosm')
$scenarioDir = Join-Path $root 'tests' 'results' '_agent' 'pre-push-ni-image'
New-Item -ItemType Directory -Path $scenarioDir -Force | Out-Null
$reportPath = Join-Path $scenarioDir 'compare-report.html'
$runtimeSnapshotPath = Join-Path $scenarioDir 'runtime-determinism.json'

Write-Host '[pre-push] Running NI image known-flag scenario (real container compare)' -ForegroundColor Cyan
Push-Location $root
try {
  pwsh -NoLogo -NoProfile -File $niCompareScript `
    -BaseVi $baseVi `
    -HeadVi $headVi `
    -Image $expectedImage `
    -ReportPath $reportPath `
    -Flags $knownFlags `
    -TimeoutSeconds 240 `
    -HeartbeatSeconds 15 `
    -AutoRepairRuntime:$true `
    -ManageDockerEngine:$false `
    -RuntimeEngineReadyTimeoutSeconds 120 `
    -RuntimeEngineReadyPollSeconds 3 `
    -RuntimeSnapshotPath $runtimeSnapshotPath
  $compareExit = $LASTEXITCODE
  if ($compareExit -ne 0) {
    throw ("NI image known-flag scenario compare failed (exit={0})." -f $compareExit)
  }
} finally {
  Pop-Location | Out-Null
}

$capturePath = Join-Path $scenarioDir 'ni-windows-container-capture.json'
if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
  throw ("NI image known-flag scenario capture missing: {0}" -f $capturePath)
}
$capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 20
$gateOutcome = if ($capture.PSObject.Properties['gateOutcome']) { [string]$capture.gateOutcome } else { '' }
$resultClass = if ($capture.PSObject.Properties['resultClass']) { [string]$capture.resultClass } else { '' }
$imageUsed = if ($capture.PSObject.Properties['image']) { [string]$capture.image } else { '' }
$commandText = if ($capture.PSObject.Properties['command']) { [string]$capture.command } else { '' }
$flagsUsed = @()
if ($capture.PSObject.Properties['flags'] -and $capture.flags) {
  $flagsUsed = @($capture.flags | ForEach-Object { [string]$_ })
}

if (-not [string]::Equals($imageUsed, $expectedImage, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("NI image known-flag scenario used unexpected image: {0}" -f $imageUsed)
}
if (-not [string]::Equals($gateOutcome, 'pass', [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("NI image known-flag scenario did not pass (resultClass={0}, gateOutcome={1})." -f $resultClass, $gateOutcome)
}
if ([string]::IsNullOrWhiteSpace($commandText) -or $commandText -notmatch '(?i)docker run') {
  throw 'NI image known-flag scenario did not emit a docker run command in capture evidence.'
}
foreach ($flag in $knownFlags) {
  if ($flagsUsed -notcontains $flag) {
    throw ("NI image known-flag scenario missing expected flag in capture: {0}" -f $flag)
  }
}
if ($flagsUsed -notcontains '-Headless') {
  throw 'NI image known-flag scenario missing enforced -Headless flag in capture.'
}

if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @(
    '### Pre-push NI Image Scenario',
    '',
    ('- image: `{0}`' -f $imageUsed),
    ('- resultClass: `{0}`' -f $resultClass),
    ('- gateOutcome: `{0}`' -f $gateOutcome),
    ('- flags: `{0}`' -f [string]::Join(', ', $flagsUsed)),
    ('- capture: `{0}`' -f $capturePath),
    ('- report: `{0}`' -f $reportPath)
  )
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
Write-Host '[pre-push] NI image known-flag scenarios OK' -ForegroundColor Green
