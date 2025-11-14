#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).ProviderPath
$targetModule = Join-Path $repoRoot 'tools' 'Vipm.psm1'

if (-not (Test-Path -LiteralPath $targetModule -PathType Leaf)) {
    throw "Unable to locate root Vipm module at '$targetModule'."
}

$imported = Import-Module $targetModule -Force -PassThru
if ($imported) {
    Export-ModuleMember -Function $imported.ExportedFunctions.Keys -Alias $imported.ExportedAliases.Keys
}
