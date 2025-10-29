#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Sequential VI history fixture' {
    BeforeAll {
        $repoRoot = (Get-Location).Path
        $script:FixturePath = Join-Path $repoRoot 'fixtures' 'vi-history' 'sequential.json'
        Test-Path -LiteralPath $script:FixturePath -PathType Leaf | Should -BeTrue
        $script:Fixture = Get-Content -LiteralPath $script:FixturePath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'defines a valid vi-history sequence schema' {
        $script:Fixture.schema | Should -Be 'vi-history-sequence@v1'
        [string]::IsNullOrWhiteSpace($script:Fixture.targetPath) | Should -BeFalse
        $steps = $script:Fixture.steps
        $steps | Should -Not -BeNullOrEmpty
        ($steps.Count -gt 0) | Should -BeTrue
    }

    It 'references on-disk fixture files for every step' {
        $repoRoot = (Get-Location).Path
        $targetPath = if ([System.IO.Path]::IsPathRooted($script:Fixture.targetPath)) {
            $script:Fixture.targetPath
        } else {
            Join-Path $repoRoot $script:Fixture.targetPath
        }
        Test-Path -LiteralPath $targetPath -PathType Leaf | Should -BeTrue

        $stepIds = New-Object System.Collections.Generic.HashSet[string]
        foreach ($step in $script:Fixture.steps) {
            [string]::IsNullOrWhiteSpace($step.source) | Should -BeFalse
            $resolvedSource = if ([System.IO.Path]::IsPathRooted($step.source)) {
                $step.source
            } else {
                Join-Path $repoRoot $step.source
            }
            Test-Path -LiteralPath $resolvedSource -PathType Leaf | Should -BeTrue

            if (-not [string]::IsNullOrWhiteSpace($step.id)) {
                $stepIds.Add($step.id) | Should -BeTrue
            }
        }
    }
}
