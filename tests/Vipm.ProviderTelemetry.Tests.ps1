#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Test-ProviderTelemetry.ps1' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:validationScript = Join-Path $repoRoot 'tools' 'Vipm' 'Test-ProviderTelemetry.ps1'
        Test-Path -LiteralPath $script:validationScript | Should -BeTrue
    }

    It 'passes when all statuses are successful' {
        $matrixPath = Join-Path $TestDrive 'vipm-matrix.json'
        $data = @(
            [ordered]@{
                timestamp = Get-Date
                scenario  = 'install'
                provider  = 'vipm'
                operation = 'InstallVipc'
                status    = 'success'
            }
        ) | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $matrixPath -Value $data -Encoding UTF8

        $results = & $script:validationScript -InputPath $matrixPath
        $results.Count | Should -Be 1
    }

    It 'throws when failures are present' {
        $matrixPath = Join-Path $TestDrive 'vipm-matrix.json'
        $data = @(
            [ordered]@{
                timestamp = Get-Date
                scenario  = 'install'
                provider  = 'vipm'
                operation = 'InstallVipc'
                status    = 'failed'
                error     = 'simulated'
            }
        ) | ConvertTo-Json -Depth 5
        Set-Content -LiteralPath $matrixPath -Value $data -Encoding UTF8

        { & $script:validationScript -InputPath $matrixPath } | Should -Throw
    }

    It 'warns on missing file when TreatMissingAsWarning is set' {
        $missing = Join-Path $TestDrive 'missing.json'
        { & $script:validationScript -InputPath $missing -TreatMissingAsWarning } | Should -Not -Throw
    }
}

