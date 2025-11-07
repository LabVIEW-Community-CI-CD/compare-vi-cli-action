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

$rawState = Enable-IconEditorDevelopmentMode @invokeParams

if ($rawState -is [System.Array]) {
  $state = $rawState | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Active'] } | Select-Object -Last 1
  if (-not $state) {
    $state = $rawState | Select-Object -Last 1
  }
} else {
  $state = $rawState
}

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

  $verificationProp = $state.PSObject.Properties['Verification']
  if ($verificationProp) {
    $verification = $verificationProp.Value
    if ($verification -and $verification.Entries) {
      $present = $verification.Entries | Where-Object { $_.Present }
      if ($present -and $present.Count -gt 0) {
        $summary = $present | ForEach-Object {
          $status = if ($_.ContainsIconEditorPath) { 'contains icon-editor path' } else { 'missing icon-editor path' }
          "LabVIEW {0} ({1}-bit): {2}" -f $_.Version, $_.Bitness, $status
        }
        Write-Host ("Verification: {0}" -f ([string]::Join('; ', $summary)))
      } else {
        Write-Host "Verification: no LabVIEW targets detected; token check skipped."
      }
    }
  }
}

$state
