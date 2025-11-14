#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Invoke-VipmDependencies.ps1 argument handling' -Tag 'Unit','VipmDependencies' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Invoke-VipmDependencies.ps1'
        Test-Path -LiteralPath $script:scriptPath -PathType Leaf | Should -BeTrue
    }

    BeforeEach {
        Push-Location $script:repoRoot
    }

    AfterEach {
        Pop-Location
    }

    It 'applies dependencies for each version/bitness combination via vipm-gcli' {
        $vipc = New-TemporaryFile
        Set-Content -LiteralPath $vipc -Value 'stub vipc'

        Mock -ModuleName VipmDependencyHelpers Test-VipmCliReady { }
        Mock -ModuleName VipmDependencyHelpers Install-VipmVipc {
            [pscustomobject]@{
                version  = $LabVIEWVersion
                bitness  = $LabVIEWBitness
                packages = @()
            }
        }

        & $script:scriptPath `
            -MinimumSupportedLVVersion 2021 `
            -VIP_LVVersion 2023 `
            -SupportedBitness '32,64' `
            -VIPCPath $vipc

        Assert-MockCalled Test-VipmCliReady -ModuleName VipmDependencyHelpers -Times 4 -Exactly
        Assert-MockCalled Install-VipmVipc -ModuleName VipmDependencyHelpers -Times 4 -Exactly
    }

    It 'rejects providers other than vipm-gcli' {
        $vipc = New-TemporaryFile
        Set-Content -LiteralPath $vipc -Value 'stub vipc'

        { & $script:scriptPath -MinimumSupportedLVVersion 2021 -VIP_LVVersion 2023 -SupportedBitness 64 -VIPCPath $vipc -ProviderName 'vipm' } |
            Should -Throw '*Provider ''vipm'' is not supported*'
    }
}
