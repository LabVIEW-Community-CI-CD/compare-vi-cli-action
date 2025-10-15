Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GCliCandidatePaths {
  $candidates = @()
  foreach ($envName in @('GCLI_PATH','GCLI_EXE','GCLI_BIN','G_CLI_PATH','GCLI')) {
    $value = [System.Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      $candidates += $value
    }
  }
  try {
    $command = Get-Command 'g-cli' -ErrorAction Stop
    if ($command -and $command.Source -ne 'Alias') {
      if ($command.Path) { $candidates += $command.Path }
    }
  } catch {}

  if ($IsWindows) {
    $roots = @([System.Environment]::GetEnvironmentVariable('ProgramFiles'), [System.Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))
    foreach ($root in $roots) {
      if ([string]::IsNullOrWhiteSpace($root)) { continue }
      $candidates += (Join-Path $root 'G-CLI\\bin\\g-cli.exe')
    }
  } else {
    $candidates += '/usr/local/bin/g-cli'
    $candidates += '/usr/bin/g-cli'
    $candidates += '/opt/g-cli/bin/g-cli'
  }

  return $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Resolve-GCliBinaryPath {
  foreach ($candidate in Get-GCliCandidatePaths) {
    try {
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
      }
    } catch {
      # Ignore resolution failures; fall back to next candidate.
    }
  }
  return $null
}

function Convert-ToBoolString {
  param([bool]$Value)
  if ($Value) { return 'true' }
  return 'false'
}

function Add-GCliArgument {
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter()][object]$Value,
    [Parameter(Mandatory)][ref]$Buffer
  )
  if ($null -eq $Value -or ([string]::IsNullOrWhiteSpace([string]$Value) -and -not ($Value -is [bool]) -and -not ($Value -is [int]))) {
    return
  }
  $flag = '--' + $Name
  switch ($Value) {
    { $_ -is [bool] } {
      $Buffer.Value += @($flag, (Convert-ToBoolString $Value))
    }
    { $_ -is [System.Collections.IEnumerable] -and -not ($_ -is [string]) } {
      foreach ($item in $Value) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item)) { continue }
        $Buffer.Value += @($flag, [string]$item)
      }
    }
    default {
      $Buffer.Value += @($flag, [string]$Value)
    }
  }
}

function Get-GCliArgs {
  param(
    [Parameter(Mandatory)][string]$Operation,
    [Parameter()][hashtable]$Params
  )

  $args = @('--operation', $Operation)
  switch ($Operation) {
    'CloseLabVIEW' {
      Add-GCliArgument -Name 'labviewPath' -Value $Params.labviewPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'labviewVersion' -Value $Params.labviewVersion -Buffer ([ref]$args)
      Add-GCliArgument -Name 'labviewBitness' -Value $Params.labviewBitness -Buffer ([ref]$args)
    }
    'CreateComparisonReport' {
      Add-GCliArgument -Name 'vi1' -Value $Params.vi1 -Buffer ([ref]$args)
      Add-GCliArgument -Name 'vi2' -Value $Params.vi2 -Buffer ([ref]$args)
      Add-GCliArgument -Name 'reportPath' -Value $Params.reportPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'reportType' -Value $Params.reportType -Buffer ([ref]$args)
    }
    'RunVI' {
      Add-GCliArgument -Name 'viPath' -Value $Params.viPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'showFP' -Value $Params.showFP -Buffer ([ref]$args)
      Add-GCliArgument -Name 'abortOnError' -Value $Params.abortOnError -Buffer ([ref]$args)
      if ($Params.ContainsKey('arguments') -and $Params.arguments) {
        Add-GCliArgument -Name 'argument' -Value @($Params.arguments) -Buffer ([ref]$args)
      }
    }
    'RunVIAnalyzer' {
      Add-GCliArgument -Name 'configPath' -Value $Params.configPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'reportPath' -Value $Params.reportPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'reportSaveType' -Value $Params.reportSaveType -Buffer ([ref]$args)
      Add-GCliArgument -Name 'configPassword' -Value $Params.configPassword -Buffer ([ref]$args)
    }
    'RunUnitTests' {
      Add-GCliArgument -Name 'projectPath' -Value $Params.projectPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'junitReportPath' -Value $Params.junitReportPath -Buffer ([ref]$args)
    }
    'MassCompile' {
      Add-GCliArgument -Name 'directoryToCompile' -Value $Params.directoryToCompile -Buffer ([ref]$args)
      Add-GCliArgument -Name 'massCompileLogFile' -Value $Params.massCompileLogFile -Buffer ([ref]$args)
      Add-GCliArgument -Name 'appendToMassCompileLog' -Value $Params.appendToMassCompileLog -Buffer ([ref]$args)
      Add-GCliArgument -Name 'numOfVIsToCache' -Value $Params.numOfVIsToCache -Buffer ([ref]$args)
      Add-GCliArgument -Name 'reloadLVSBs' -Value $Params.reloadLVSBs -Buffer ([ref]$args)
    }
    'ExecuteBuildSpec' {
      Add-GCliArgument -Name 'projectPath' -Value $Params.projectPath -Buffer ([ref]$args)
      Add-GCliArgument -Name 'targetName' -Value $Params.targetName -Buffer ([ref]$args)
      $specName = if ($Params.buildSpec) { $Params.buildSpec } else { $Params.buildSpecName }
      Add-GCliArgument -Name 'buildSpecName' -Value $specName -Buffer ([ref]$args)
    }
    default {
      throw "Operation '$Operation' not yet implemented for g-cli provider."
    }
  }

  return $args
}

function New-LVProvider {
  $provider = New-Object PSObject
  $provider | Add-Member ScriptMethod Name { 'gcli' }
  $provider | Add-Member ScriptMethod ResolveBinaryPath { Resolve-GCliBinaryPath }
  $provider | Add-Member ScriptMethod Supports {
    param($Operation)
    return @('CloseLabVIEW','CreateComparisonReport','RunVI','RunVIAnalyzer','RunUnitTests','MassCompile','ExecuteBuildSpec') -contains $Operation
  }
  $provider | Add-Member ScriptMethod BuildArgs {
    param($Operation,$Params)
    return (Get-GCliArgs -Operation $Operation -Params $Params)
  }
  return $provider
}

Export-ModuleMember -Function New-LVProvider
