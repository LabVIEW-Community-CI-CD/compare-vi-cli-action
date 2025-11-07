[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MinimumSupportedLVVersion,
    [Parameter(Mandatory)][ValidateSet('32','64')][string]$SupportedBitness,
    [Parameter(Mandatory)][Alias('IconEditorRoot')][string]$RelativePath
)

$ErrorActionPreference = 'Stop'

function Resolve-PathOrDefault {
    param([string]$PathValue)
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return $null }
    try {
        return (Resolve-Path -LiteralPath $PathValue -ErrorAction Stop).Path
    } catch {
        return $PathValue
    }
}

$targetRoot = Resolve-PathOrDefault -PathValue $RelativePath
if (-not $targetRoot) {
    throw "RelativePath/IconEditorRoot is required."
}

$deploymentRoot = Join-Path $targetRoot 'Tooling' 'deployment'
$createTokenPath = Join-Path $deploymentRoot 'Create_LV_INI_Token.vi'

$gCliExe = if ($env:GCLI_EXE_PATH -and -not [string]::IsNullOrWhiteSpace($env:GCLI_EXE_PATH)) {
    $env:GCLI_EXE_PATH
} else {
    'g-cli'
}

$gCliArgs = @(
    '--lv-ver', $MinimumSupportedLVVersion,
    '--arch',   $SupportedBitness,
    '-v',       $createTokenPath,
    '--',
    'LabVIEW',
    'Localhost.LibraryPaths',
    $targetRoot
)

Write-Host ("Executing: {0} {1}" -f $gCliExe, ($gCliArgs -join ' '))
& $gCliExe @gCliArgs
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "g-cli exited with code $exitCode while updating Localhost.LibraryPaths."
}

Write-Host "Create localhost.library path from ini file"

$closeScriptOverride = $env:ICON_EDITOR_CLOSE_SCRIPT_PATH
$scriptDir = Split-Path -Parent $PSCommandPath
$closeScriptDefault = Join-Path (Split-Path -Parent $scriptDir) 'close-labview' 'Close_LabVIEW.ps1'
$closeScript = if (-not [string]::IsNullOrWhiteSpace($closeScriptOverride)) { $closeScriptOverride } else { $closeScriptDefault }

if ($closeScript -and (Test-Path -LiteralPath $closeScript -PathType Leaf)) {
    try {
        & $closeScript `
            -MinimumSupportedLVVersion $MinimumSupportedLVVersion `
            -SupportedBitness $SupportedBitness | Out-Null
    } catch {
        Write-Warning ("Failed to close LabVIEW after token update via '{0}': {1}" -f $closeScript, $_.Exception.Message)
    }
} else {
    Write-Verbose ("Close-LabVIEW helper not found at '{0}'; skipping post-token close." -f $closeScript)
}
