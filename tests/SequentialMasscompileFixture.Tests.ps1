#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Sequential masscompile VI history fixture' {
    BeforeAll {
        $repoRoot = (Get-Location).Path
        $script:FixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'sequential-masscompile.json'
        Test-Path -LiteralPath $script:FixturePath -PathType Leaf | Should -BeTrue
        $script:Fixture = Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'defines the expected schema and commit chain shape' {
        $script:Fixture.schema | Should -Be 'vi-history-sequence-matrix@v1'
        $script:Fixture.commits | Should -Not -BeNullOrEmpty
        ($script:Fixture.commits.Count -ge 4) | Should -BeTrue
    }

    It 'contains a multi-VI same-commit step and valid paths' {
        $repoRoot = (Get-Location).Path
        $multiViCommitCount = 0
        $strictTargets = New-Object System.Collections.Generic.HashSet[string]
        $smokeTargets = New-Object System.Collections.Generic.HashSet[string]

        foreach ($commit in $script:Fixture.commits) {
            $changes = @($commit.changes)
            $changes.Count | Should -BeGreaterThan 0
            if ($changes.Count -ge 2) {
                $multiViCommitCount += 1
            }

            foreach ($change in $changes) {
                [string]::IsNullOrWhiteSpace($change.targetPath) | Should -BeFalse
                [string]::IsNullOrWhiteSpace($change.source) | Should -BeFalse

                $targetPath = if ([System.IO.Path]::IsPathRooted($change.targetPath)) {
                    $change.targetPath
                } else {
                    Join-Path $repoRoot $change.targetPath
                }
                $sourcePath = if ([System.IO.Path]::IsPathRooted($change.source)) {
                    $change.source
                } else {
                    Join-Path $repoRoot $change.source
                }

                Test-Path -LiteralPath $targetPath -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath $sourcePath -PathType Leaf | Should -BeTrue

                if ([bool]$change.requireDiff) {
                    [void]$strictTargets.Add([string]$change.targetPath)
                    ([int]$change.minDiffs -ge 1) | Should -BeTrue
                } else {
                    [void]$smokeTargets.Add([string]$change.targetPath)
                    ([int]$change.minDiffs -ge 0) | Should -BeTrue
                }
            }
        }

        ($multiViCommitCount -ge 1) | Should -BeTrue
        ($strictTargets.Count -ge 1) | Should -BeTrue
        ($smokeTargets.Count -ge 1) | Should -BeTrue
    }
}

