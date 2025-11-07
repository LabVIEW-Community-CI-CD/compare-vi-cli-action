<#
.SYNOPSIS
    Gracefully closes a running LabVIEW instance.

.DESCRIPTION
    Utilizes g-cli's QuitLabVIEW command to shut down the specified LabVIEW
    version and bitness, ensuring the application exits cleanly.

.PARAMETER MinimumSupportedLVVersion
    LabVIEW version to close (e.g., "2021").

.PARAMETER SupportedBitness
    Bitness of the LabVIEW instance ("32" or "64").

.EXAMPLE
    .\Close_LabVIEW.ps1 -MinimumSupportedLVVersion "2021" -SupportedBitness "64"
#>
param(
    [string]$MinimumSupportedLVVersion,
    [string]$SupportedBitness
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
$helperPath = Join-Path $repoRoot 'tools' 'Close-LabVIEW.ps1'

if (Test-Path -LiteralPath $helperPath -PathType Leaf) {
    try {
        & $helperPath -MinimumSupportedLVVersion $MinimumSupportedLVVersion -SupportedBitness $SupportedBitness
        exit $LASTEXITCODE
    } catch {
        Write-Warning ("Close-LabVIEW helper failed: {0} (falling back to legacy g-cli path)" -f $_.Exception.Message)
    }
}

$vendorTools = Join-Path $repoRoot 'tools\VendorTools.psm1'
Import-Module $vendorTools -Force

$gCli = Get-Command g-cli -ErrorAction Stop
$args = @('--lv-ver', $MinimumSupportedLVVersion, '--arch', $SupportedBitness, 'QuitLabVIEW')

Write-Output "Executing the following command:"
Write-Output ("{0} {1}" -f $gCli.Source, ($args -join ' '))

$output = & $gCli.Source @args 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    $joinedOutput = $output -join [Environment]::NewLine
    if ($joinedOutput -match 'Timed out waiting for app to connect to g-cli') {
        Write-Warning "Close LabVIEW $MinimumSupportedLVVersion ($SupportedBitness-bit) reported no running instance (g-cli timeout); continuing."
        exit 0
    }
    Write-Error ("Failed to close LabVIEW (exit code {0}). Output:`n{1}" -f $exitCode, $joinedOutput)
    exit $exitCode
}

Write-Host "Close LabVIEW $MinimumSupportedLVVersion ($SupportedBitness-bit)"

