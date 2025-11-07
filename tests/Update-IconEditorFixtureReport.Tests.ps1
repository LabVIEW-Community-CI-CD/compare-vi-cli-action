$ErrorActionPreference = 'Stop'

Describe 'Update-IconEditorFixtureReport.ps1' -Tag 'IconEditor','FixtureReport','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name RepoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name UpdateScript -Value (Join-Path $repoRoot 'tools/icon-editor/Update-IconEditorFixtureReport.ps1')

        Test-Path -LiteralPath $script:UpdateScript | Should -BeTrue
    }

    It 'suppresses summary output when -NoSummary is specified' {
        $fixturePath = $env:ICON_EDITOR_FIXTURE_PATH
        if (-not $fixturePath -or -not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_FIXTURE_PATH not supplied; skipping fixture report test.'
            return
        }

        $resultsRoot   = Join-Path $TestDrive 'report-root'
        $manifestPath  = Join-Path $TestDrive 'fixture-manifest.json'
        $params = @{
            FixturePath   = $fixturePath
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

    It 'throws when the describe helper fails to emit a report' {
        $fixturePath = Join-Path $TestDrive 'synthetic.vip'
        Set-Content -LiteralPath $fixturePath -Value 'vip-stub' -Encoding utf8
        $resultsRoot = Join-Path $TestDrive 'broken-report'
        $manifestPath = Join-Path $resultsRoot 'manifest.json'

        $pwshInvocations = New-Object System.Collections.Generic.List[object]
        Mock -CommandName pwsh -MockWith {
            param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgumentList)
            $null = $pwshInvocations.Add($ArgumentList)
            Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        }

        { & $script:UpdateScript `
            -FixturePath $fixturePath `
            -ResultsRoot $resultsRoot `
            -ManifestPath $manifestPath `
            -SkipDocUpdate } | Should -Throw '*fixture-report.json*'

        $pwshInvocations.Count | Should -Be 1
        ($pwshInvocations[0] | Where-Object { $_ -is [string] -and $_ -like '*Describe-IconEditorFixture.ps1' }) | Should -Not -BeNullOrEmpty
    }
}
