#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'g-cli provider' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:providerModulePath = Join-Path $repoRoot 'tools/providers/gcli/gcli.Provider.psd1'
        Test-Path -LiteralPath $script:providerModulePath | Should -BeTrue
        Remove-Module Provider -Force -ErrorAction SilentlyContinue
        Import-Module $script:providerModulePath -Force | Out-Null
        $script:providerCommand = Get-Command New-GCliProvider -ErrorAction Stop
        $probeProvider = & $script:providerCommand
        if ($null -eq $probeProvider) {
            throw 'New-GCliProvider returned null during initialization.'
        }
    }

    BeforeEach {
        $script:prevGCli = $env:GCLI_EXE_PATH
    }

    AfterEach {
        if ($script:prevGCli) {
            Set-Item Env:GCLI_EXE_PATH $script:prevGCli
        } else {
            Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
        }
    }

    It 'resolves g-cli path from environment overrides' {
        $fakeExe = Join-Path $TestDrive 'g-cli.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $fakeExe) -Force | Out-Null
        Set-Content -LiteralPath $fakeExe -Value '' -Encoding utf8
        $resolvedFake = (Resolve-Path -LiteralPath $fakeExe).Path
        Set-Item Env:GCLI_EXE_PATH $resolvedFake

        $provider = New-GCliProvider
        if ($null -eq $provider) { throw 'Provider returned null.' }

        $binaryPath = $provider.ResolveBinaryPath()
        $binaryPath | Should -Be $resolvedFake
    }

    It 'builds arguments for VipbBuild operation' {
        $provider = New-GCliProvider
        if ($null -eq $provider) { throw 'Provider returned null.' }
        $provider.Supports('VipbBuild') | Should -BeTrue

        $args = $provider.BuildArgs('VipbBuild', @{
                buildSpecPath    = 'C:\specs\Icon.vipb'
                buildVersion     = '1.2.3.4'
                releaseNotesPath = 'C:\notes\release.md'
                labviewVersion   = 2025
                architecture     = 32
                timeoutSeconds   = 120
        })

        $args | Should -Not -BeNullOrEmpty
        $args | Should -Be @(
            '--lv-ver','2025',
            '--arch','32',
            'vipb',
            '--',
            '--buildspec','C:\specs\Icon.vipb',
            '-v','1.2.3.4',
            '--release-notes','C:\notes\release.md',
            '--timeout','120'
        )
    }

    It 'builds arguments for VipcInstall operation' {
        $provider = New-GCliProvider
        if ($null -eq $provider) { throw 'Provider returned null.' }
        $provider.Supports('VipcInstall') | Should -BeTrue

        $args = $provider.BuildArgs('VipcInstall', @{
                vipcPath       = 'C:\tooling\bundle.vipc'
                applyVipcPath  = 'C:\repo\vendor\Applyvipc.vi'
                targetVersion  = '2025'
                labviewVersion = '2025'
                labviewBitness = 64
        })

        $args | Should -Be @(
            '--lv-ver','2025',
            '--arch','64',
            '-v','C:\repo\vendor\Applyvipc.vi',
            '--',
            'C:\tooling\bundle.vipc',
            '2025'
        )
    }
}
