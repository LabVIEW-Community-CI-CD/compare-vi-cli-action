$ErrorActionPreference = 'Stop'

Describe 'Invoke-VIDiffSweep.ps1' -Tag 'Compare','Sweep','Integration' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name sweepScript -Value (Join-Path $repoRoot 'tools/icon-editor/Invoke-VIDiffSweep.ps1')
        Test-Path -LiteralPath $script:sweepScript | Should -BeTrue "Sweep script not found."
    }

    BeforeEach {
        $script:testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:testRoot | Out-Null

        Push-Location $script:testRoot
        git init --quiet | Out-Null
        git config user.email "tester@example.com" | Out-Null
        git config user.name "Tester" | Out-Null

        $script:viPath = 'resource/plugins/NIIconEditor/Miscellaneous/Icon Editor/MenuSelection(User).vi'
        $script:ctlPath = 'resource/plugins/NIIconEditor/Miscellaneous/Icon Editor/MenuSelection(User).ctl'
        foreach ($path in @($script:viPath, $script:ctlPath)) {
            $dir = Split-Path -Parent (Join-Path $script:testRoot $path)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:testRoot $path) -Value "baseline $path" -NoNewline
        }

        git add . | Out-Null
        git commit -m 'baseline' --quiet | Out-Null
        $script:baseline = (git rev-parse HEAD).Trim()

        Set-Content -LiteralPath (Join-Path $script:testRoot $script:viPath) -Value 'updated vi' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:testRoot $script:ctlPath) -Value 'updated ctl' -NoNewline
        git commit -am 'modify vi assets' --quiet | Out-Null
        $script:headCommit = (git rev-parse HEAD).Trim()

        Pop-Location
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs the sweep and returns candidate summary' {
        $outputPath = Join-Path $TestDrive 'vi-sweep.json'
        $result = & $script:sweepScript `
            -RepoPath $script:testRoot `
            -BaseRef $script:baseline `
            -HeadRef $script:headCommit `
            -OutputPath $outputPath `
            -SummaryCount 5 `
            -SkipSync `
            -Quiet

        $result | Should -Not -BeNullOrEmpty
        $result.candidates.totalFiles | Should -Be 2
        Test-Path -LiteralPath $result.outputPath | Should -BeTrue

        $summaryJson = Get-Content -LiteralPath $result.outputPath -Raw | ConvertFrom-Json
        $summaryJson.totalCommits | Should -Be 1
        $summaryJson.commits[0].files.path | Should -Contain $script:viPath
    }
}
