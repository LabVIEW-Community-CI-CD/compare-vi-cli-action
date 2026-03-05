$ErrorActionPreference = 'Stop'

Describe 'Update-IconEditorFixtureReport.ps1' -Tag 'IconEditor','FixtureReport','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name RepoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name UpdateScript -Value (Join-Path $repoRoot 'tools/icon-editor/Update-IconEditorFixtureReport.ps1')

        Test-Path -LiteralPath $script:UpdateScript | Should -BeTrue
    }

    It 'suppresses summary output when -NoSummary is specified' {
        $resultsRoot   = Join-Path $TestDrive 'report-root'
        $manifestPath  = Join-Path $TestDrive 'fixture-manifest.json'
        $params = @{
            ResultsRoot   = $resultsRoot
            ManifestPath  = $manifestPath
            SkipDocUpdate = $true
            NoSummary     = $true
        }

        $output = & $script:UpdateScript @params
        $output | Should -BeNullOrEmpty

        $reportPath = Join-Path $resultsRoot 'fixture-report.json'
        Test-Path -LiteralPath $reportPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue

        $summary = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 6
        $summary.schema | Should -Be 'icon-editor/fixture-report@v1'
        ($summary.artifacts | Measure-Object).Count | Should -BeGreaterThan 0
    }
}
