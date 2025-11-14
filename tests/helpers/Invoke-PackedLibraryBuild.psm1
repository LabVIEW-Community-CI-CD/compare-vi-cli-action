Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..')) 'tools' 'vendor' 'PackedLibraryBuild.psm1') -Force

function Invoke-PackedLibraryBuildHelper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$BuildScriptPath,
        [Parameter()][string]$CloseScriptPath,
        [Parameter(Mandatory)][string]$RenameScriptPath,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [Parameter(Mandatory)][string]$BaseArtifactName,
        [Parameter(Mandatory)][hashtable[]]$Targets,
        [ScriptBlock]$InvokeAction,
        [string[]]$CleanupPatterns = @('*.lvlibp')
    )

    if (-not $InvokeAction) {
        $InvokeAction = {
            param([string]$ScriptPath, [string[]]$Arguments)
            & pwsh -NoLogo -NoProfile -File $ScriptPath @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Script '$ScriptPath' exited with code $LASTEXITCODE."
            }
        }
    }

    Invoke-LVPackedLibraryBuild `
        -InvokeAction $InvokeAction `
        -BuildScriptPath $BuildScriptPath `
        -CloseScriptPath $CloseScriptPath `
        -RenameScriptPath $RenameScriptPath `
        -ArtifactDirectory $ArtifactDirectory `
        -BaseArtifactName $BaseArtifactName `
        -CleanupPatterns $CleanupPatterns `
        -Targets $Targets
}

Export-ModuleMember -Function Invoke-PackedLibraryBuildHelper
