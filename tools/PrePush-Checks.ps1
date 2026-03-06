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

$root = (Get-RepoRoot).Path
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

$skipNiImageChecks = $SkipNiImageFlagScenarios `
  -or $SkipIconEditorFixtureChecks `
  -or ($env:PREPUSH_SKIP_NI_IMAGE_FLAG_SCENARIOS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_LEGACY_FIXTURE_CHECKS -match '^(1|true|yes|on)$') `
  -or ($env:PREPUSH_SKIP_ICON_EDITOR_FIXTURE_CHECKS -match '^(1|true|yes|on)$')
if ($skipNiImageChecks) {
  Write-Host '[pre-push] Skipping NI image known-flag scenarios by request' -ForegroundColor Yellow
  return
}

$niFlagTests = Join-Path $root 'tests' 'Run-NIWindowsContainerCompare.Tests.ps1'
if (-not (Test-Path -LiteralPath $niFlagTests -PathType Leaf)) {
  throw ("NI image flag scenario tests not found: {0}" -f $niFlagTests)
}

function Get-CachedPesterV5Manifest {
  param([Parameter(Mandatory)][string]$CacheRoot)
  $pesterRoot = Join-Path $CacheRoot 'Pester'
  if (-not (Test-Path -LiteralPath $pesterRoot -PathType Container)) { return $null }

  $candidates = @()
  $manifests = Get-ChildItem -LiteralPath $pesterRoot -Recurse -Filter 'Pester.psd1' -File -ErrorAction SilentlyContinue
  foreach ($manifest in @($manifests)) {
    $versionFolder = Split-Path -Leaf (Split-Path -Parent $manifest.FullName)
    $parsedVersion = [version]'0.0.0'
    if (-not [version]::TryParse($versionFolder, [ref]$parsedVersion)) { continue }
    if ($parsedVersion.Major -lt 5) { continue }
    $candidates += [pscustomobject]@{
      Version = $parsedVersion
      Path = $manifest.FullName
    }
  }

  return $candidates | Sort-Object Version -Descending | Select-Object -First 1
}

$pesterCacheRoot = if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
  Join-Path $env:LOCALAPPDATA 'compare-vi-cli-action\PowerShell\Modules'
} else {
  Join-Path $root '.cache/powershell-modules'
}

$pesterModule = Get-CachedPesterV5Manifest -CacheRoot $pesterCacheRoot
if (-not $pesterModule) {
  if (-not (Get-Command -Name Save-Module -ErrorAction SilentlyContinue)) {
    throw 'PowerShellGet Save-Module is required to provision Pester 5 for pre-push checks.'
  }
  Write-Host ("[pre-push] Caching Pester 5.x under {0}" -f $pesterCacheRoot) -ForegroundColor Cyan
  New-Item -ItemType Directory -Path $pesterCacheRoot -Force | Out-Null
  Save-Module -Name Pester -Path $pesterCacheRoot -RequiredVersion 5.7.1 -Force
  $pesterModule = Get-CachedPesterV5Manifest -CacheRoot $pesterCacheRoot
}
if (-not $pesterModule -or $pesterModule.Version.Major -lt 5) {
  throw 'Pester 5+ is required for NI image known-flag scenario checks.'
}

Write-Host '[pre-push] Verifying NI image known-flag scenarios' -ForegroundColor Cyan
Push-Location $root
try {
  Import-Module $pesterModule.Path -Force
  $config = New-PesterConfiguration
  $config.Run.Path = $niFlagTests
  $config.Run.PassThru = $true
  $config.Run.Exit = $false
  $config.Filter.Tag = @('Unit')
  $result = Invoke-Pester -Configuration $config
  if (-not $result) {
    throw 'Invoke-Pester returned no result object for NI image known-flag scenarios.'
  }
  $failedCount = [int]$result.FailedCount
  if ($failedCount -gt 0) {
    throw ("NI image known-flag scenarios failed (failed={0})." -f $failedCount)
  }
} finally {
  Pop-Location | Out-Null
}
Write-Host '[pre-push] NI image known-flag scenarios OK' -ForegroundColor Green
