<#
.SYNOPSIS
  Append a concise Session block from tests/results/session-index.json.
#>
[CmdletBinding()]
param(
  [string]$ResultsDir = 'tests/results',
  [string]$FileName = 'session-index.json'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_STEP_SUMMARY) { return }

$readerModule = Join-Path (Split-Path -Parent $PSCommandPath) 'SessionIndex-Readers.psm1'
Import-Module $readerModule -Force

$path = if ($ResultsDir) { Join-Path $ResultsDir $FileName } else { $FileName }
$preferred = Read-PreferredSessionIndex -ResultsDir $ResultsDir
if (-not $preferred.Path) {
  ("### Session`n- File: (missing) {0}`n- Source: missing" -f $path) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
  return
}
$path = $preferred.Path
$j = $preferred.Data

$lines = @('### Session','')
if ($j) {
  function Add-LineIfPresent {
    param(
      [Parameter(Mandatory)][pscustomobject]$Object,
      [Parameter(Mandatory)][string]$Property,
      [Parameter(Mandatory)][string]$Label,
      [Parameter(Mandatory)][ref]$Target
    )
    $prop = $Object.PSObject.Properties[$Property]
    if ($prop -and $prop.Value -ne $null) {
      $Target.Value += ('- {0}: {1}' -f $Label, $prop.Value)
    }
  }

  Add-LineIfPresent -Object $j -Property 'status' -Label 'Status' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'total' -Label 'Total' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'passed' -Label 'Passed' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'failed' -Label 'Failed' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'errors' -Label 'Errors' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'skipped' -Label 'Skipped' -Target ([ref]$lines)
  Add-LineIfPresent -Object $j -Property 'duration_s' -Label 'Duration (s)' -Target ([ref]$lines)
  $lines += ('- Source: {0}' -f $preferred.Source)
  $lines += ('- File: {0}' -f $path)

  if ($preferred.Source -eq 'v2' -and $j.PSObject.Properties.Name -contains 'tests' -and $j.tests -and $j.tests.PSObject.Properties.Name -contains 'cases') {
    $cases = @($j.tests.cases)
    if ($cases.Count -gt 0) {
      $withRequirement = @($cases | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'requirement' -and -not [string]::IsNullOrWhiteSpace([string]$_.requirement) }).Count
      $lines += ('- Requirement-tagged cases: {0}/{1}' -f $withRequirement, $cases.Count)
    }
  }

  $runContext = $null
  if ($j.PSObject.Properties.Name -contains 'runContext') {
    $runContext = $j.runContext
  }
  if ($runContext) {
    $runnerDetails = @()
    $runnerName = $runContext.PSObject.Properties['runner']
    if ($runnerName -and $runnerName.Value) { $runnerDetails += ('- Name: {0}' -f $runnerName.Value) }
    $runnerOs = $runContext.PSObject.Properties['runnerOS']
    $runnerArch = $runContext.PSObject.Properties['runnerArch']
    if ($runnerOs -and $runnerOs.Value -and $runnerArch -and $runnerArch.Value) {
      $runnerDetails += ('- OS/Arch: {0}/{1}' -f $runnerOs.Value,$runnerArch.Value)
    } elseif ($runnerOs -and $runnerOs.Value) {
      $runnerDetails += ('- OS: {0}' -f $runnerOs.Value)
    } elseif ($runnerArch -and $runnerArch.Value) {
      $runnerDetails += ('- Arch: {0}' -f $runnerArch.Value)
    }
    $runnerEnv = $runContext.PSObject.Properties['runnerEnvironment']
    if ($runnerEnv -and $runnerEnv.Value) { $runnerDetails += ('- Environment: {0}' -f $runnerEnv.Value) }
    $runnerMachine = $runContext.PSObject.Properties['runnerMachine']
    if ($runnerMachine -and $runnerMachine.Value) { $runnerDetails += ('- Machine: {0}' -f $runnerMachine.Value) }
    $runnerImageOsProp = $runContext.PSObject.Properties['runnerImageOS']
    $runnerImageVersionProp = $runContext.PSObject.Properties['runnerImageVersion']
    $imageOsValue = if ($runnerImageOsProp) { $runnerImageOsProp.Value } else { $null }
    $imageVerValue = if ($runnerImageVersionProp) { $runnerImageVersionProp.Value } else { $null }
    if ($imageOsValue -and $imageVerValue) {
      $runnerDetails += ('- Image: {0} ({1})' -f $imageOsValue,$imageVerValue)
    } elseif ($imageOsValue) {
      $runnerDetails += ('- Image: {0}' -f $imageOsValue)
    } elseif ($imageVerValue) {
      $runnerDetails += ('- Image Version: {0}' -f $imageVerValue)
    }
    $labelsList = @()
    if ($runContext.PSObject.Properties.Name -contains 'runnerLabels') {
      $rawLabels = $runContext.runnerLabels
      if ($null -ne $rawLabels) {
        if ($rawLabels -is [System.Collections.IEnumerable] -and -not ($rawLabels -is [string])) {
          foreach ($label in $rawLabels) {
            if ($label -and "$label" -ne '') { $labelsList += "$label" }
          }
        } elseif ($rawLabels -and "$rawLabels" -ne '') {
          $labelsList += "$rawLabels"
        }
      }
    }
    if ($labelsList.Count -gt 0) {
      $uniqueLabels = $labelsList | Where-Object { $_ -and $_ -ne '' } | Select-Object -Unique
      if ($uniqueLabels.Count -gt 0) {
        $runnerDetails += ('- Labels: {0}' -f ($uniqueLabels -join ', '))
      }
    }
    if ($runnerDetails.Count -gt 0) {
      $lines += ''
      $lines += '### Runner'
      $lines += ''
      $lines += $runnerDetails
    }
  }
} else {
  $lines += ('- Source: {0}' -f $preferred.Source)
  $lines += ('- File: failed to parse: {0}' -f $path)
}

$lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
