$ErrorActionPreference = 'Stop'

Describe 'Prepare-VipViDiffRequests.ps1' {
    BeforeAll {
        $repoRoot = (git rev-parse --show-toplevel).Trim()
        $scriptPath = Join-Path $repoRoot 'tools/icon-editor/Prepare-VipViDiffRequests.ps1'
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name prepareScript -Value (Get-Item -LiteralPath $scriptPath)
    }

    It 'maps extracted VIP paths to head, normalizes relPath, and handles missing base' {
        $extractRoot = Join-Path $TestDrive 'extract'
        $iconRoot    = Join-Path $extractRoot 'National Instruments/LabVIEW Icon Editor'
        New-Item -ItemType Directory -Path (Join-Path $iconRoot 'ModuleA') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $iconRoot 'ModuleB/Sub') -Force | Out-Null

        # Create dummy VI files in extracted tree
        $viA = Join-Path $iconRoot 'ModuleA/SampleA.vi'
        $viB = Join-Path $iconRoot 'ModuleB/Sub/SampleB.vi'
        'dummy' | Set-Content -LiteralPath $viA -Encoding ascii
        'dummy' | Set-Content -LiteralPath $viB -Encoding ascii

        # Create a custom source root: only one base exists to test base=null
        $sourceRoot = Join-Path $TestDrive 'icon-src'
        New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'ModuleA') -Force | Out-Null
        Copy-Item -LiteralPath $viA -Destination (Join-Path $sourceRoot 'ModuleA/SampleA.vi') -Force

        $outputDir   = Join-Path $TestDrive 'vip-vi-diff'
        $requestsOut = Join-Path $outputDir 'vi-diff-requests.json'

        $sourceParent = Split-Path -Parent $sourceRoot
        $sourceLeaf = Split-Path -Leaf $sourceRoot

        $result = & $script:prepareScript `
            -ExtractRoot $extractRoot `
            -RepoRoot $sourceParent `
            -SourceRoot $sourceLeaf `
            -OutputDir $outputDir `
            -RequestsPath $requestsOut `
            -Category 'vip'

        Test-Path -LiteralPath $requestsOut | Should -BeTrue
        $json = Get-Content -LiteralPath $requestsOut -Raw | ConvertFrom-Json
        $json.count | Should -Be 2
        $json.requests.Count | Should -Be 2

        # relPath normalization uses forward slashes
        @($json.requests | % relPath) | ForEach-Object { $_ | Should -Match '^[^\\]+/.+\.vi$' }

        # Head copies exist for both
        $headRoot = Join-Path $outputDir 'head'
        Test-Path -LiteralPath (Join-Path $headRoot 'ModuleA/SampleA.vi') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $headRoot 'ModuleB/Sub/SampleB.vi') | Should -BeTrue

        # Base exists for SampleA but not for SampleB
        $reqA = @($json.requests | Where-Object { $_.name -eq 'SampleA.vi' })[0]
        $reqB = @($json.requests | Where-Object { $_.name -eq 'SampleB.vi' })[0]
        [string]::IsNullOrEmpty($reqA.base) | Should -BeFalse
        [string]::IsNullOrEmpty($reqB.base) | Should -BeTrue
    }
}

