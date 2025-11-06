<#
.SYNOPSIS
    Applies the icon editor runner dependencies using the VIPM CLI.

.EXAMPLE
    .\ApplyVIPC.ps1 -MinimumSupportedLVVersion 2023 -SupportedBitness 64 -RelativePath vendor\icon-editor -VIP_LVVersion 2026
#>

[CmdletBinding()]
param(
    [int]$MinimumSupportedLVVersion,
    [int]$VIP_LVVersion,
    [ValidateSet('32','64')][string]$SupportedBitness,
    [string]$RelativePath,
    [string]$VIPCPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$iconEditorRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
$vipmModule = Join-Path $iconEditorRoot 'tools\Vipm.psm1'
if (-not (Test-Path -LiteralPath $vipmModule -PathType Leaf)) {
    throw "Vipm module not found at '$vipmModule'."
}
Import-Module $vipmModule -Force

if (-not $VIPCPath) {
    $vipcFiles = Get-ChildItem -Path $PSScriptRoot -Filter '*.vipc'
    if ($vipcFiles.Count -eq 0) {
        throw "No .vipc file found in '$PSScriptRoot'."
    }
    if ($vipcFiles.Count -gt 1) {
        throw "Multiple .vipc files found in '$PSScriptRoot'. Specify -VIPCPath."
    }
    $VIPCPath = $vipcFiles[0].FullName
    Write-Verbose "Auto-detected VIPCPath: $VIPCPath"
}

Write-Verbose "Parameters provided:"
Write-Verbose " - MinimumSupportedLVVersion: $MinimumSupportedLVVersion"
Write-Verbose " - VIP_LVVersion:             $VIP_LVVersion"
Write-Verbose " - SupportedBitness:          $SupportedBitness"
Write-Verbose " - RelativePath:              $RelativePath"
Write-Verbose " - VIPCPath:                  $VIPCPath"

try {
    $resolvedWorkspace = if ($RelativePath) {
        (Resolve-Path -Path $RelativePath -ErrorAction Stop).ProviderPath
    } else {
        $iconEditorRoot
    }

    if ([System.IO.Path]::IsPathRooted($VIPCPath)) {
        $resolvedVipcPath = (Resolve-Path -Path $VIPCPath -ErrorAction Stop).ProviderPath
    } else {
        $resolvedVipcPath = (Resolve-Path -Path (Join-Path $resolvedWorkspace $VIPCPath) -ErrorAction Stop).ProviderPath
    }
} catch {
    throw "Error resolving paths. Ensure RelativePath/VIPCPath are valid. Details: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $resolvedVipcPath -PathType Leaf)) {
    throw "The .vipc file does not exist at '$resolvedVipcPath'."
}

Write-Host ("Applying dependencies for LabVIEW {0} ({1}-bit) via VIPM CLI..." -f $VIP_LVVersion, $SupportedBitness)

$invocation = Get-VipmInvocation -Operation 'InstallVipc' -Params @{
    vipcPath       = $resolvedVipcPath
    labviewVersion = $VIP_LVVersion.ToString()
    labviewBitness = $SupportedBitness
}

Write-Host ("Executing: {0} {1}" -f $invocation.Binary, ($invocation.Arguments -join ' '))
$output = & $invocation.Binary @($invocation.Arguments) 2>&1
$exitCode = $LASTEXITCODE

if ($output) {
    $output | ForEach-Object {
        if ($_ -match '^\s*\[WARN\]') {
            Write-Warning $_
        } else {
            Write-Output $_
        }
    }
}

if ($exitCode -ne 0) {
    throw "VIPM CLI exited with code $exitCode while applying '$resolvedVipcPath' for LabVIEW $VIP_LVVersion ($SupportedBitness-bit)."
}

Write-Host ("Successfully applied dependencies to LabVIEW {0} ({1}-bit)." -f $VIP_LVVersion, $SupportedBitness)
