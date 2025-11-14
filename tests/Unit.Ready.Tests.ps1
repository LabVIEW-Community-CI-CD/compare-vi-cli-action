#Requires -Version 7.0
#Requires -Modules Pester

Describe 'Unit readiness helper' -Tag 'Unit','Infrastructure' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:helperPath = Join-Path $repoRoot 'tools' 'icon-editor' 'Prepare-UnitTestState.ps1'
        Test-Path -LiteralPath $script:helperPath | Should -BeTrue
    }

    It 'executes in guidance mode without validation' {
        { & pwsh -NoLogo -NoProfile -File $script:helperPath } | Should -Not -Throw
    }

    It 'surfaces validation errors gracefully' {
        { & pwsh -NoLogo -NoProfile -File $script:helperPath -Validate } | Should -Throw '*Unit-test prerequisites are not satisfied*'
    }
}
