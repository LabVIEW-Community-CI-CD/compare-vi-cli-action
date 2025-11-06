<#
.SYNOPSIS
    Updates a VIPB file's display information and builds the VI package.

.DESCRIPTION
    Locates a VIPB file stored alongside this script, merges version details into
    DisplayInformation JSON, and calls the VIPM CLI to create the final VI package.

.PARAMETER SupportedBitness
    LabVIEW bitness for the build ("32" or "64").


.PARAMETER MinimumSupportedLVVersion
    Minimum LabVIEW version supported by the package.

.PARAMETER LabVIEWMinorRevision
    Minor revision number of LabVIEW (0 or 3).

.PARAMETER Major
    Major version component for the package.

.PARAMETER Minor
    Minor version component for the package.

.PARAMETER Patch
    Patch version component for the package.

.PARAMETER Build
    Build number component for the package.

.PARAMETER Commit
    Commit identifier embedded in the package metadata.

.PARAMETER ReleaseNotesFile
    Path to a release notes file injected into the build.

.PARAMETER DisplayInformationJSON
    JSON string representing the VIPB display information to update.

.EXAMPLE
    .\build_vip.ps1 -SupportedBitness "64" -MinimumSupportedLVVersion 2021 -LabVIEWMinorRevision 3 -Major 1 -Minor 0 -Patch 0 -Build 2 -Commit "abcd123" -ReleaseNotesFile "Tooling\deployment\release_notes.md" -DisplayInformationJSON '{"Package Version":{"major":1,"minor":0,"patch":0,"build":2}}'
#>

param (
    [string]$SupportedBitness,

    [int]$MinimumSupportedLVVersion,

    [ValidateSet("0","3")]
    [string]$LabVIEWMinorRevision = "0",

    [int]$Major,
    [int]$Minor,
    [int]$Patch,
    [int]$Build,
    [string]$Commit,
    [string]$ReleaseNotesFile,

    [Parameter(Mandatory=$true)]
    [string]$DisplayInformationJSON
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve repository roots for shared tooling
$actionRoot      = $PSScriptRoot
$repoRoot        = (Resolve-Path (Join-Path $actionRoot '..\..\..\..\..')).ProviderPath
$iconEditorRoot  = (Resolve-Path (Join-Path $repoRoot 'vendor' 'icon-editor')).ProviderPath
$toolsRoot       = Join-Path $repoRoot 'tools'
$vipmModulePath  = Join-Path $iconEditorRoot 'tools' 'Vipm.psm1'
$packageModule   = Join-Path $toolsRoot 'icon-editor' 'IconEditorPackage.psm1'

if (-not (Test-Path -LiteralPath $vipmModulePath -PathType Leaf)) {
    throw "Vipm module not found at '$vipmModulePath'."
}
Import-Module $vipmModulePath -Force

if (-not (Test-Path -LiteralPath $packageModule -PathType Leaf)) {
    throw "IconEditorPackage module not found at '$packageModule'."
}
Import-Module $packageModule -Force

# 1) Locate VIPB file in the action directory
try {
    $vipbFile = Get-ChildItem -Path $PSScriptRoot -Filter *.vipb -ErrorAction Stop | Select-Object -First 1
    if (-not $vipbFile) { throw "No .vipb file found" }
    $ResolvedVIPBPath = $vipbFile.FullName
}
catch {
    $errorObject = [PSCustomObject]@{
        error      = "No .vipb file found in the action directory."
        exception  = $_.Exception.Message
        stackTrace = $_.Exception.StackTrace
    }
    $errorObject | ConvertTo-Json -Depth 10
    exit 1
}

# 2) Create release notes if needed
$resolvedReleaseNotes = if ([System.IO.Path]::IsPathRooted($ReleaseNotesFile)) {
    $ReleaseNotesFile
} else {
    Join-Path $repoRoot $ReleaseNotesFile
}

if (-not (Test-Path $resolvedReleaseNotes)) {
    Write-Host "Release notes file '$resolvedReleaseNotes' does not exist. Creating it..."
    $releaseDir = Split-Path -Parent $resolvedReleaseNotes
    if (-not (Test-Path -LiteralPath $releaseDir -PathType Container)) {
        New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    }
    New-Item -ItemType File -Path $resolvedReleaseNotes -Force | Out-Null
}

# 3) Calculate the LabVIEW version string
$lvNumericMajor    = $MinimumSupportedLVVersion - 2000
$lvNumericVersion  = "$($lvNumericMajor).$LabVIEWMinorRevision"
if ($SupportedBitness -eq "64") {
    $VIP_LVVersion_A = "$lvNumericVersion (64-bit)"
}
else {
    $VIP_LVVersion_A = $lvNumericVersion
}
Write-Output "Building VI Package for LabVIEW $VIP_LVVersion_A..."

# 4) Parse and update the DisplayInformationJSON
try {
    $jsonObj = $DisplayInformationJSON | ConvertFrom-Json
}
catch {
    $errorObject = [PSCustomObject]@{
        error      = "Failed to parse DisplayInformationJSON into valid JSON."
        exception  = $_.Exception.Message
        stackTrace = $_.Exception.StackTrace
    }
    $errorObject | ConvertTo-Json -Depth 10
    exit 1
}

# If "Package Version" doesn't exist, create it as a subobject
if (-not $jsonObj.'Package Version') {
    $jsonObj | Add-Member -MemberType NoteProperty -Name 'Package Version' -Value ([PSCustomObject]@{
        major = $Major
        minor = $Minor
        patch = $Patch
        build = $Build
    })
}
else {
    # "Package Version" exists, so just overwrite its fields
    $jsonObj.'Package Version'.major = $Major
    $jsonObj.'Package Version'.minor = $Minor
    $jsonObj.'Package Version'.patch = $Patch
    $jsonObj.'Package Version'.build = $Build
}

# Re-convert to a JSON string with a comfortable nesting depth
$UpdatedDisplayInformationJSON = $jsonObj | ConvertTo-Json -Depth 5

# 5) Invoke the VIPM CLI build
$bitnessValue = [int]$SupportedBitness
$labviewMinor = [int]$LabVIEWMinorRevision

Write-Output "Invoking VIPM CLI build for $MinimumSupportedLVVersion ($SupportedBitness-bit)..."

try {
    $result = Invoke-IconEditorVipBuild `
        -VipbPath $ResolvedVIPBPath `
        -Major $Major `
        -Minor $Minor `
        -Patch $Patch `
        -Build $Build `
        -SupportedBitness $bitnessValue `
        -MinimumSupportedLVVersion $MinimumSupportedLVVersion `
        -LabVIEWMinorRevision $labviewMinor `
        -ReleaseNotesPath $resolvedReleaseNotes `
        -WorkspaceRoot $iconEditorRoot `
        -Provider 'vipm'

    Write-Host "Successfully built VI package: $($result.PackagePath)"
}
catch {
    $errorObject = [PSCustomObject]@{
        error      = "An error occurred while executing the VIPM build."
        exception  = $_.Exception.Message
        stackTrace = $_.Exception.StackTrace
    }
    $errorObject | ConvertTo-Json -Depth 10
    exit 1
}

# 6) Persist VIPM build diagnostics
$logRoot = Join-Path $iconEditorRoot 'tests\results\_agent\icon-editor\vipm-cli-build'
if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMddTHHmmssfff'
$logPath = Join-Path $logRoot ("vipm-build-{0}.log" -f $timestamp)
$metadataPath = Join-Path $logRoot ("vipm-build-{0}.json" -f $timestamp)

$logLines = @()
$logLines += "VIPM Build Invocation"
$logLines += "Timestamp (UTC): {0}" -f (Get-Date -Format 'u')
$logLines += "Provider: {0}" -f $result.Provider
$logLines += "ProviderBinary: {0}" -f $result.ProviderBinary
$logLines += "PackagePath: {0}" -f $result.PackagePath
$logLines += "DurationSeconds: {0}" -f $result.DurationSeconds
$logLines += "Warnings: {0}" -f (($result.Warnings -join '; ') ?? '')
$logLines += "---- StdOut ----"
if ($result.StdOut) { $logLines += $result.StdOut } else { $logLines += '<empty>' }
$logLines += "---- StdErr ----"
if ($result.StdErr) { $logLines += $result.StdErr } else { $logLines += '<empty>' }

Set-Content -LiteralPath $logPath -Value $logLines -Encoding UTF8
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

if ($Env:GITHUB_OUTPUT) {
    $relativeLog = [System.IO.Path]::GetRelativePath($repoRoot, (Resolve-Path -LiteralPath $logPath).ProviderPath).Replace('\','/')
    $relativeMetadata = [System.IO.Path]::GetRelativePath($repoRoot, (Resolve-Path -LiteralPath $metadataPath).ProviderPath).Replace('\','/')
    "vipm_build_log=$relativeLog" >> $Env:GITHUB_OUTPUT
    "vipm_build_metadata=$relativeMetadata" >> $Env:GITHUB_OUTPUT
}

