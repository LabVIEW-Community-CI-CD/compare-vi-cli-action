<#
.SYNOPSIS
  Provides a structured setup/main/cleanup flow for packaging the Icon Editor VI.

.DESCRIPTION
  Wraps the Modify-VIPB, build_vip, and Close-LabVIEW scripts so every invocation
  emits consistent troubleshooting breadcrumbs. The helper also gathers freshly
  produced .vip artifacts and copies them to the provided results directory.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-IconEditorVipPackaging {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][ScriptBlock]$InvokeAction,
    [Parameter(Mandatory)][string]$ModifyVipbScriptPath,
    [Parameter(Mandatory)][string]$BuildVipScriptPath,
    [Parameter(Mandatory)][string]$CloseScriptPath,
    [Parameter(Mandatory)][string]$IconEditorRoot,
    [Parameter(Mandatory)][string]$ResultsRoot,
    [Parameter(Mandatory)][DateTime]$ArtifactCutoffUtc,
    [string[]]$ModifyArguments = @(),
    [string[]]$BuildArguments = @(),
    [string[]]$CloseArguments = @(),
    [string]$VipbRelativePath,
    [string]$ReleaseNotesPath,
    [string]$Toolchain = 'gcli',
    [string]$Provider,
    [string]$ArtifactFilter = '*.vip'
  )

  foreach ($scriptPath in @($ModifyVipbScriptPath, $BuildVipScriptPath, $CloseScriptPath)) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      throw "Required packaging script '$scriptPath' was not found."
    }
  }

  $artifactCutoffUtc = $ArtifactCutoffUtc.ToUniversalTime()
  $resultsResolved   = (Resolve-Path -LiteralPath $ResultsRoot).Path
  $iconRootResolved  = (Resolve-Path -LiteralPath $IconEditorRoot).Path

  Write-Host '=== Setup: IconEditorVipPackaging ==='
  Write-Host ("Icon editor root : {0}" -f $iconRootResolved)
  Write-Host ("Results root     : {0}" -f $resultsResolved)
  Write-Host ("Modify-VIPB script: {0}" -f $ModifyVipbScriptPath)
  Write-Host ("Build-VIP script : {0}" -f $BuildVipScriptPath)
  Write-Host ("Close script     : {0}" -f $CloseScriptPath)
  if ($VipbRelativePath) { Write-Host ("VIPB path        : {0}" -f $VipbRelativePath) }
  if ($ReleaseNotesPath) { Write-Host ("Release notes    : {0}" -f $ReleaseNotesPath) }
  Write-Host ("Toolchain        : {0}" -f ($Toolchain ?? '<unspecified>'))
  Write-Host ("Provider         : {0}" -f ($Provider ?? '<none>'))
  Write-Host ("Artifact filter  : {0}" -f $ArtifactFilter)

  $artifactList = New-Object System.Collections.Generic.List[object]

  Write-Host '=== MainSequence: IconEditorVipPackaging ==='

  Write-Host '-- Modify VIPB metadata'
  & $InvokeAction $ModifyVipbScriptPath $ModifyArguments

  Write-Host '-- Build VI Package via vendor helper'
  & $InvokeAction $BuildVipScriptPath $BuildArguments

  if ($CloseArguments) {
    Write-Host '-- Close LabVIEW instance used for packaging'
    & $InvokeAction $CloseScriptPath $CloseArguments
  }

  Write-Host '-- Collect VI package artifacts'
  $vipCandidates = Get-ChildItem -Path $iconRootResolved -Filter $ArtifactFilter -File -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $artifactCutoffUtc.AddSeconds(-2) }

  foreach ($vip in $vipCandidates) {
    $destination = Join-Path $resultsResolved $vip.Name
    Copy-Item -LiteralPath $vip.FullName -Destination $destination -Force
    $copiedInfo = Get-Item -LiteralPath $destination
    $artifactList.Add([ordered]@{
      SourcePath        = $vip.FullName
      DestinationPath   = $copiedInfo.FullName
      Name              = $copiedInfo.Name
      Kind              = 'vip'
      SizeBytes         = $copiedInfo.Length
      LastWriteTimeUtc  = $copiedInfo.LastWriteTimeUtc.ToString('o')
    }) | Out-Null
    Write-Host ("   Captured {0} ({1:N0} bytes)" -f $copiedInfo.Name, $copiedInfo.Length)
  }

  if ($artifactList.Count -eq 0) {
    Write-Warning 'No VI packages were produced after the build_vip step.'
  }

  Write-Host '=== Cleanup: IconEditorVipPackaging ==='

  return [pscustomobject]@{
    Artifacts = $artifactList
    Toolchain = $Toolchain
    Provider  = $Provider
  }
}

Export-ModuleMember -Function Invoke-IconEditorVipPackaging
