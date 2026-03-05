$ErrorActionPreference = 'Stop'

Describe 'Find-VIComparisonCandidates.ps1' -Tag 'Compare','Analysis','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name scriptPath -Value (Join-Path $repoRoot 'tools/compare/Find-VIComparisonCandidates.ps1')
        Test-Path -LiteralPath $script:scriptPath | Should -BeTrue "Candidate discovery script not found."
    }

    BeforeEach {
        $script:testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:testRoot | Out-Null

        Push-Location $script:testRoot
        git init --quiet | Out-Null
        git config user.email "tester@example.com" | Out-Null
        git config user.name "Tester" | Out-Null

        $script:viPath = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
        $script:renameSource = 'resource/plugins/NIIconEditor/Support/ApplyLibIconOverlayToVIIcon.vi'
        $script:renameTarget = 'resource/plugins/NIIconEditor/Support/ApplyLibIconOverlayToVIIcon_Renamed.vi'
        $script:ignoredPath = 'docs/readme.txt'

        foreach ($path in @($script:viPath, $script:renameSource, $script:ignoredPath)) {
            $dir = Split-Path -Parent (Join-Path $script:testRoot $path)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:testRoot $path) -Value "content for $path" -NoNewline
        }

        git add . | Out-Null
        git commit -m 'initial baseline' --quiet | Out-Null
        $script:baseline = (git rev-parse HEAD).Trim()

        Set-Content -LiteralPath (Join-Path $script:testRoot $script:viPath) -Value 'modified vi content' -NoNewline
        git commit -am 'modify vi payload' --quiet | Out-Null
        $script:modifyCommit = (git rev-parse HEAD).Trim()

        Remove-Item -LiteralPath (Join-Path $script:testRoot $script:renameTarget) -ErrorAction SilentlyContinue
        git mv $script:renameSource $script:renameTarget | Out-Null
        git commit -m 'rename support vi' --quiet | Out-Null
        $script:renameCommit = (git rev-parse HEAD).Trim()

        Pop-Location
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'reports VI binaries that changed between refs' {
        $result = & $script:scriptPath `
            -RepoPath $script:testRoot `
            -BaseRef $script:baseline `
            -HeadRef $script:renameCommit

        $result.kinds | Should -Contain 'vi'
        $result.totalCommits | Should -Be 2
        $result.totalFiles   | Should -Be 2

        $modify = $result.commits | Where-Object { $_.commit -eq $script:modifyCommit }
        $modify | Should -Not -BeNullOrEmpty
        $modify.fileCount | Should -Be 1
        $modify.files[0].path | Should -Be $script:viPath
        $modify.files[0].status | Should -Be 'M'

        $rename = $result.commits | Where-Object { $_.commit -eq $script:renameCommit }
        $rename | Should -Not -BeNullOrEmpty
        $rename.fileCount | Should -Be 1
        $rename.files[0].status | Should -Match '^R'
        $rename.files[0].path | Should -Be $script:renameTarget
        $rename.files[0].oldPath | Should -Be $script:renameSource
    }

    It 'honors overrides for max commits and output path' {
        $outputPath = Join-Path $TestDrive 'vi-changes.json'

        $result = & $script:scriptPath `
            -RepoPath $script:testRoot `
            -HeadRef $script:renameCommit `
            -MaxCommits 1 `
            -OutputPath $outputPath

        $result.totalCommits | Should -Be 1
        $result.commits[0].commit | Should -Be $script:renameCommit
        Test-Path -LiteralPath $outputPath | Should -BeTrue

        $json = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $json.totalCommits | Should -Be 1
        $json.commits[0].files[0].path | Should -Be $script:renameTarget
    }
}
