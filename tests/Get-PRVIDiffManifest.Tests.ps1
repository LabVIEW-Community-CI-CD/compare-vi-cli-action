#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Get-PRVIDiffManifest.ps1' {
    BeforeAll {
        $scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Get-PRVIDiffManifest.ps1')
    }

    It 'emits a manifest for modified, renamed, added, and deleted VIs' {
        $repoRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $repoRoot | Out-Null

        Push-Location $repoRoot
        try {
            git init --quiet | Out-Null
            git config user.name 'Test Bot' | Out-Null
            git config user.email 'bot@example.com' | Out-Null

            # Base commit
            Set-Content -Path 'Keep.vi' -Value 'keep-v1'
            Set-Content -Path 'Remove.vi' -Value 'remove-v1'
            Set-Content -Path 'Original.vi' -Value 'original-v1'
            git add . | Out-Null
            git commit --quiet -m 'base commit' | Out-Null
            $baseCommit = (git rev-parse HEAD).Trim()

            # Head commit with assorted changes
            git mv Original.vi Renamed.vi | Out-Null
            Set-Content -Path 'Keep.vi' -Value 'keep-v2'
            git rm Remove.vi --quiet | Out-Null
            Set-Content -Path 'New.vi' -Value 'new-file'   # added VI
            New-Item -ItemType Directory -Path 'ignore' | Out-Null
            Set-Content -Path (Join-Path 'ignore' 'Skip.vi') -Value 'ignored'
            Set-Content -Path 'notes.txt' -Value 'non-vi'
            git add -A | Out-Null
            git commit --quiet -m 'head commit' | Out-Null
            $headCommit = (git rev-parse HEAD).Trim()
        }
        finally {
            Pop-Location
        }

        Push-Location $repoRoot
        try {
            $json = & $scriptPath -BaseRef $baseCommit -HeadRef $headCommit -IgnorePattern 'ignore/*'
        }
        finally {
            Pop-Location
        }

        $manifest = $json | ConvertFrom-Json
        $manifest.schema | Should -Be 'vi-diff-manifest@v1'
        $manifest.baseRef | Should -Be $baseCommit
        $manifest.headRef | Should -Be $headCommit
        $manifest.ignore | Should -Contain 'ignore/*'

        $manifest.pairs.Count | Should -Be 4

        $modified = $manifest.pairs | Where-Object { $_.changeType -eq 'modified' }
        $modified.basePath | Should -Be 'Keep.vi'
        $modified.headPath | Should -Be 'Keep.vi'

        $renamed = $manifest.pairs | Where-Object { $_.changeType -eq 'renamed' }
        $renamed.basePath | Should -Be 'Original.vi'
        $renamed.headPath | Should -Be 'Renamed.vi'
        [int]$renamed.renameScore | Should -BeGreaterThan 0

        $added = $manifest.pairs | Where-Object { $_.changeType -eq 'added' }
        $added.basePath | Should -BeNullOrEmpty
        $added.headPath | Should -Be 'New.vi'

        $deleted = $manifest.pairs | Where-Object { $_.changeType -eq 'deleted' }
        $deleted.basePath | Should -Be 'Remove.vi'
        $deleted.headPath | Should -BeNullOrEmpty

        ($manifest.pairs | Where-Object { $_.headPath -like 'ignore/*' -or $_.basePath -like 'ignore/*' }) |
            Should -BeNullOrEmpty
    }
}
