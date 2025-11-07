$ErrorActionPreference = 'Stop'

Describe 'Invoke-IconEditorSnapshotFromRepo.ps1' -Tag 'IconEditor','Snapshot','Integration' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name scriptPath -Value (Join-Path $repoRoot 'tools/icon-editor/Invoke-IconEditorSnapshotFromRepo.ps1')
        Test-Path -LiteralPath $script:scriptPath | Should -BeTrue "Snapshot invocation script not found."
        Set-Variable -Scope Script -Name fixturePath -Value $env:ICON_EDITOR_FIXTURE_PATH
        Set-Variable -Scope Script -Name manifestPath -Value $env:ICON_EDITOR_BASELINE_MANIFEST_PATH
    }

    BeforeEach {
        $script:testRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $script:testRoot | Out-Null

        Push-Location $script:testRoot
        git init --quiet | Out-Null
        git config user.email "snapshot@example.com" | Out-Null
        git config user.name "Snapshot User" | Out-Null

        $script:viPath = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
        $dir = Split-Path -Parent (Join-Path $script:testRoot $script:viPath)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot $script:viPath), [System.Text.Encoding]::UTF8.GetBytes('base'))
        git add . | Out-Null
        git commit -m 'base commit' --quiet | Out-Null
        $script:baseRef = (git rev-parse HEAD).Trim()

        [System.IO.File]::WriteAllBytes((Join-Path $script:testRoot $script:viPath), [System.Text.Encoding]::UTF8.GetBytes('head'))
        git commit -am 'head change' --quiet | Out-Null
        $script:headRef = (git rev-parse HEAD).Trim()

        Pop-Location
    }

    AfterEach {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'generates a snapshot workspace using changed files from the repo' {
        if (-not $script:fixturePath -or -not (Test-Path -LiteralPath $script:fixturePath -PathType Leaf)) {
            Set-ItResult -Skip -Because 'ICON_EDITOR_FIXTURE_PATH not supplied; skipping snapshot integration test.'
            return
        }

        $workspace = Join-Path $TestDrive 'snapshots'
        $stageName = 'test-snapshot'

        $invokeArgs = @(
            '-RepoPath', $script:testRoot,
            '-BaseRef', $script:baseRef,
            '-HeadRef', $script:headRef,
            '-WorkspaceRoot', $workspace,
            '-StageName', $stageName,
            '-FixturePath', $script:fixturePath,
            '-SkipValidate',
            '-SkipLVCompare'
        )
        if ($script:manifestPath -and (Test-Path -LiteralPath $script:manifestPath -PathType Leaf)) {
            $invokeArgs += @('-BaselineManifest', $script:manifestPath)
        }
        $result = & $script:scriptPath $invokeArgs

        $result | Should -Not -BeNullOrEmpty
        $result.stageExecuted | Should -BeTrue
        $result.files.Count | Should -Be 1

        $overlayPath = $result.overlay
        Test-Path -LiteralPath $overlayPath | Should -BeTrue
        (Get-ChildItem -LiteralPath $overlayPath -Recurse -File | Measure-Object).Count | Should -Be 1

        $stageRoot = $result.stageRoot
        Test-Path -LiteralPath $stageRoot | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $stageRoot 'head-manifest.json') | Should -BeTrue
    }
}
