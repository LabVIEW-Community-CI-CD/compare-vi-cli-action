<#
.SYNOPSIS
    Updates a VIPB file's display information and builds the VI package.

.DESCRIPTION
    Locates a VIPB file stored alongside this script, merges version details into
    DisplayInformation JSON, and invokes the provider-backed packaging helper
    (g-cli by default) to create the final VI package.

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

.PARAMETER BuildToolchain
    Toolchain requested for the package build (`gcli` or `vipm`). Defaults to `gcli`.

.PARAMETER BuildProvider
    Optional provider name routed to the selected toolchain (e.g. custom g-cli shim).

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

    [ValidateSet("gcli","vipm")]
    [string]$BuildToolchain = "gcli",

    [string]$BuildProvider,

    [Parameter(Mandatory=$true)]
    [string]$DisplayInformationJSON
)

Set-StrictMode -Version Latest

$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).ProviderPath
$iconEditorModulePath = Join-Path $workspaceRoot 'tools\icon-editor\IconEditorPackage.psm1'
if (-not (Test-Path -LiteralPath $iconEditorModulePath -PathType Leaf)) {
    throw "IconEditor package module not found at '$iconEditorModulePath'."
}
Import-Module $iconEditorModulePath -Force

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

# 5) Execute the package build via the provider-aware helper
try {
    Write-Host ("Invoking icon-editor package build via {0} toolchain..." -f $BuildToolchain)

    $buildParams = @{
        VipbPath                  = $ResolvedVIPBPath
        Major                     = $Major
        Minor                     = $Minor
        Patch                     = $Patch
        Build                     = $Build
        SupportedBitness          = [int]$SupportedBitness
        MinimumSupportedLVVersion = $MinimumSupportedLVVersion
        LabVIEWMinorRevision      = [int]$LabVIEWMinorRevision
        ReleaseNotesPath          = $ReleaseNotesFile
        WorkspaceRoot             = $workspaceRoot
        Provider                  = $BuildToolchain
    }

    if ($BuildToolchain -eq 'gcli' -and $BuildProvider) {
        $buildParams.GCliProviderName = $BuildProvider
    } elseif ($BuildToolchain -eq 'vipm' -and $BuildProvider) {
        $buildParams.VipmProviderName = $BuildProvider
    }

    $buildResult = Invoke-IconEditorVipBuild @buildParams

    if ($buildResult.ReleaseNotes) {
        $ReleaseNotesFile = $buildResult.ReleaseNotes
    }

    if ($buildResult.Provider) {
        Write-Host ("Resolved provider backend: {0}" -f $buildResult.Provider)
    }

    Write-Host "Successfully built VI package: $ResolvedVIPBPath"
}
catch {
    $errorObject = [PSCustomObject]@{
        error      = "An error occurred while executing the build commands."
        exception  = $_.Exception.Message
        stackTrace = $_.Exception.StackTrace
    }
    $errorObject | ConvertTo-Json -Depth 10
    exit 1
}

