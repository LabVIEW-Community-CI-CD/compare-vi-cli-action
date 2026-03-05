$ErrorActionPreference = 'Stop'

Describe 'Prepare-OverlayFromRepo.ps1' -Tag 'IconEditor','Overlay','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name scriptPath -Value (Join-Path $repoRoot 'tools/icon-editor/Prepare-OverlayFromRepo.ps1')
        Test-Path -LiteralPath $script:scriptPath | Should -BeTrue "Overlay preparation script not found."
    }

    BeforeEach {
        $script:testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:testRoot | Out-Null

        Push-Location $script:testRoot
        git init --quiet | Out-Null
        git config user.email "test@example.com" | Out-Null
        git config user.name "Test User" | Out-Null

        $script:resourcePath = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
        $script:additionalPath = 'resource/plugins/NIIconEditor/Support/ApplyLibIconOverlayToVIIcon.vi'

        $initialContent = [System.Text.Encoding]::UTF8.GetBytes('original')
        $additionalContent = [System.Text.Encoding]::UTF8.GetBytes('support')

        $directory = Split-Path -Parent (Join-Path $script:testRoot $script:resourcePath)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot $script:resourcePath), $initialContent)

        $additionalDirectory = Split-Path -Parent (Join-Path $script:testRoot $script:additionalPath)
        New-Item -ItemType Directory -Path $additionalDirectory -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot $script:additionalPath), $additionalContent)

        git add . | Out-Null
        git commit -m 'initial commit' --quiet | Out-Null
        $script:baseRef = (git rev-parse HEAD).Trim()

        $updatedContent = [System.Text.Encoding]::UTF8.GetBytes('changed')
        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot $script:resourcePath), $updatedContent)
        git commit -am 'update initialization vi' --quiet | Out-Null
        $script:headRef = (git rev-parse HEAD).Trim()

        Pop-Location
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies only changed files into the overlay' {
        $overlay = Join-Path $TestDrive 'overlay'
        $result = & $script:scriptPath `
            -RepoPath $script:testRoot `
            -BaseRef $script:baseRef `
            -HeadRef $script:headRef `
            -OverlayRoot $overlay `
            -Force

        $result | Should -Not -BeNullOrEmpty
        $result.files.Count | Should -Be 1
        $result.files[0] | Should -Be $script:resourcePath

        $destPath = Join-Path $overlay ($script:resourcePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        Test-Path -LiteralPath $destPath | Should -BeTrue
        $content = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($destPath))
        $content | Should -Be 'changed'
    }

    It 'skips unchanged files even when extensions match' {
        $overlay = Join-Path $TestDrive 'overlay-two'
        $result = & $script:scriptPath `
            -RepoPath $script:testRoot `
            -BaseRef $script:headRef `
            -HeadRef $script:headRef `
            -OverlayRoot $overlay `
            -Force

        $result.files.Count | Should -Be 0
        (Test-Path -LiteralPath $overlay) | Should -BeTrue
        (Get-ChildItem -LiteralPath $overlay -Recurse | Measure-Object).Count | Should -Be 0
    }
}
