#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Replay-ApplyVipcJob helpers' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $repoRoot 'tools' 'icon-editor' 'Replay-ApplyVipcJob.ps1')
    }

    It 'parses matrix job titles' {
        $parsed = Parse-ApplyVipcJobTitle -Title 'Apply VIPC Dependencies (2026, 64)'
        $parsed | Should -Not -BeNullOrEmpty
        $parsed.Version | Should -Be '2026'
        $parsed.Bitness | Should -Be 64
    }

    It 'returns null for unexpected titles' {
        $parsed = Parse-ApplyVipcJobTitle -Title 'Other job'
        $parsed | Should -BeNullOrEmpty
    }

    It 'prefers explicit parameters over job title parsing' {
        $resolved = Resolve-ApplyVipcParameters `
            -RunId $null `
            -JobName 'Apply VIPC Dependencies (2026, 64)' `
            -Repository $null `
            -LogPath $null `
            -MinimumSupportedLVVersion '2021' `
            -VipLabVIEWVersion '2021' `
            -SupportedBitness 32

        $resolved.Version | Should -Be '2021'
        $resolved.VipVersion | Should -Be '2021'
        $resolved.Bitness | Should -Be 32
    }

    It 'applies default workspace and vipc path when omitted' {
        $params = @{
            MinimumSupportedLVVersion = '2023'
            VipLabVIEWVersion         = '2026'
            SupportedBitness          = 64
            SkipExecution             = $true
        }

        { Invoke-ReplayApplyVipcJob -InitialParameters $params } | Should -Not -Throw
        ($params.Keys -contains 'Workspace') | Should -BeTrue
        ($params.Keys -contains 'VipcPath')  | Should -BeTrue
        Test-Path -LiteralPath $params.Workspace | Should -BeTrue
        $params.VipcPath | Should -Be '.github/actions/apply-vipc/runner_dependencies.vipc'
    }

    It 'routes apply replay through vipm toolchain by default' {
        $params = @{
            MinimumSupportedLVVersion = '2023'
            VipLabVIEWVersion         = '2026'
            SupportedBitness          = 64
        }

        Mock -CommandName Invoke-ApplyVipcReplay {
            param($Resolved,$Workspace,$VipcPath,$Toolchain,$SkipExecution)
        }

        Invoke-ReplayApplyVipcJob -InitialParameters $params

        Assert-MockCalled Invoke-ApplyVipcReplay -Times 1 -ParameterFilter { $Toolchain -eq 'vipm' }
    }

}
