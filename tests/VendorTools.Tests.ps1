Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'VendorTools LabVIEW helpers' {
  BeforeAll {
    $script:repoRoot = (git rev-parse --show-toplevel).Trim()
    $script:modulePath = Join-Path $script:repoRoot 'tools/VendorTools.psm1'
    Import-Module $script:modulePath -Force

    $script:localConfigPath = Join-Path $script:repoRoot 'configs/labview-paths.local.json'
    $script:hadExistingLocalConfig = Test-Path -LiteralPath $script:localConfigPath -PathType Leaf
    if ($script:hadExistingLocalConfig) {
      $script:existingLocalConfig = Get-Content -LiteralPath $script:localConfigPath -Raw
    } else {
      $script:existingLocalConfig = $null
    }
  }

  AfterEach {
    if ($script:localConfigPath -and (Test-Path -LiteralPath $script:localConfigPath -PathType Leaf)) {
      Remove-Item -LiteralPath $script:localConfigPath -Force
    }
  }

  AfterAll {
    if ($script:hadExistingLocalConfig) {
      Set-Content -LiteralPath $script:localConfigPath -Value $script:existingLocalConfig -Encoding utf8
    } else {
      if ($script:localConfigPath -and (Test-Path -LiteralPath $script:localConfigPath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:localConfigPath -Force
      }
    }
  }

  It 'resolves LabVIEW executables and ini values from local config' {
    $tempRoot = Join-Path $TestDrive 'labview-local'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $fakeExe = Join-Path $tempRoot 'LabVIEW.exe'
    [System.IO.File]::WriteAllBytes($fakeExe, [byte[]](0x00)) | Out-Null
    $fakeIni = Join-Path $tempRoot 'LabVIEW.ini'
    Set-Content -LiteralPath $fakeIni -Value "SCCUseInLabVIEW=True`nSCCProviderIsActive=False`n"

    @"
{
  "labview": [ "$fakeExe" ]
}
"@ | Set-Content -LiteralPath $script:localConfigPath

    $candidates = Get-LabVIEWCandidateExePaths -LabVIEWExePath $fakeExe
    $resolvedExe = (Resolve-Path -LiteralPath $fakeExe).Path
    $candidates | Should -Contain $resolvedExe

    $iniPath = Get-LabVIEWIniPath -LabVIEWExePath $fakeExe
    $iniPath | Should -Be (Resolve-Path -LiteralPath $fakeIni).Path

    $sccValue = Get-LabVIEWIniValue -LabVIEWExePath $fakeExe -Key 'SCCUseInLabVIEW'
    $sccValue | Should -Be 'True'
  }

  It 'includes version-scoped executables when present' {
    $tempRoot = Join-Path $TestDrive 'labview-version'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $versionExe = Join-Path $tempRoot 'Program Files\NI\LabVIEW 2025\LabVIEW.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $versionExe) -Force | Out-Null
    Set-Content -LiteralPath $versionExe -Value '' -Encoding ascii

    $configJson = @{
      versions = @{
        '2025' = @{
          '64' = @{
            LabVIEWExePath = $versionExe
          }
        }
      }
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $script:localConfigPath -Value $configJson -Encoding utf8

    $candidates = Get-LabVIEWCandidateExePaths
    $resolvedVersionExe = (Resolve-Path -LiteralPath $versionExe).Path
    $candidates | Should -Contain $resolvedVersionExe
  }

  It 'resolves g-cli path from config overrides' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'g-cli resolution only applies on Windows'
      return
    }

    $tempRoot = Join-Path $TestDrive 'gcli-config'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fakeGCli = Join-Path $tempRoot 'g-cli.exe'
    Set-Content -LiteralPath $fakeGCli -Value '' -Encoding ascii

    @{
      GCliExePath = $fakeGCli
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:localConfigPath -Encoding utf8

    $resolved = Resolve-GCliPath
    $resolved | Should -Be (Resolve-Path -LiteralPath $fakeGCli).Path
  }

  It 'prefers g-cli path from environment variables when present' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'g-cli resolution only applies on Windows'
      return
    }

    $previous = $env:GCLI_EXE_PATH
    try {
      $tempRoot = Join-Path $TestDrive 'gcli-env'
      New-Item -ItemType Directory -Path $tempRoot | Out-Null
      $envGCli = Join-Path $tempRoot 'bin\g-cli.exe'
      New-Item -ItemType Directory -Path (Split-Path -Parent $envGCli) -Force | Out-Null
      Set-Content -LiteralPath $envGCli -Value '' -Encoding ascii
      $env:GCLI_EXE_PATH = (Resolve-Path -LiteralPath $envGCli).Path

      $resolved = Resolve-GCliPath
      $resolved | Should -Be (Resolve-Path -LiteralPath $envGCli).Path
    }
    finally {
      $env:GCLI_EXE_PATH = $previous
    }
  }

  It 'resolves LabVIEW executable from versioned config entries' {
    $tempRoot = Join-Path $TestDrive 'labview-config'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $lv2021x86 = Join-Path $tempRoot 'LabVIEW2021x86.exe'
    Set-Content -LiteralPath $lv2021x86 -Value '' -Encoding ascii

    $configJson = @{
      versions = @{
        '2021' = @{
          '32' = @{
            LabVIEWExePath = $lv2021x86
          }
        }
      }
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $script:localConfigPath -Value $configJson -Encoding utf8

    $resolved = Find-LabVIEWVersionExePath -Version 2021 -Bitness 32
    $resolved | Should -Be (Resolve-Path -LiteralPath $lv2021x86).Path
  }

  It 'returns null when required LabVIEW version is missing' {
    '{}' | Set-Content -LiteralPath $script:localConfigPath -Encoding utf8
    $resolved = Find-LabVIEWVersionExePath -Version 2099 -Bitness 64
    $resolved | Should -Be $null
  }
}
