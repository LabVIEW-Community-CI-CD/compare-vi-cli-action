#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'Invoke-PRVIStaging.ps1' {
    BeforeAll {
        $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Invoke-PRVIStaging.ps1')).ProviderPath
        $manifestScript = (Resolve-Path (Join-Path $PSScriptRoot '..' 'tools' 'Get-PRVIDiffManifest.ps1')).ProviderPath
    }

    It 'invokes Stage-CompareInputs for manifest pairs with base and head paths' {
        $repoRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path $repoRoot | Out-Null

        Push-Location $repoRoot
        try {
            git init --quiet | Out-Null
            git config user.name 'Test Bot' | Out-Null
            git config user.email 'bot@example.com' | Out-Null

            Set-Content -Path 'Keep.vi' -Value 'keep-v1'
            Set-Content -Path 'Original.vi' -Value 'original'
            git add . | Out-Null
            git commit --quiet -m 'base' | Out-Null

            git mv Original.vi Renamed.vi | Out-Null
            Set-Content -Path 'Keep.vi' -Value 'keep-v2'
            git add -A | Out-Null
            git commit --quiet -m 'head' | Out-Null

            $base = (git rev-parse HEAD~1).Trim()
            $head = (git rev-parse HEAD).Trim()
            $manifestJson = & $manifestScript -BaseRef $base -HeadRef $head
            $manifestPath = Join-Path $repoRoot 'vi-manifest.json'
            Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8
        }
        finally {
            Pop-Location
        }

        $invocations = New-Object System.Collections.Generic.List[object]
        $stageInvoker = {
            param($BaseVi, $HeadVi, $WorkingRoot, $StageScript)
            $invocations.Add([pscustomobject]@{
                BaseVi      = $BaseVi
                HeadVi      = $HeadVi
                WorkingRoot = $WorkingRoot
            })
            return [pscustomobject]@{
                Base = "$BaseVi.staged"
                Head = "$HeadVi.staged"
                Root = 'root'
            }
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            $workingRoot = Join-Path -Path $TestDrive -ChildPath 'stage-root'
            try {
                $results = & $scriptPath -ManifestPath $manifestPath -WorkingRoot $workingRoot -StageInvoker $stageInvoker
            } catch {
                throw
            }
        }
        finally {
            Pop-Location
        }

        $invocations.Count | Should -Be 1
        $results.Count | Should -Be 1

        $modifiedCall = $invocations | Where-Object { $_.BaseVi -like '*Keep.vi' }
        $modifiedCall.HeadVi | Should -BeLike '*Keep.vi'
        $modifiedCall.WorkingRoot | Should -BeLike '*stage-root'

        $results[0].staged.Base | Should -Match '\.staged$'
    }

    It 'supports dry-run mode without invoking the stage invoker' {
        $repoRoot = Join-Path $TestDrive 'repo-dryrun'
        New-Item -ItemType Directory -Path $repoRoot | Out-Null

        Push-Location $repoRoot
        try {
            git init --quiet | Out-Null
            git config user.name 'Test Bot' | Out-Null
            git config user.email 'bot@example.com' | Out-Null

            Set-Content -Path 'Base.vi' -Value 'base'
            Set-Content -Path 'Head.vi' -Value 'head'
            git add . | Out-Null
            git commit --quiet -m 'base' | Out-Null

            Set-Content -Path 'Head.vi' -Value 'head2'
            git add . | Out-Null
            git commit --quiet -m 'head' | Out-Null

            $base = (git rev-parse HEAD~1).Trim()
            $head = (git rev-parse HEAD).Trim()
            $manifestJson = & $manifestScript -BaseRef $base -HeadRef $head
            $manifestPath = Join-Path $repoRoot 'vi-manifest.json'
            Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8
        }
        finally {
            Pop-Location
        }

        $invocations = New-Object System.Collections.Generic.List[object]
        $stageInvoker = {
            param($BaseVi, $HeadVi, $WorkingRoot, $StageScript)
            $invocations.Add([pscustomobject]@{ BaseVi = $BaseVi })
            return $null
        }.GetNewClosure()

        Push-Location $repoRoot
        try {
            & $scriptPath -ManifestPath $manifestPath -DryRun -StageInvoker $stageInvoker | Out-Null
        }
        finally {
            Pop-Location
        }

        $invocations.Count | Should -Be 0
    }
}
