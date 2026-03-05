$ErrorActionPreference = 'Stop'

Describe 'Invoke-ValidateLocal.ps1' -Tag 'IconEditor','LocalValidate' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name scriptPath -Value (Join-Path $repoRoot 'tools/icon-editor/Invoke-ValidateLocal.ps1')
        Set-Variable -Scope Script -Name baselineFixture -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/ni_icon_editor-1.4.1.794.vip')
        Set-Variable -Scope Script -Name baselineManifest -Value (Join-Path $repoRoot 'tests/fixtures/icon-editor/fixture-manifest-1.4.1.794.json')
        $script:originalGhToken = $env:GH_TOKEN
    }

    AfterAll {
        if ($null -ne $script:originalGhToken) {
            $env:GH_TOKEN = $script:originalGhToken
        } else {
            Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        }
    }

    It 'produces outputs in dry-run mode' {
        $env:GH_TOKEN = 'local-validate-test'

        $resultsRoot = Join-Path $TestDrive 'local-validate'
        $tempManifest = Join-Path $TestDrive 'baseline-manifest.json'
        $manifest = Get-Content -LiteralPath $script:baselineManifest -Raw | ConvertFrom-Json -Depth 8
        $target = $manifest.entries | Select-Object -First 1
        $target.hash = '0000000000000000000000000000000000000000000000000000000000000000'
        $manifest.generatedAt = (Get-Date).ToString('o')
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempManifest -Encoding utf8

        & $script:scriptPath `
            -SkipBootstrap `
            -DryRun `
            -SkipLVCompare `
            -BaselineFixture $script:baselineFixture `
            -BaselineManifest $tempManifest `
            -ResultsRoot $resultsRoot | Out-Null

        $reportPath = Join-Path $resultsRoot 'fixture-report.json'
        Test-Path -LiteralPath $reportPath | Should -BeTrue

        $requestsPath = Join-Path $resultsRoot 'vi-diff\vi-diff-requests.json'
        Test-Path -LiteralPath $requestsPath | Should -BeTrue
        $requests = Get-Content -LiteralPath $requestsPath -Raw | ConvertFrom-Json -Depth 6
        $requests.count | Should -BeGreaterThan 0

        $summaryPath = Join-Path $resultsRoot 'vi-diff-captures\vi-comparison-summary.json'
        Test-Path -LiteralPath $summaryPath | Should -BeTrue
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 6
        $summary.counts.total | Should -BeGreaterThan 0

        $reportMd = Join-Path $resultsRoot 'vi-diff-captures\vi-comparison-report.md'
        Test-Path -LiteralPath $reportMd | Should -BeTrue
    }
}
