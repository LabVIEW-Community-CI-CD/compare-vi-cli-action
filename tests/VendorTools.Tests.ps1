Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (git rev-parse --show-toplevel).Trim()
$modulePath = Join-Path $repoRoot 'tools/VendorTools.psm1'
Import-Module $modulePath -Force

$localConfigPath = Join-Path $repoRoot 'configs/labview-paths.local.json'
$hadExistingLocalConfig = Test-Path -LiteralPath $localConfigPath -PathType Leaf
$existingLocalConfig = $null
if ($hadExistingLocalConfig) {
  $existingLocalConfig = Get-Content -LiteralPath $localConfigPath -Raw
}

Describe 'VendorTools LabVIEW helpers' {
  AfterEach {
    if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
      Remove-Item -LiteralPath $localConfigPath -Force
    }
  }

  AfterAll {
    if ($hadExistingLocalConfig) {
      Set-Content -LiteralPath $localConfigPath -Value $existingLocalConfig
    } else {
      if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $localConfigPath -Force
      }
    }
  }

  It 'resolves LabVIEW executables and ini values from local config' {
    $tempRoot = Join-Path $TestDrive 'labview-local'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $fakeExe = Join-Path $tempRoot 'LabVIEW.exe'
    Set-Content -LiteralPath $fakeExe -Value '' -Encoding Byte
    $fakeIni = Join-Path $tempRoot 'LabVIEW.ini'
    Set-Content -LiteralPath $fakeIni -Value "SCCUseInLabVIEW=True`nSCCProviderIsActive=False`n"

    @"
{
  "labview": [ "$fakeExe" ]
}
"@ | Set-Content -LiteralPath $localConfigPath

    $candidates = Get-LabVIEWCandidateExePaths -LabVIEWExePath $fakeExe
    $resolvedExe = (Resolve-Path -LiteralPath $fakeExe).Path
    $candidates | Should -Contain $resolvedExe

    $iniPath = Get-LabVIEWIniPath -LabVIEWExePath $fakeExe
    $iniPath | Should -Be (Resolve-Path -LiteralPath $fakeIni).Path

    $sccValue = Get-LabVIEWIniValue -LabVIEWExePath $fakeExe -Key 'SCCUseInLabVIEW'
    $sccValue | Should -Be 'True'
  }
}
