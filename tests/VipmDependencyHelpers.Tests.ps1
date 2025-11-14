#Requires -Version 7.0
#Requires -Modules Pester

Describe 'VipmDependencyHelpers' -Tag 'Vipm','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $modulePath = Join-Path $repoRoot 'tools' 'icon-editor' 'VipmDependencyHelpers.psm1'
        Test-Path -LiteralPath $modulePath | Should -BeTrue
        $script:module = Import-Module $modulePath -Force -PassThru
        $script:moduleName = $script:module.Name

        $vipmModulePath = Join-Path $repoRoot 'tools' 'Vipm.psm1'
        Test-Path -LiteralPath $vipmModulePath | Should -BeTrue
        Import-Module $vipmModulePath -Force | Out-Null
    }

    Context 'Initialize-VipmTelemetry' {
        It 'creates telemetry directory when missing' {
        $repoRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $repoRoot | Out-Null

        $path = Initialize-VipmTelemetry -RepoRoot $repoRoot
        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
    }
    }

    Context 'Show-VipmDependencies' {
        It 'returns packages and writes telemetry log' {
            $pkgInfo = [pscustomobject]@{
                rawOutput = 'mock output'
                packages  = @(
                    [pscustomobject]@{ name = 'pkg1'; identifier = 'id1'; version = '1.0.0' }
                )
            }

        Mock -ModuleName $script:moduleName Get-VipmInstalledPackages { $pkgInfo }
        Mock -ModuleName $script:moduleName Write-VipmInstalledPackagesLog { 'log-path' }

        $result = Show-VipmDependencies -LabVIEWVersion '2026' -LabVIEWBitness '64' -TelemetryRoot $TestDrive -ProviderName 'vipm'

        $result.packages.Count | Should -Be 1
        Assert-MockCalled Get-VipmInstalledPackages -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Write-VipmInstalledPackagesLog -ModuleName $script:moduleName -Times 1
    }

        It 'throws when provider cannot emit display info' {
        { Show-VipmDependencies -LabVIEWVersion '2026' -LabVIEWBitness '64' -TelemetryRoot $TestDrive -ProviderName 'vipm-gcli' } |
            Should -Throw '*DisplayOnly mode requires the classic*'
    }
    }

    Context 'Install-VipmVipc' {
        It 'invokes VIPM provider and records telemetry' {
            $vipc = Join-Path $TestDrive 'deps.vipc'
            Set-Content -LiteralPath $vipc -Value 'stub'
            $pkgInfo = [pscustomobject]@{
                rawOutput = 'mock output'
                packages  = @(
                    [pscustomobject]@{ name = 'pkg1'; identifier = 'id1'; version = '1.0.0' }
                )
            }

        Mock -ModuleName $script:moduleName Get-VipmInvocation {
            [pscustomobject]@{
                Provider  = 'vipm'
                Binary    = 'vipm'
                Arguments = @('install')
            }
        }
        Mock -ModuleName $script:moduleName Invoke-VipmProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = 'ok'; StdErr = '' }
        }
        Mock -ModuleName $script:moduleName Write-VipmTelemetryLog { 'telemetry-log' }
        Mock -ModuleName $script:moduleName Get-VipmInstalledPackages { $pkgInfo }
        Mock -ModuleName $script:moduleName Write-VipmInstalledPackagesLog { 'installed-log' }

        $result = Install-VipmVipc -VipcPath $vipc -LabVIEWVersion '2026' -LabVIEWBitness '64' -RepoRoot $TestDrive -TelemetryRoot $TestDrive -ProviderName 'vipm'

        $result.packages.Count | Should -Be 1
        Assert-MockCalled Get-VipmInvocation -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Invoke-VipmProcess -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Write-VipmTelemetryLog -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Get-VipmInstalledPackages -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Write-VipmInstalledPackagesLog -ModuleName $script:moduleName -Times 1
    }

        It 'adds g-cli specific parameters when provider is vipm-gcli' {
        $vipc = Join-Path $TestDrive 'deps.vipc'
        Set-Content -LiteralPath $vipc -Value 'stub'
        $applyRoot = Join-Path $TestDrive 'vendor\icon-editor\Tooling\deployment'
        New-Item -ItemType Directory -Path $applyRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $applyRoot 'Applyvipc.vi') -Value '' -Encoding utf8

        $capturedParams = $null
        Mock -ModuleName $script:moduleName Get-VipmInvocation {
            param($Operation,$Params,$ProviderName)
            $script:capturedParams = $Params
            [pscustomobject]@{
                Provider  = 'vipm-gcli'
                Binary    = 'g-cli'
                Arguments = @('--lv-ver','2025')
            }
        }
        Mock -ModuleName $script:moduleName Invoke-VipmProcess {
            [pscustomobject]@{ ExitCode = 0; StdOut = 'ok'; StdErr = '' }
        }
        Mock -ModuleName $script:moduleName Write-VipmTelemetryLog { 'telemetry-log' }

        $result = Install-VipmVipc -VipcPath $vipc -LabVIEWVersion '2025' -LabVIEWBitness '64' -RepoRoot $TestDrive -TelemetryRoot $TestDrive -ProviderName 'vipm-gcli'

        $script:capturedParams.applyVipcPath | Should -Match 'Applyvipc\.vi$'
        $script:capturedParams.targetVersion | Should -Match '64-bit'
        $result.packages.Count | Should -Be 0
        Assert-MockCalled Get-VipmInvocation -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Invoke-VipmProcess -ModuleName $script:moduleName -Times 1
        Assert-MockCalled Write-VipmTelemetryLog -ModuleName $script:moduleName -Times 1
    }
}
}
