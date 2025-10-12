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
  [bool]$InstallIfMissing = $true
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
    $dl = Join-Path $bin 'dl-actionlint.sh'
    if (Test-Path -LiteralPath $dl -PathType Leaf) {
      Write-Info "Installing actionlint ${version} via dl-actionlint.sh..."
      & bash $dl $version $bin
    } else {
      # Generic fallback using upstream script
      Write-Info "Installing actionlint ${version} via upstream script..."
      $script = "https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash"
      bash -lc "curl -sSL ${script} | bash -s -- ${version} ${bin}"
    }
  }
}

function Invoke-Actionlint([string]$repoRoot){
  $exe = Get-ActionlintPath -repoRoot $repoRoot
  if (-not $exe) {
    if ($InstallIfMissing) {
      Install-Actionlint -repoRoot $repoRoot -version $ActionlintVersion
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
    return $LASTEXITCODE
  } finally {
    Pop-Location | Out-Null
  }
}

$root = (Get-RepoRoot).Path
$code = Invoke-Actionlint -repoRoot $root
if ($code -ne 0) {
  Write-Error "actionlint reported issues (exit=$code)."
  exit $code
}
Write-Host '[pre-push] actionlint OK' -ForegroundColor Green

$manifestScript = Join-Path $root 'tools' 'Validate-CompareReportManifest.ps1'
if (Test-Path -LiteralPath $manifestScript) {
  try {
    & $manifestScript -ResultsDir (Join-Path $root 'tests/results')
    Write-Host '[pre-push] compare-report manifest OK' -ForegroundColor Green
  } catch {
    Write-Error "compare-report manifest validation failed: $($_.Exception.Message)"
    exit 1
  }
}

$reRunScript = Join-Path $root 'tools' 'Append-ReRunHint.ps1'
if (Test-Path -LiteralPath $reRunScript) {
  $summaryPath = Join-Path ([IO.Path]::GetTempPath()) ("prepush-re-run-summary-{0}.md" -f ([Guid]::NewGuid()))
  $repoSlug = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } else { "local/$((Split-Path -Leaf $root))" }
  try {
    & $reRunScript -WorkflowName 'pre-push-smoke' `
                   -RefName 'HEAD' `
                   -SampleId '' `
                   -WorkflowRef "$repoSlug/.github/workflows/pester-reusable.yml@refs/heads/pre-push" `
                   -Repository $repoSlug `
                   -StepSummaryPath $summaryPath
    Write-Host '[pre-push] re-run hint helper OK' -ForegroundColor Green
  } catch {
    Write-Error "Append-ReRunHint smoke failed: $($_.Exception.Message)"
    exit 1
  } finally {
    Remove-Item -LiteralPath $summaryPath -ErrorAction SilentlyContinue
  }
}

# Optional: mini dispatcher smoke (fast path). Enable via PREPUSH_SMOKE=1.
if ($env:PREPUSH_SMOKE -eq '1') {
  try {
    & (Join-Path $root 'tools' 'Quick-DispatcherSmoke.ps1') | Out-Null
    Write-Host '[pre-push] quick dispatcher smoke OK' -ForegroundColor Green
  } catch {
    Write-Error "Quick-DispatcherSmoke failed: $($_.Exception.Message)"
    exit 1
  }
}
