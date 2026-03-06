Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PesterV5OrNewer {
  param(
    [string]$Caller = $PSCommandPath
  )

  $effectiveVersion = $null
  $loaded = @(Get-Module -Name Pester | Sort-Object Version -Descending | Select-Object -First 1)
  if ($loaded.Count -gt 0 -and $loaded[0].Version) {
    $effectiveVersion = [version]$loaded[0].Version
  } else {
    $available = @(Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending)
    if ($available.Count -gt 0 -and $available[0].Version) {
      $effectiveVersion = [version]$available[0].Version
    }
  }

  $leaf = if ($Caller) { Split-Path -Leaf $Caller } else { 'this test file' }
  if ($null -eq $effectiveVersion) {
    throw ("Pester v5+ is required for {0}, but no Pester module was found. Use Invoke-PesterTests.ps1 or tools/Run-Pester.ps1." -f $leaf)
  }
  if ($effectiveVersion.Major -lt 5) {
    throw ("Pester v5+ is required for {0}. Detected v{1}. Use Invoke-PesterTests.ps1 or tools/Run-Pester.ps1." -f $leaf, $effectiveVersion)
  }

  return $effectiveVersion
}

