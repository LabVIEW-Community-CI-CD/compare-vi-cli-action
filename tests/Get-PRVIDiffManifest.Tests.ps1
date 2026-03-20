#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Get-PRVIDiffManifest.ps1' {
    BeforeAll {
        $scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Get-PRVIDiffManifest.ps1')

        function Set-LabVIEWBinaryFixture {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][ValidateSet('LVIN', 'LVCC')][string]$Signature,
                [string]$Payload = ''
            )

            $directory = Split-Path -Parent $Path
            $resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) {
                [System.IO.Path]::GetFullPath($Path)
            } else {
                [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
            }
            $directory = Split-Path -Parent $resolvedPath
            if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }

            $payloadBytes = if ([string]::IsNullOrWhiteSpace($Payload)) {
                [byte[]]@()
            } else {
                [System.Text.Encoding]::UTF8.GetBytes($Payload)
            }

            $minimumLength = 12 + $payloadBytes.Length
            $bytes = New-Object byte[] ([Math]::Max(16, $minimumLength))
            [System.Text.Encoding]::ASCII.GetBytes($Signature).CopyTo($bytes, 8)
            if ($payloadBytes.Length -gt 0) {
                [Array]::Copy($payloadBytes, 0, $bytes, 12, $payloadBytes.Length)
            }
            [System.IO.File]::WriteAllBytes($resolvedPath, $bytes)
        }
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
            Set-LabVIEWBinaryFixture -Path 'Keep.vi' -Signature 'LVIN' -Payload 'keep-v1'
            Set-LabVIEWBinaryFixture -Path 'Remove.vi' -Signature 'LVCC' -Payload 'remove-v1'
            Set-LabVIEWBinaryFixture -Path 'Original.weird' -Signature 'LVIN' -Payload 'original-v1'
            git add . | Out-Null
            git commit --quiet -m 'base commit' | Out-Null
            $baseCommit = (git rev-parse HEAD).Trim()

            # Head commit with assorted changes
            git mv Original.weird Renamed.custom | Out-Null
            Set-LabVIEWBinaryFixture -Path 'Keep.vi' -Signature 'LVIN' -Payload 'keep-v2'
            git rm Remove.vi --quiet | Out-Null
            Set-LabVIEWBinaryFixture -Path 'NewArtifact' -Signature 'LVCC' -Payload 'new-file'
            Set-Content -Path 'PlainText.vi' -Value 'not-a-labview-binary'
            New-Item -ItemType Directory -Path 'ignore' | Out-Null
            Set-LabVIEWBinaryFixture -Path (Join-Path 'ignore' 'Skip.bin') -Signature 'LVIN' -Payload 'ignored'
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
        $renamed.basePath | Should -Be 'Original.weird'
        $renamed.headPath | Should -Be 'Renamed.custom'
        [int]$renamed.renameScore | Should -BeGreaterThan 0

        $added = $manifest.pairs | Where-Object { $_.changeType -eq 'added' }
        $added.basePath | Should -BeNullOrEmpty
        $added.headPath | Should -Be 'NewArtifact'

        $deleted = $manifest.pairs | Where-Object { $_.changeType -eq 'deleted' }
        $deleted.basePath | Should -Be 'Remove.vi'
        $deleted.headPath | Should -BeNullOrEmpty

        ($manifest.pairs | Where-Object { $_.headPath -like 'ignore/*' -or $_.basePath -like 'ignore/*' }) |
            Should -BeNullOrEmpty
        ($manifest.pairs | Where-Object { $_.headPath -eq 'PlainText.vi' -or $_.basePath -eq 'PlainText.vi' }) |
            Should -BeNullOrEmpty
    }
}
