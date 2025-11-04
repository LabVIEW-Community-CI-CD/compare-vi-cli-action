$ErrorActionPreference = 'Stop'

Describe 'Stage-BuildArtifacts.ps1' -Tag 'IconEditor','Artifacts','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name stageScript -Value (Join-Path $repoRoot 'tools/icon-editor/Stage-BuildArtifacts.ps1')
        Test-Path -LiteralPath $script:stageScript | Should -BeTrue
    }

    It 'copies fixture reports into the reports bucket while preserving the source files' {
        $workspace = Join-Path $TestDrive 'results'
        New-Item -ItemType Directory -Path $workspace | Out-Null

        $manifest = Join-Path $workspace 'manifest.json'
        $metadata = Join-Path $workspace 'metadata.json'
        $fixtureJson = Join-Path $workspace 'fixture-report.json'
        $fixtureMarkdown = Join-Path $workspace 'fixture-report.md'

        '{"schema":"icon-editor/fixture-manifest@v1"}' | Set-Content -LiteralPath $manifest -Encoding utf8
        '{"schema":"icon-editor/fixture-metadata@v1"}' | Set-Content -LiteralPath $metadata -Encoding utf8
        '{"schema":"icon-editor/fixture-report@v1","fixtureOnlyAssets":[]}' | Set-Content -LiteralPath $fixtureJson -Encoding utf8
        '# Fixture Report' | Set-Content -LiteralPath $fixtureMarkdown -Encoding utf8

        $resultRaw = & $script:stageScript -ResultsRoot $workspace
        $result = $resultRaw | ConvertFrom-Json -Depth 5

        (Test-Path -LiteralPath $fixtureJson -PathType Leaf) | Should -BeTrue -Because 'fixture-report.json should remain in the results root'
        (Test-Path -LiteralPath $fixtureMarkdown -PathType Leaf) | Should -BeTrue -Because 'fixture-report.md should remain in the results root'

        $result.buckets.reports | Should -Not -BeNullOrEmpty
        $reportsRoot = $result.buckets.reports.path
        (Test-Path -LiteralPath (Join-Path $reportsRoot 'fixture-report.json') -PathType Leaf) | Should -BeTrue -Because 'fixture-report.json should be staged under reports/'
        (Test-Path -LiteralPath (Join-Path $reportsRoot 'fixture-report.md') -PathType Leaf) | Should -BeTrue -Because 'fixture-report.md should be staged under reports/'
    }

    It 'fails if required fixture reports are missing' {
        $workspace = Join-Path $TestDrive 'results-missing'
        New-Item -ItemType Directory -Path $workspace | Out-Null

        '{"schema":"icon-editor/fixture-manifest@v1"}' | Set-Content -LiteralPath (Join-Path $workspace 'manifest.json') -Encoding utf8

        $thrown = $null
        try {
            & $script:stageScript -ResultsRoot $workspace | Out-Null
        } catch {
            $thrown = $_
        }
        $thrown | Should -Not -BeNullOrEmpty -Because 'Stage-BuildArtifacts.ps1 should throw when fixture reports are missing'
        $thrown.Exception.Message | Should -Match 'Stage-BuildArtifacts.ps1 must preserve fixture reports'
    }
}
