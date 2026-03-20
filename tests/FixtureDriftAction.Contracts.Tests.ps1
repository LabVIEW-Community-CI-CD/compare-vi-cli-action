$ErrorActionPreference = 'Stop'

Describe 'fixture-drift action artifact-first contracts' -Tag 'Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $actionPath = Join-Path $repoRoot '.github' 'actions' 'fixture-drift' 'action.yml'
        Test-Path -LiteralPath $actionPath | Should -BeTrue
        $script:actionText = Get-Content -LiteralPath $actionPath -Raw
    }

    It 'uses compare-outcome.json when building PR comments' {
        $script:actionText | Should -Match 'compare-outcome\.json'
        $script:actionText | Should -Match 'compareOutcome\.reportPath'
    }

    It 'accepts custom report artifact names instead of only compare-report.html' {
        $script:actionText | Should -Match '\(\?i\)\(compare\|diff\|print\|cli-compare\|linux-compare\|windows-compare\)-report\\\.\(html\|xml\|txt\)\$'
        $script:actionText | Should -Not -Match "\$rel -match 'compare-report\.html\$'"
    }
}
