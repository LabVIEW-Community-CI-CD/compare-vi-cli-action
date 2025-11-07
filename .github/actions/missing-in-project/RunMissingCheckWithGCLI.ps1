#Runs MissingInProjectCLI.vi via g-cli.
#Leaves exit status in $LASTEXITCODE for caller.
#NOTE: g-cli must be available and configured for the requested LabVIEW version.

#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LVVersion,
    [Parameter(Mandatory)][ValidateSet('32','64')][string]$Arch,
    [Parameter(Mandatory)][string]$ProjectFile
)

$ErrorActionPreference = 'Stop'
Write-Host "==> [g-cli] Starting Missing-in-Project check ..."

$viPath = Join-Path -Path $PSScriptRoot -ChildPath 'MissingInProjectCLI.vi'
if (-not (Test-Path $viPath)) {
    Write-Host "!! VI not found: $viPath"
    $global:LASTEXITCODE = 2
    return
}
if (-not (Test-Path $ProjectFile)) {
    Write-Host "!! Project file not found: $ProjectFile"
    $global:LASTEXITCODE = 3
    return
}

Write-Host "   VI Path      : $viPath"
Write-Host "   Project File : $ProjectFile"
Write-Host "   LabVIEW Ver  : $LVVersion ($Arch-bit)"
Write-Host "--------------------------------------------------"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Import-Module (Join-Path $repoRoot 'tools' 'VendorTools.psm1') -Force

$gCliPath = Resolve-GCliPath
if (-not $gCliPath) {
    Write-Host "!! g-cli executable not found. Configure GCLI_EXE_PATH or labview-paths*.json."
    $global:LASTEXITCODE = 127
    return
}
$gCliPath = (Resolve-Path -LiteralPath $gCliPath).Path
Write-Host "   CLI Path     : $gCliPath"

$cliArgs = @('--lv-ver', $LVVersion, '--arch', $Arch, '-v', $viPath, '--', $ProjectFile)
$cliOutput = & $gCliPath @cliArgs 2>&1 | Tee-Object -Variable _outLines
$exitCode = $LASTEXITCODE

$cliOutput | ForEach-Object { Write-Output $_ }

if ($exitCode -eq 0) {
    Write-Host "==> Missing-in-Project check passed (no missing files)."
} else {
    Write-Host "==> Missing-in-Project check FAILED - exit code $exitCode"
}

$global:LASTEXITCODE = $exitCode
