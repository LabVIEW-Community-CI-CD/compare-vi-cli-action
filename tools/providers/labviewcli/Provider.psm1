Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$toolsRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $toolsRoot 'VendorTools.psm1') -Force

$script:boolTrue  = 'true'
$script:boolFalse = 'false'

function Convert-ToBoolString {
  param([bool]$Value)
  if ($Value) { return $script:boolTrue }
  return $script:boolFalse
}

function Resolve-LabVIEWCliBinaryPath {
  return Resolve-LabVIEWCliPath
}

function Get-LabVIEWInstallCandidates {
  param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Bitness
  )
  $candidates = @()
  $pf = $env:ProgramFiles
  $pf86 = ${env:ProgramFiles(x86)}
  if ($Bitness -eq '32') {
    foreach ($root in @($pf, $pf86)) {
      if (-not $root) { continue }
      $candidates += (Join-Path $root ("National Instruments\LabVIEW $Version (32-bit)\LabVIEW.exe"))
      $candidates += (Join-Path $root ("National Instruments\LabVIEW $Version\LabVIEW.exe"))
    }
  } else {
    foreach ($root in @($pf, $pf86)) {
      if (-not $root) { continue }
      $candidates += (Join-Path $root ("National Instruments\LabVIEW $Version\LabVIEW.exe"))
    }
  }
  return $candidates | Where-Object { $_ }
}

function Resolve-LabVIEWPathFromParams {
  param([hashtable]$Params)
  if ($Params.ContainsKey('labviewPath') -and $Params.labviewPath) {
    $candidate = $Params.labviewPath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    return $candidate
  }
  $version = if ($Params.ContainsKey('labviewVersion')) { $Params.labviewVersion } else { '2025' }
  $bitness = if ($Params.ContainsKey('labviewBitness')) { $Params.labviewBitness } else { '64' }
  foreach ($candidate in Get-LabVIEWInstallCandidates -Version $version -Bitness $bitness) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }
  return $null
}

function Get-LabVIEWCliArgs {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][hashtable]$Params
  )
  switch ($Operation) {
    'CloseLabVIEW' {
      $args = @('-OperationName','CloseLabVIEW')
      $lvPath = Resolve-LabVIEWPathFromParams -Params $Params
      if ($lvPath) {
        $args += @('-LabVIEWPath', $lvPath)
      }
      return $args
    }
    'CreateComparisonReport' {
      $args = @(
        '-OperationName','CreateComparisonReport',
        '-vi1', $Params.vi1,
        '-vi2', $Params.vi2
      )
      if ($Params.ContainsKey('reportPath') -and $Params.reportPath) {
        $args += @('-reportPath', $Params.reportPath)
      }
      if ($Params.ContainsKey('reportType') -and $Params.reportType) {
        $args += @('-reportType', $Params.reportType)
      }
      if ($Params.ContainsKey('flags') -and $Params.flags) {
        foreach ($flag in $Params.flags) {
          if (-not [string]::IsNullOrWhiteSpace([string]$flag)) {
            $args += [string]$flag
          }
        }
      }
      return $args
    }
    'RunVI' {
      $args = @(
        '-OperationName','RunVI',
        '-VIPath', $Params.viPath
      )
      if ($Params.ContainsKey('showFP')) {
        $args += @('-ShowFrontPanel', (Convert-ToBoolString $Params.showFP))
      }
      if ($Params.ContainsKey('abortOnError')) {
        $args += @('-AbortOnError', (Convert-ToBoolString $Params.abortOnError))
      }
      if ($Params.ContainsKey('arguments') -and $Params.arguments) {
        foreach ($arg in $Params.arguments) { $args += [string]$arg }
      }
      return $args
    }
    'RunVIAnalyzer' {
      $args = @(
        '-OperationName','RunVIAnalyzer',
        '-ConfigPath', $Params.configPath,
        '-ReportPath', $Params.reportPath
      )
      if ($Params.ContainsKey('reportSaveType') -and $Params.reportSaveType) {
        $args += @('-ReportSaveType', $Params.reportSaveType)
      }
      if ($Params.ContainsKey('configPassword') -and $Params.configPassword) {
        $args += @('-ConfigPassword', $Params.configPassword)
      }
      return $args
    }
    'RunUnitTests' {
      $args = @(
        '-OperationName','RunUnitTests',
        '-ProjectPath', $Params.projectPath,
        '-JUnitReportPath', $Params.junitReportPath
      )
      return $args
    }
    'MassCompile' {
      $args = @(
        '-OperationName','MassCompile',
        '-DirectoryToCompile', $Params.directoryToCompile
      )
      if ($Params.ContainsKey('massCompileLogFile') -and $Params.massCompileLogFile) {
        $args += @('-MassCompileLogFile', $Params.massCompileLogFile)
      }
      if ($Params.ContainsKey('appendToMassCompileLog')) {
        $args += @('-AppendToMassCompileLog', (Convert-ToBoolString $Params.appendToMassCompileLog))
      }
      if ($Params.ContainsKey('numOfVIsToCache')) {
        $args += @('-NumOfVIsToCache', [string]$Params.numOfVIsToCache)
      }
      if ($Params.ContainsKey('reloadLVSBs')) {
        $args += @('-ReloadLVSBs', (Convert-ToBoolString $Params.reloadLVSBs))
      }
      return $args
    }
    'ExecuteBuildSpec' {
      $buildSpecName = $Params.buildSpecName
      if (-not $buildSpecName -and $Params.ContainsKey('buildSpec')) {
        $buildSpecName = $Params.buildSpec
      }
      $args = @(
        '-OperationName','ExecuteBuildSpec',
        '-ProjectPath', $Params.projectPath
      )
      if ($Params.ContainsKey('targetName') -and $Params.targetName) {
        $args += @('-TargetName', $Params.targetName)
      }
      if ($buildSpecName) {
        $args += @('-BuildSpecName', $buildSpecName)
      }
      return $args
    }
    default {
      throw "Operation '$Operation' not yet implemented for LabVIEWCLI provider."
    }
  }
}

function New-LVProvider {
  $provider = New-Object PSObject
  $provider | Add-Member ScriptMethod Name { 'labviewcli' }
  $provider | Add-Member ScriptMethod ResolveBinaryPath { Resolve-LabVIEWCliBinaryPath }
  $provider | Add-Member ScriptMethod Supports {
    param($Operation)
    return @('CloseLabVIEW','CreateComparisonReport','RunVI','RunVIAnalyzer','RunUnitTests','MassCompile','ExecuteBuildSpec') -contains $Operation
  }
  $provider | Add-Member ScriptMethod BuildArgs {
    param($Operation,$Params)
    return (Get-LabVIEWCliArgs -Operation $Operation -Params $Params)
  }
  return $provider
}

Export-ModuleMember -Function New-LVProvider
