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

  BeforeEach {
    $script:envSnapshot = @{
      LABVIEW_PATH        = $env:LABVIEW_PATH
      LABVIEW_EXE_PATH    = $env:LABVIEW_EXE_PATH
      LABVIEWCLI_PATH     = $env:LABVIEWCLI_PATH
      LABVIEW_CLI_PATH    = $env:LABVIEW_CLI_PATH
      'ProgramFiles'      = $env:ProgramFiles
      'ProgramFiles(x86)' = ${env:ProgramFiles(x86)}
      LVCOMPARE_PATH      = $env:LVCOMPARE_PATH
    }
  }

  AfterEach {
    foreach ($entry in $script:envSnapshot.GetEnumerator()) {
      $name = $entry.Key
      $value = $entry.Value
      $targetName = if ($name -eq 'ProgramFiles(x86)') { 'ProgramFiles(x86)' } else { $name }
      [Environment]::SetEnvironmentVariable($targetName, $value, 'Process')
    }

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

  It 'filters 32-bit LabVIEW paths when resolving the 2025 environment' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'LabVIEW environment resolution only applies on Windows'
      return
    }

    $tempRoot = Join-Path $TestDrive 'labview-env-x86'
    $pf64 = Join-Path $tempRoot 'Program Files'
    $pf86 = Join-Path $tempRoot 'Program Files (x86)'
    New-Item -ItemType Directory -Path $pf64, $pf86 -Force | Out-Null

    $x86Exe = Join-Path $pf86 'National Instruments\LabVIEW 2025\LabVIEW.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $x86Exe) -Force | Out-Null
    Set-Content -LiteralPath $x86Exe -Value '' -Encoding ascii

    [Environment]::SetEnvironmentVariable('ProgramFiles', $pf64, 'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $pf86, 'Process')
    [Environment]::SetEnvironmentVariable('LABVIEW_PATH', $x86Exe, 'Process')
    [Environment]::SetEnvironmentVariable('LABVIEW_EXE_PATH', $x86Exe, 'Process')

    $threw = $false
    try {
      Resolve-LabVIEW2025Environment -ThrowOnMissing
    } catch {
      $threw = $true
      $_.Exception.Message | Should -Match 'LabVIEW 2025 \(64-bit\) executable not found'
    }
    $threw | Should -BeTrue

    $resolved = Resolve-LabVIEW2025Environment
    $resolved.LabVIEWExePath | Should -Be $null
    $resolved.LabVIEWCliPath | Should -Be $null
  }

  It 'returns canonical 64-bit LabVIEW paths when available' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'LabVIEW environment resolution only applies on Windows'
      return
    }

    $tempRoot = Join-Path $TestDrive 'labview-env-64'
    $pf64 = Join-Path $tempRoot 'Program Files'
    $pf86 = Join-Path $tempRoot 'Program Files (x86)'
    New-Item -ItemType Directory -Path $pf64, $pf86 -Force | Out-Null

    $lvExe = Join-Path $pf64 'National Instruments\LabVIEW 2025\LabVIEW.exe'
    $cliExe = Join-Path $pf64 'National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $compareExe = Join-Path $pf64 'National Instruments\Shared\LabVIEW Compare\LVCompare.exe'

    foreach ($path in @($lvExe, $cliExe, $compareExe)) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
      Set-Content -LiteralPath $path -Value '' -Encoding ascii
    }

    [Environment]::SetEnvironmentVariable('ProgramFiles', $pf64, 'Process')
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $pf86, 'Process')
    [Environment]::SetEnvironmentVariable('LABVIEW_PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('LABVIEW_EXE_PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $cliExe, 'Process')
    [Environment]::SetEnvironmentVariable('LVCOMPARE_PATH', $compareExe, 'Process')

    $resolved = Resolve-LabVIEW2025Environment -ThrowOnMissing
    $resolved.LabVIEWExePath | Should -Be (Resolve-Path -LiteralPath $lvExe).Path
    $resolved.LabVIEWCliPath | Should -Be (Resolve-Path -LiteralPath $cliExe).Path
    $resolved.LVComparePath  | Should -Be (Resolve-Path -LiteralPath $compareExe).Path
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

  It 'resolves LabVIEWCLI path from versioned config' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'LabVIEWCLI resolution only applies on Windows'
      return
    }

    $tempRoot = Join-Path $TestDrive 'labviewcli-config'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $cliPath = Join-Path $tempRoot 'LabVIEWCLI.exe'
    Set-Content -LiteralPath $cliPath -Value '' -Encoding ascii
    $cliResolved = (Resolve-Path -LiteralPath $cliPath).Path

    $config = @{
      versions = @{
        '2025' = @{
          '64' = @{
            LabVIEWCliPath = $cliResolved
          }
        }
      }
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath $script:localConfigPath -Value $config -Encoding utf8

    $resolved = Resolve-LabVIEWCLIPath -Version 2025 -Bitness 64
    $resolved | Should -Be $cliResolved
  }

  It 'resolves VIPM path from config overrides' {
    if (-not $IsWindows) {
      Set-ItResult -Skipped -Because 'VIPM resolution only applies on Windows'
      return
    }

    $tempRoot = Join-Path $TestDrive 'vipm-config'
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $vipmPath = Join-Path $tempRoot 'VIPM.exe'
    Set-Content -LiteralPath $vipmPath -Value '' -Encoding ascii

    $config = @{
      VipmPath = $vipmPath
    } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $script:localConfigPath -Value $config -Encoding utf8

    $resolved = Resolve-VIPMPath
    $resolved | Should -Be (Resolve-Path -LiteralPath $vipmPath).Path
  }
}
