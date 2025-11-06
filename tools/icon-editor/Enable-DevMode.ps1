#Requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$IconEditorRoot,
  [int[]]$Versions,
  [int[]]$Bitness,
  [string]$Operation = 'BuildPackage'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $scriptDirectory 'IconEditorDevMode.psm1'
Import-Module $modulePath -Force

$invokeParams = @{}
if ($RepoRoot) {
  $invokeParams.RepoRoot = $RepoRoot
}
if ($IconEditorRoot) {
  $invokeParams.IconEditorRoot = $IconEditorRoot
}
if ($Versions) {
  $invokeParams.Versions = $Versions
}
if ($Bitness) {
  $invokeParams.Bitness = $Bitness
}
if ($Operation) {
  $invokeParams.Operation = $Operation
}

$state = Enable-IconEditorDevelopmentMode @invokeParams

Write-Host "Icon editor development mode enabled."
if ($null -eq $state) {
  Write-Warning "Enable-IconEditorDevelopmentMode returned no state payload."
} else {
  $stateType = $state.GetType().FullName
  $pathProp = $state.PSObject.Properties['Path']
  $updatedProp = $state.PSObject.Properties['UpdatedAt']

  if ($pathProp) {
    Write-Host ("State file: {0}" -f $pathProp.Value)
  } else {
    Write-Warning ("Dev-mode state omitted 'Path' (type: {0})" -f $stateType)
    Write-Warning ($state | ConvertTo-Json -Depth 5 -Compress)
  }

  if ($updatedProp) {
    Write-Host ("Updated at : {0}" -f $updatedProp.Value)
  } else {
    Write-Warning ("Dev-mode state omitted 'UpdatedAt' (type: {0})" -f $stateType)
  }
}

$state
