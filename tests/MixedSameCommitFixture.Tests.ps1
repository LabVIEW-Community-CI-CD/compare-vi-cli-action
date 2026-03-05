#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Mixed same-commit VI history fixture' {
    BeforeAll {
        $repoRoot = (Get-Location).Path
        $script:FixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'mixed-same-commit.json'
        Test-Path -LiteralPath $script:FixturePath -PathType Leaf | Should -BeTrue
        $script:Fixture = Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'defines a valid mixed same-commit schema' {
        $script:Fixture.schema | Should -Be 'vi-history-mixed-commit@v1'
        $script:Fixture.commit | Should -Not -BeNullOrEmpty
        $script:Fixture.commit.changes | Should -Not -BeNullOrEmpty
        ($script:Fixture.commit.changes.Count -ge 2) | Should -BeTrue
    }

    It 'references valid on-disk targets and sources with stable diff requirements' {
        $repoRoot = (Get-Location).Path
        $changeIds = New-Object System.Collections.Generic.HashSet[string]
        $strictCount = 0
        $nonStrictCount = 0

        foreach ($change in $script:Fixture.commit.changes) {
            [string]::IsNullOrWhiteSpace($change.targetPath) | Should -BeFalse
            [string]::IsNullOrWhiteSpace($change.source) | Should -BeFalse

            $resolvedTarget = if ([System.IO.Path]::IsPathRooted($change.targetPath)) {
                $change.targetPath
            } else {
                Join-Path $repoRoot $change.targetPath
            }
            $resolvedSource = if ([System.IO.Path]::IsPathRooted($change.source)) {
                $change.source
            } else {
                Join-Path $repoRoot $change.source
            }

            Test-Path -LiteralPath $resolvedTarget -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $resolvedSource -PathType Leaf | Should -BeTrue

            if (-not [string]::IsNullOrWhiteSpace($change.id)) {
                $changeIds.Add([string]$change.id) | Should -BeTrue
            }

            if ([bool]$change.requireDiff) {
                $strictCount += 1
                ([int]$change.minDiffs -ge 1) | Should -BeTrue
            } else {
                $nonStrictCount += 1
                ([int]$change.minDiffs -ge 0) | Should -BeTrue
            }
        }

        ($strictCount -ge 1) | Should -BeTrue
        ($nonStrictCount -ge 1) | Should -BeTrue
    }
}
