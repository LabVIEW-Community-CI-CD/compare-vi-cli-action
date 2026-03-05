$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'LabVIEW CLI provider' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:providerModulePath = Join-Path $repoRoot 'tools/providers/labviewcli/Provider.psm1'
    Test-Path -LiteralPath $script:providerModulePath | Should -BeTrue
    $script:providerModule = Import-Module $script:providerModulePath -Force -PassThru
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

  It 'maps headless and logToConsole booleans for CreateComparisonReport' {
    $args = InModuleScope $script:providerModule.Name {
      Get-LabVIEWCliArgs -Operation 'CreateComparisonReport' -Params @{
        vi1 = 'C:\repo\Base.vi'
        vi2 = 'C:\repo\Head.vi'
        headless = $true
        logToConsole = $false
      }
    }

    $args | Should -Contain '-Headless'
    $headlessIndex = [Array]::IndexOf($args, '-Headless')
    $args[$headlessIndex + 1] | Should -Be 'true'

    $args | Should -Contain '-LogToConsole'
    $logIndex = [Array]::IndexOf($args, '-LogToConsole')
    $args[$logIndex + 1] | Should -Be 'false'
  }

  It 'normalizes string boolean tokens for CreateComparisonReport' {
    $args = InModuleScope $script:providerModule.Name {
      Get-LabVIEWCliArgs -Operation 'CreateComparisonReport' -Params @{
        vi1 = 'C:\repo\Base.vi'
        vi2 = 'C:\repo\Head.vi'
        headless = '1'
        logToConsole = 'false'
      }
    }

    $headlessIndex = [Array]::IndexOf($args, '-Headless')
    $args[$headlessIndex + 1] | Should -Be 'true'
    $logIndex = [Array]::IndexOf($args, '-LogToConsole')
    $args[$logIndex + 1] | Should -Be 'false'
  }

  It 'fails on unsupported boolean tokens for CreateComparisonReport' {
    {
      InModuleScope $script:providerModule.Name {
        Get-LabVIEWCliArgs -Operation 'CreateComparisonReport' -Params @{
          vi1 = 'C:\repo\Base.vi'
          vi2 = 'C:\repo\Head.vi'
          headless = 'maybe'
        }
      }
    } | Should -Throw "*headless*"
  }
}
