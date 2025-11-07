#Requires -Version 7.0

[CmdletBinding()]
param (
    [string]$MinimumSupportedLVVersion,
    [string]$VIP_LVVersion,
    [string]$SupportedBitness,
    [string]$RelativePath = (Resolve-Path '.').ProviderPath,
    [string]$VIPCPath,
    [switch]$DisplayOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperModule = Join-Path $PSScriptRoot 'VipmDependencyHelpers.psm1'
if (-not (Test-Path -LiteralPath $helperModule -PathType Leaf)) {
    throw "VipmDependencyHelpers.psm1 not found at '$helperModule'."
}
Import-Module $helperModule -Force

Write-Verbose "Parameters:"
Write-Verbose " - MinimumSupportedLVVersion: $MinimumSupportedLVVersion"
Write-Verbose " - VIP_LVVersion:             $VIP_LVVersion"
Write-Verbose " - SupportedBitness:          $SupportedBitness"
Write-Verbose " - RelativePath:              $RelativePath"
Write-Verbose " - VIPCPath:                  $VIPCPath"
Write-Verbose " - DisplayOnly:               $($DisplayOnly.IsPresent)"

$ResolvedRelativePath = (Resolve-Path -Path $RelativePath -ErrorAction Stop).ProviderPath

if (-not $DisplayOnly) {
    if (-not $VIPCPath) {
        $vipcFiles = @(Get-ChildItem -Path $ResolvedRelativePath -Filter *.vipc)
        if ($vipcFiles.Count -eq 0) {
            throw "No .vipc file found in '$ResolvedRelativePath'."
        }
        if ($vipcFiles.Count -gt 1) {
            throw "Multiple .vipc files found in '$ResolvedRelativePath'. Specify -VIPCPath."
        }
        $VIPCPath = $vipcFiles[0].FullName
    } elseif (-not [System.IO.Path]::IsPathRooted($VIPCPath)) {
        $VIPCPath = (Resolve-Path -Path (Join-Path $ResolvedRelativePath $VIPCPath) -ErrorAction Stop).ProviderPath
    } else {
        $VIPCPath = (Resolve-Path -Path $VIPCPath -ErrorAction Stop).ProviderPath
    }
    if (-not (Test-Path -LiteralPath $VIPCPath -PathType Leaf)) {
        throw "The .vipc file does not exist at '$VIPCPath'."
    }
}

$vipmModulePath = Join-Path $ResolvedRelativePath 'tools' 'Vipm.psm1'
if (-not (Test-Path -LiteralPath $vipmModulePath -PathType Leaf)) {
    throw "VIPM module not found at '$vipmModulePath'."
}
Import-Module $vipmModulePath -Force

$versionsToApply = [System.Collections.Generic.List[string]]::new()
$versionsToApply.Add([string]$MinimumSupportedLVVersion) | Out-Null
if ($VIP_LVVersion -and ($VIP_LVVersion -ne $MinimumSupportedLVVersion)) {
    $versionsToApply.Add([string]$VIP_LVVersion) | Out-Null
}
$uniqueVersions = $versionsToApply | Select-Object -Unique

$vipmTelemetryRoot = Initialize-VipmTelemetry -RepoRoot $ResolvedRelativePath
$collectedPackages = New-Object System.Collections.Generic.List[object]

foreach ($version in $uniqueVersions) {
    Test-VipmCliReady -LabVIEWVersion $version -LabVIEWBitness $SupportedBitness -RepoRoot $ResolvedRelativePath | Out-Null
    if ($DisplayOnly) {
        $collectedPackages.Add((Show-VipmDependencies -LabVIEWVersion $version -LabVIEWBitness $SupportedBitness -TelemetryRoot $vipmTelemetryRoot)) | Out-Null
    } else {
        Write-Output ("Applying dependencies via VIPM for LabVIEW {0} ({1}-bit)..." -f $version, $SupportedBitness)
        $collectedPackages.Add((Install-VipmVipc -VipcPath $VIPCPath -LabVIEWVersion $version -LabVIEWBitness $SupportedBitness -RepoRoot $ResolvedRelativePath -TelemetryRoot $vipmTelemetryRoot)) | Out-Null
    }
}

if ($DisplayOnly) {
    Write-Host 'Displayed VIPM dependencies:'
} else {
    Write-Host 'Successfully applied dependencies using VIPM CLI.'
}

Write-Host '=== VIPM Packages ==='
foreach ($entry in $collectedPackages) {
    Write-Host ("LabVIEW {0} ({1}-bit)" -f $entry.version, $entry.bitness)
    foreach ($pkg in $entry.packages) {
        Write-Host ("  - {0} ({1}) v{2}" -f $pkg.name, $pkg.identifier, $pkg.version)
    }
}
