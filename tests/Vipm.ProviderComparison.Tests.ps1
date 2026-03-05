#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Invoke-ProviderComparison.ps1' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:comparisonScript = Join-Path $repoRoot 'tools' 'Vipm' 'Invoke-ProviderComparison.ps1'
        Test-Path -LiteralPath $script:comparisonScript | Should -BeTrue

        $script:defaultVipc = Join-Path $repoRoot '.github' 'actions' 'apply-vipc' 'runner_dependencies.vipc'
        Test-Path -LiteralPath $script:defaultVipc | Should -BeTrue
    }

    It 'emits telemetry even when VIPM provider cannot resolve binaries' {
        $outputPath = Join-Path $TestDrive 'vipm-matrix.json'
        $scenario = @(
            @{
                Name      = 'unit-test-install'
                Operation = 'InstallVipc'
                VipcPath  = $script:defaultVipc
                Targets   = @(
                    @{ LabVIEWVersion = '2025'; SupportedBitness = '64' }
                )
            }
        )

        $results = & $script:comparisonScript `
            -Providers @('vipm') `
            -Scenario $scenario `
            -OutputPath $outputPath

        $results | Should -Not -BeNull
        $results.Count | Should -BeGreaterThan 0
        Test-Path -LiteralPath $outputPath | Should -BeTrue

        $first = $results | Select-Object -First 1
        $first.scenario | Should -Be 'unit-test-install'
        $first.provider | Should -Be 'vipm'
        $first.operation | Should -Be 'InstallVipc'
        $first.status | Should -Not -BeNullOrEmpty
    }
}
