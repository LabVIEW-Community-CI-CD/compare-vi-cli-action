#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'VIPM provider module' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:providerModulePath = Join-Path $repoRoot 'tools/providers/vipm/vipm.Provider.psd1'
        Test-Path -LiteralPath $script:providerModulePath | Should -BeTrue
        Remove-Module -Name Provider -Force -ErrorAction SilentlyContinue
        $script:providerModule = Import-Module $script:providerModulePath -Force -PassThru
    }

    BeforeEach {
        $script:prevVipmPath = $env:VIPM_PATH
    }

    AfterEach {
        if ($script:prevVipmPath) {
            Set-Item Env:VIPM_PATH $script:prevVipmPath
        } else {
            Remove-Item Env:VIPM_PATH -ErrorAction SilentlyContinue
        }
    }

    AfterAll {
        if ($script:providerModule) {
            Remove-Module -ModuleInfo $script:providerModule -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Module -Name Provider -Force -ErrorAction SilentlyContinue
        }
    }

    It 'resolves VIPM path from environment overrides' {
        $fakeExe = Join-Path $TestDrive 'VIPM.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExe) -Force | Out-Null
        Set-Content -LiteralPath $fakeExe -Value '' -Encoding utf8
        Set-Item Env:VIPM_PATH (Resolve-Path -LiteralPath $fakeExe).Path

        $resolved = InModuleScope $script:providerModule {
            $provider = New-VipmProvider
            $provider.ResolveBinaryPath()
        }

        $resolved | Should -Be (Resolve-Path -LiteralPath $fakeExe).Path
    }

    It 'resolves VIPM path when environment points to installation directory' {
        $fakeRoot = Join-Path $TestDrive 'vipm'
        New-Item -ItemType Directory -Path $fakeRoot -Force | Out-Null
        $fakeExe = Join-Path $fakeRoot 'VIPM.exe'
        Set-Content -LiteralPath $fakeExe -Value '' -Encoding utf8
        $resolvedRoot = (Resolve-Path -LiteralPath $fakeRoot).Path
        Set-Item Env:VIPM_PATH $resolvedRoot

        $resolved = InModuleScope $script:providerModule {
            Mock Resolve-VIPMPath { return $env:VIPM_PATH }
            $provider = New-VipmProvider
            $provider.ResolveBinaryPath()
        }

        $resolved | Should -Be (Resolve-Path -LiteralPath $fakeExe).Path
    }

    It 'invokes resolved VIPM binary via provider interface' {
        $vipmCmd = Get-Command vipm -ErrorAction Stop
        Set-Item Env:VIPM_PATH $vipmCmd.Source

        $resolved = InModuleScope $script:providerModule {
            $provider = New-VipmProvider
            $provider.ResolveBinaryPath()
        }
        $resolved | Should -Be (Resolve-Path -LiteralPath $vipmCmd.Source).Path

        $output = & $resolved '--help' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'A command-line interface for VIPM'
    }

    Context 'argument generation' {
        It 'builds InstallVipc arguments' {
            $args = InModuleScope $script:providerModule {
                Get-VipmArgs -Operation 'InstallVipc' -Params @{
                    vipcPath       = 'C:\tooling\bundle.vipc'
                    labviewVersion = '2025'
                    labviewBitness = '64'
                    additionalOptions = @('-foo','bar')
                }
            }

            $args | Should -Be @(
                '-vipc','C:\tooling\bundle.vipc',
                '-q',
                '-lvversion','2025',
                '-lvbitness','64',
                '-foo','bar'
            )
        }

        It 'builds BuildVip arguments' {
            $args = InModuleScope $script:providerModule {
                Get-VipmArgs -Operation 'BuildVip' -Params @{
                    vipbPath          = 'C:\tooling\package.vipb'
                    outputDirectory   = 'C:\tooling\out'
                    buildVersion      = '1.2.3.4'
                    additionalOptions = @('-silent')
                }
            }

            $args | Should -Be @(
                '-vipb','C:\tooling\package.vipb',
                '-q',
                '-output','C:\tooling\out',
                '-version','1.2.3.4',
                '-silent'
            )
        }
    }

    It 'advertises supported operations via provider interface' {
        InModuleScope $script:providerModule {
            $provider = New-VipmProvider
            $provider.Supports('InstallVipc') | Should -BeTrue
            $provider.Supports('BuildVip')    | Should -BeTrue
            $provider.Supports('ListPackages') | Should -BeFalse

            $buildArgs = $provider.BuildArgs('BuildVip', @{
                vipbPath        = 'C:\tmp\icon.vipb'
                outputDirectory = 'C:\tmp\dist'
                buildVersion    = '1.0.0.0'
            })
            $buildArgs | Should -Be @(
                '-vipb','C:\tmp\icon.vipb',
                '-q',
                '-output','C:\tmp\dist',
                '-version','1.0.0.0'
            )
        }
    }
}

