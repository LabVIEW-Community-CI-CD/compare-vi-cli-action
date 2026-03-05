#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'PR VI history harness fixture' {
    BeforeAll {
        $repoRoot = (Get-Location).Path
        $script:FixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'pr-harness.json'
        Test-Path -LiteralPath $script:FixturePath -PathType Leaf | Should -BeTrue
        $script:Fixture = Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'defines the expected harness schema and deterministic defaults' {
        $script:Fixture.schema | Should -Be 'vi-history-pr-harness@v1'
        $script:Fixture.targetPath | Should -Not -BeNullOrEmpty
        ([int]$script:Fixture.maxPairs -ge 1) | Should -BeTrue
        $script:Fixture.scenarios | Should -Not -BeNullOrEmpty
        ($script:Fixture.scenarios.Count -ge 2) | Should -BeTrue
    }

    It 'contains diff-required scenarios with valid source paths' {
        $repoRoot = (Get-Location).Path
        $ids = New-Object System.Collections.Generic.HashSet[string]
        $requireDiffCount = 0

        foreach ($scenario in $script:Fixture.scenarios) {
            [string]::IsNullOrWhiteSpace($scenario.id) | Should -BeFalse
            [string]::IsNullOrWhiteSpace($scenario.mode) | Should -BeFalse
            $ids.Add([string]$scenario.id) | Should -BeTrue

            if ($scenario.PSObject.Properties['source']) {
                [string]::IsNullOrWhiteSpace($scenario.source) | Should -BeFalse
                $resolvedSource = if ([System.IO.Path]::IsPathRooted($scenario.source)) {
                    $scenario.source
                } else {
                    Join-Path $repoRoot $scenario.source
                }
                Test-Path -LiteralPath $resolvedSource -PathType Leaf | Should -BeTrue
            }

            if ([bool]$scenario.requireDiff) {
                $requireDiffCount += 1
            }
        }

        ($requireDiffCount -ge 2) | Should -BeTrue
        $ids.Contains('attribute') | Should -BeTrue
        $ids.Contains('sequential') | Should -BeTrue
    }
}
