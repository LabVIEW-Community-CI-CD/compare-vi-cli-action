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

function Convert-ToCliBoolString {
  param(
    [Parameter(Mandatory)][object]$Value,
    [Parameter(Mandatory)][string]$ParameterName
  )

  if ($Value -is [bool]) {
    return (Convert-ToBoolString -Value $Value)
  }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [int64]) {
    switch ([int64]$Value) {
      0 { return $script:boolFalse }
      1 { return $script:boolTrue }
      default { throw ("Parameter '{0}' only accepts boolean, 0, or 1 values." -f $ParameterName) }
    }
  }
  if ($Value -is [string]) {
    $normalized = $Value.Trim().ToLowerInvariant()
    switch ($normalized) {
      'true' { return $script:boolTrue }
      'false' { return $script:boolFalse }
      '1' { return $script:boolTrue }
      '0' { return $script:boolFalse }
      default { throw ("Parameter '{0}' string value '{1}' is not a supported boolean token." -f $ParameterName, $Value) }
    }
  }

  throw ("Parameter '{0}' value type '{1}' is not supported for boolean conversion." -f $ParameterName, $Value.GetType().FullName)
}

function Resolve-LabVIEWCliBinaryPath {
  return Resolve-LabVIEWCliPath
}

function Get-LabVIEWInstallCandidates {
  param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Bitness,
    [object]$Config
  )
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($Config -and $Config.PSObject.Properties['labview']) {
    $cfg = $Config.labview
    if ($cfg -is [string]) { $candidates.Add($cfg) }
    elseif ($cfg -is [System.Collections.IEnumerable]) {
      foreach ($entry in $cfg) { if ($entry) { $candidates.Add([string]$entry) } }
    }
  }
  $pf = $env:ProgramFiles
  $pf86 = ${env:ProgramFiles(x86)}
  if ($Bitness -eq '32') {
    foreach ($root in @($pf, $pf86)) {
      if (-not $root) { continue }
      $candidates.Add((Join-Path $root ("National Instruments\LabVIEW $Version (32-bit)\LabVIEW.exe")))
      $candidates.Add((Join-Path $root ("National Instruments\LabVIEW $Version\LabVIEW.exe")))
    }
  } else {
    foreach ($root in @($pf)) {
      if (-not $root) { continue }
      $candidates.Add((Join-Path $root ("National Instruments\LabVIEW $Version\LabVIEW.exe")))
    }
  }
  return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Resolve-LabVIEWPathFromParams {
  param([hashtable]$Params)
  $Params = $Params ?? @{}
  $effectiveBitness = if ($Params.ContainsKey('labviewBitness') -and $Params.labviewBitness) {
    [string]$Params.labviewBitness
  } else {
    '64'
  }
  if ($Params.ContainsKey('labviewPath') -and $Params.labviewPath) {
    $candidate = $Params.labviewPath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    return $candidate
  }
  foreach ($envName in @('LABVIEW_PATH','LABVIEW_EXE_PATH')) {
    $envValue = [System.Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
      if (Test-Path -LiteralPath $envValue -PathType Leaf) {
        $resolvedEnv = (Resolve-Path -LiteralPath $envValue).Path
        if ($effectiveBitness -eq '64' -and $resolvedEnv -match '(?i)Program Files \(x86\)') {
          continue
        }
        return $resolvedEnv
      }
      return $envValue
    }
  }
  $config = $null
  $root = Get-ProviderRepoRoot
  $configPath = Join-Path $root 'configs/labview-paths.json'
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try { $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -Depth 4 } catch {}
  }
  $version = if ($Params.ContainsKey('labviewVersion')) { $Params.labviewVersion } else { '2025' }
  $candidates = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in Get-LabVIEWInstallCandidates -Version $version -Bitness $effectiveBitness -Config $config) {
    $candidates.Add($candidate)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $resolvedCandidate = (Resolve-Path -LiteralPath $candidate).Path
      if ($effectiveBitness -eq '64' -and $resolvedCandidate -match '(?i)Program Files \(x86\)') { continue }
      return $resolvedCandidate
    }
  }
  Write-Verbose ("LabVIEWCLI provider: LabVIEW candidates -> {0}" -f ($candidates -join '; '))
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
        '-VI1', $Params.vi1,
        '-VI2', $Params.vi2
      )
      if ($Params.ContainsKey('reportPath') -and $Params.reportPath) {
        $args += @('-ReportPath', $Params.reportPath)
      }
      if ($Params.ContainsKey('reportType') -and $Params.reportType) {
        $args += @('-ReportType', $Params.reportType)
      }
      if ($Params.ContainsKey('flags') -and $Params.flags) {
        foreach ($flag in $Params.flags) {
          if (-not [string]::IsNullOrWhiteSpace([string]$flag)) {
            $args += [string]$flag
          }
        }
      }
      $resolvedLvPath = Resolve-LabVIEWPathFromParams -Params $Params
      if ($resolvedLvPath) {
        $args += @('-LabVIEWPath', $resolvedLvPath)
      }
      if ($Params.ContainsKey('headless')) {
        $args += @('-Headless', (Convert-ToCliBoolString -Value $Params.headless -ParameterName 'headless'))
      }
      if ($Params.ContainsKey('logToConsole')) {
        $args += @('-LogToConsole', (Convert-ToCliBoolString -Value $Params.logToConsole -ParameterName 'logToConsole'))
      }
      return $args
    }
    'RunCustomOperation' {
      $args = @(
        '-OperationName', $Params.customOperationName,
        '-AdditionalOperationDirectory', $Params.additionalOperationDirectory
      )
      if ($Params.ContainsKey('help') -and $Params.help) {
        $args += '-Help'
      }
      if ($Params.ContainsKey('arguments') -and $Params.arguments) {
        foreach ($arg in $Params.arguments) {
          if (-not [string]::IsNullOrWhiteSpace([string]$arg)) {
            $args += [string]$arg
          }
        }
      }
      if ($Params.ContainsKey('labviewPath') -and $Params.labviewPath) {
        $args += @('-LabVIEWPath', $Params.labviewPath)
      }
      if ($Params.ContainsKey('logToConsole')) {
        $args += @('-LogToConsole', (Convert-ToCliBoolString -Value $Params.logToConsole -ParameterName 'logToConsole'))
      }
      if ($Params.ContainsKey('headless')) {
        $args += @('-Headless', (Convert-ToCliBoolString -Value $Params.headless -ParameterName 'headless'))
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
    return @('CloseLabVIEW','CreateComparisonReport','RunCustomOperation','RunVI','RunVIAnalyzer','RunUnitTests','MassCompile','ExecuteBuildSpec') -contains $Operation
  }
  $provider | Add-Member ScriptMethod BuildArgs {
    param($Operation,$Params)
    return (Get-LabVIEWCliArgs -Operation $Operation -Params $Params)
  }
  return $provider
}

Export-ModuleMember -Function New-LVProvider
$script:ProviderRepoRoot = $null
function Get-ProviderRepoRoot {
  if ($script:ProviderRepoRoot) { return $script:ProviderRepoRoot }
  $start = (Get-Location).Path
  try {
    $root = git -C $start rev-parse --show-toplevel 2>$null
    if ($root) {
      $script:ProviderRepoRoot = $root.Trim()
      return $script:ProviderRepoRoot
    }
  } catch {}
  $script:ProviderRepoRoot = (Resolve-Path -LiteralPath $start).Path
  return $script:ProviderRepoRoot
}
