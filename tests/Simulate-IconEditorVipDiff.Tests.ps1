$ErrorActionPreference = 'Stop'

Describe 'Simulate-IconEditorBuild VIP diff' {
    BeforeAll {
        $repoRoot = (git rev-parse --show-toplevel).Trim()
        $simulateScript = Join-Path $repoRoot 'tools/icon-editor/Simulate-IconEditorBuild.ps1'
        $invokeDiffScript = Join-Path $repoRoot 'tools/icon-editor/Invoke-FixtureViDiffs.ps1'
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name simulateScript -Value (Get-Item -LiteralPath $simulateScript)
        Set-Variable -Scope Script -Name invokeDiffScript -Value (Get-Item -LiteralPath $invokeDiffScript)
    }

    It 'generates VIP diff requests during simulation' {
        $resultsRoot = Join-Path $TestDrive 'results'
        $vipDiffDir = Join-Path $resultsRoot 'vip-vi-diff'
        $requestsPath = Join-Path $vipDiffDir 'vi-diff-requests.json'
        $capturesRoot = Join-Path $resultsRoot 'vip-vi-diff-captures'

        $expectedVersion = [ordered]@{
            major  = 1
            minor  = 4
            patch  = 1
            build  = 948
            commit = 'fixture'
        }

        $fixturePath = $env:ICON_EDITOR_FIXTURE_PATH
        if (-not $fixturePath -or -not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_FIXTURE_PATH not supplied; skipping simulation diff test.'
            return
        }

        & $script:simulateScript `
            -FixturePath $fixturePath `
            -ResultsRoot $resultsRoot `
            -ExpectedVersion $expectedVersion `
            -VipDiffOutputDir $vipDiffDir `
            -VipDiffRequestsPath $requestsPath | Out-Null

        Test-Path -LiteralPath $requestsPath | Should -BeTrue
        $requestJson = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json
        $requestJson.count | Should -BeGreaterThan 0
        $requestJson.requests.Count | Should -BeGreaterThan 0

        $headSample = Get-ChildItem -LiteralPath (Join-Path $vipDiffDir 'head') -Filter '*.vi' -Recurse | Select-Object -First 1
        $headSample | Should -Not -BeNull

        $summary = & $script:invokeDiffScript `
            -RequestsPath $requestsPath `
            -CapturesRoot $capturesRoot `
            -SummaryPath (Join-Path $capturesRoot 'vi-comparison-summary.json') `
            -DryRun

        $summary.counts.dryRun | Should -BeGreaterThan 0
    }
}

