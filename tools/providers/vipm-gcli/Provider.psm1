#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gcliProviderPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'gcli' 'Provider.psm1'
if (-not (Test-Path -LiteralPath $gcliProviderPath -PathType Leaf)) {
    throw "GCli provider module not found at '$gcliProviderPath'."
}
Import-Module $gcliProviderPath -Force

function New-VipmProvider {
    $gcliProvider = New-GCliProvider
    $vipmProvider = New-Object PSObject
    $vipmProvider | Add-Member ScriptMethod Name { 'vipm-gcli' }
    $vipmProvider | Add-Member ScriptMethod ResolveBinaryPath { $gcliProvider.ResolveBinaryPath() }
    $vipmProvider | Add-Member ScriptMethod Supports {
        param($Operation)
        return @('InstallVipc') -contains $Operation
    }
    $vipmProvider | Add-Member ScriptMethod BuildArgs {
        param($Operation,$Params)
        if ($Operation -ne 'InstallVipc') {
            throw "vipm-gcli provider only supports InstallVipc operation (requested '$Operation')."
        }
        return (Get-GCliArgs -Operation 'VipcInstall' -Params $Params)
    }
    return $vipmProvider
}

Export-ModuleMember -Function New-VipmProvider
