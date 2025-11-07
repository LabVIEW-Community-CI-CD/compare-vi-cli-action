$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'LabVIEW CLI provider' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:providerModulePath = Join-Path $repoRoot 'tools/providers/labviewcli/Provider.psm1'
    Test-Path -LiteralPath $script:providerModulePath | Should -BeTrue
    $script:providerModule = Import-Module $script:providerModulePath -Force -PassThru
  }
  AfterAll {
    if ($script:providerModule) {
      Remove-Module -ModuleInfo $script:providerModule -ErrorAction SilentlyContinue
    }
  }

  BeforeEach {
    $script:prevLabVIEWPath = $env:LABVIEW_PATH
    $script:prevLabVIEWExe = $env:LABVIEW_EXE_PATH
  }

  AfterEach {
    if ($script:prevLabVIEWPath) { Set-Item Env:LABVIEW_PATH $script:prevLabVIEWPath } else { Remove-Item Env:LABVIEW_PATH -ErrorAction SilentlyContinue }
    if ($script:prevLabVIEWExe) { Set-Item Env:LABVIEW_EXE_PATH $script:prevLabVIEWExe } else { Remove-Item Env:LABVIEW_EXE_PATH -ErrorAction SilentlyContinue }
  }

  It 'includes -LabVIEWPath when parameters specify a LabVIEW path' {
    $labviewPath = Join-Path $TestDrive 'LabVIEW.exe'
    Set-Content -LiteralPath $labviewPath -Value '' -Encoding utf8

    $resolvedPath = (Resolve-Path -LiteralPath $labviewPath).Path
    $args = InModuleScope $script:providerModule.Name {
      param($lvPath)
      Get-LabVIEWCliArgs -Operation 'CreateComparisonReport' -Params @{
        vi1 = 'C:\repo\Base.vi'
        vi2 = 'C:\repo\Head.vi'
        labviewPath = $lvPath
      }
    } -ArgumentList $resolvedPath

    $args | Should -Not -BeNullOrEmpty
    $args | Should -Contain '-LabVIEWPath'
    $index = [Array]::IndexOf($args, '-LabVIEWPath')
    $index | Should -BeGreaterThan 0
    $args[$index + 1] | Should -Be $resolvedPath
  }

  It 'resolves LabVIEW path from environment when parameters omit it' {
    $labviewPath = Join-Path $TestDrive 'LabVIEW2025.exe'
    Set-Content -LiteralPath $labviewPath -Value '' -Encoding utf8
    Set-Item Env:LABVIEW_PATH (Resolve-Path -LiteralPath $labviewPath).Path

    $args = InModuleScope $script:providerModule.Name {
      Get-LabVIEWCliArgs -Operation 'CreateComparisonReport' -Params @{
        vi1 = 'C:\repo\Base.vi'
        vi2 = 'C:\repo\Head.vi'
      }
    }

    $args | Should -Contain '-LabVIEWPath'
    $index = [Array]::IndexOf($args, '-LabVIEWPath')
    $args[$index + 1] | Should -Be (Resolve-Path -LiteralPath $labviewPath).Path
  }

}

Describe 'LabVIEW CLI dispatcher' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:cliModulePath = Join-Path $repoRoot 'tools/LabVIEWCli.psm1'
    Test-Path -LiteralPath $script:cliModulePath | Should -BeTrue
    $script:cliModule = Import-Module $script:cliModulePath -Force -PassThru
  }
  AfterAll {
    if ($script:cliModule) {
      Remove-Module -ModuleInfo $script:cliModule -ErrorAction SilentlyContinue
    }
  }

  It 'quotes LabVIEWPath in the preview command line' {
    $cliStubPath = Join-Path $TestDrive 'Shared Tools\LabVIEW CLI\LabVIEWCLI.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $cliStubPath) -Force | Out-Null
    Set-Content -LiteralPath $cliStubPath -Value '' -Encoding utf8
    $labviewPath = Join-Path $TestDrive 'Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $labviewPath) -Force | Out-Null
    Set-Content -LiteralPath $labviewPath -Value '' -Encoding utf8

    $originalCli = $env:LABVIEWCLI_PATH
    try {
      Set-Item Env:LABVIEWCLI_PATH $cliStubPath
      $preview = InModuleScope $script:cliModule.Name {
        param($lvPath)
        Invoke-LVOperation -Operation 'CloseLabVIEW' -Params @{ labviewPath = $lvPath } -Preview
      } -ArgumentList $labviewPath

      $preview.command.Trim().StartsWith('"') | Should -BeTrue
      $preview.command | Should -Match '-LabVIEWPath\s+"[^"]*LabVIEW\.exe"'
      $preview.args | Should -Contain '-LabVIEWPath'
    } finally {
      if ($originalCli) {
        Set-Item Env:LABVIEWCLI_PATH $originalCli
      } else {
        Remove-Item Env:LABVIEWCLI_PATH -ErrorAction SilentlyContinue
      }
    }
  }
}
