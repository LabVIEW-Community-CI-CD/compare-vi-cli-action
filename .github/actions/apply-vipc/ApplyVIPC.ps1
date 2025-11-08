#Requires -Version 7.0

[CmdletBinding()]
param (
    [string]$MinimumSupportedLVVersion,
    [string]$VIP_LVVersion,
    [string]$SupportedBitness,
    [string]$RelativePath,
    [string]$VIPCPath,
    [switch]$DisplayOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'ApplyVIPC.ps1 is deprecated. Use tools/icon-editor/Invoke-VipmDependencies.ps1 directly when scripting locally.'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..')).Path
$helperPath = Join-Path $repoRoot 'tools\icon-editor\Invoke-VipmDependencies.ps1'

if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
    throw "Unable to locate helper script at '$helperPath'."
}

$bitnessList = @()
if ($SupportedBitness) {
    $bitnessList = $SupportedBitness -split '[,\s]+' | Where-Object { $_ }
}
if (-not $bitnessList) {
    $bitnessList = @('64')
}

& $helperPath `
    -MinimumSupportedLVVersion $MinimumSupportedLVVersion `
    -VIP_LVVersion $VIP_LVVersion `
    -SupportedBitness $bitnessList `
    -RelativePath ($RelativePath ?? $repoRoot) `
    -VIPCPath $VIPCPath `
    -DisplayOnly:$DisplayOnly
