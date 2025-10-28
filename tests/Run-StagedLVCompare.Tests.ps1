Describe 'Run-StagedLVCompare.ps1' -Tag 'Unit' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools' 'Run-StagedLVCompare.ps1'

    BeforeAll {
        $script:originalLocation = Get-Location
        Set-Location $repoRoot
    }

    AfterAll {
        Set-Location $script:originalLocation
    }

    AfterEach {
        Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_REPLACE_FLAGS -ErrorAction SilentlyContinue
    }

    It 'records match when LVCompare exits 0' {
        $resultsPath = Join-Path $TestDrive 'vi-staging-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path (Split-Path $resultsPath -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'staged\Base.vi'
        $stagedHead = Join-Path $TestDrive 'staged\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        $resultsEntries = @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI1.vi'
                headPath   = 'VI1.vi'
                staged     = [ordered]@{
                    Base         = $stagedBase
                    Head         = $stagedHead
                    AllowSameLeaf= $true
                }
            }
        )
        $resultsEntries | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport
            )
            $call = [pscustomobject]@{
                Base         = $BaseVi
                Head         = $HeadVi
                OutputDir    = $OutputDir
                AllowSameLeaf= $AllowSameLeaf.IsPresent
                RenderReport = $RenderReport.IsPresent
            }
            $using:invokeCalls.Add($call) | Out-Null
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
            $reportPath  = Join-Path $OutputDir 'compare-report.html'
            '{"capture":true}' | Set-Content -LiteralPath $capturePath -Encoding utf8
            '<html />' | Set-Content -LiteralPath $reportPath -Encoding utf8
            return [pscustomobject]@{
                ExitCode    = 0
                CapturePath = $capturePath
                ReportPath  = $reportPath
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $entry = $updated[0]
        $entry.compare.status | Should -Be 'match'
        $entry.compare.exitCode | Should -Be 0
        $entry.compare.capturePath | Should -Not -BeNullOrEmpty
        $entry.compare.reportPath | Should -Match 'compare-report\.html$'

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].AllowSameLeaf | Should -BeTrue
        $invokeCalls[0].RenderReport | Should -BeTrue

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        $compareSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $compareSummary[0].status | Should -Be 'match'

        $outputMap = @{}
        foreach ($line in Get-Content -LiteralPath $outputFile) {
            if ($line -match '=') {
                $k, $v = $line.Split('=', 2)
                $outputMap[$k] = $v
            }
        }
        $outputMap['match_count'] | Should -Be '1'
        $outputMap['diff_count'] | Should -Be '0'
        $outputMap['error_count'] | Should -Be '0'
        $outputMap['skip_count'] | Should -Be '0'
    }

    It 'marks diff when LVCompare exits 1' {
        $resultsPath = Join-Path $TestDrive 'results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'staged2\Base.vi'
        $stagedHead = Join-Path $TestDrive 'staged2\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI2.vi'
                headPath   = 'VI2.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir
            )
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 1
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs2.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $updated[0].compare.status | Should -Be 'diff'
        $updated[0].compare.exitCode | Should -Be 1

        $outputMap = @{}
        foreach ($line in Get-Content -LiteralPath $outputFile) {
            if ($line -match '=') {
                $k, $v = $line.Split('=', 2)
                $outputMap[$k] = $v
            }
        }
        $outputMap['diff_count'] | Should -Be '1'
        $outputMap['match_count'] | Should -Be '0'
    }

    It 'throws when LVCompare exits with error' {
        $resultsPath = Join-Path $TestDrive 'err-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'err\Base.vi'
        $stagedHead = Join-Path $TestDrive 'err\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'Err.vi'
                headPath   = 'Err.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir
            )
            return [pscustomobject]@{
                ExitCode = 2
            }
        }.GetNewClosure()

        { & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke } |
            Should -Throw -ErrorMessage '*LVCompare reported failures*'
    }

    It 'passes replace flags and custom flags to Invoke-LVCompare' {
        $resultsPath = Join-Path $TestDrive 'flags-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'flags\Base.vi'
        $stagedHead = Join-Path $TestDrive 'flags\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI3.vi'
                headPath   = 'VI3.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags
            )
            $invokeCalls.Add([pscustomobject]@{
                Flags        = $Flags
                ReplaceFlags = $ReplaceFlags.IsPresent
            }) | Out-Null
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -ReplaceFlags -Flags @('-nobd','-nobdcosm') -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -Be @('-nobd','-nobdcosm')
    }

    It 'honors environment flag configuration when parameters omitted' {
        $resultsPath = Join-Path $TestDrive 'env-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'env\Base.vi'
        $stagedHead = Join-Path $TestDrive 'env\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI4.vi'
                headPath   = 'VI4.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $env:RUN_STAGED_LVCOMPARE_FLAGS_MODE = 'replace'
        $env:RUN_STAGED_LVCOMPARE_FLAGS = @('-nobd','-nobdcosm') -join "`n"

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags
            )
            $invokeCalls.Add([pscustomobject]@{
                Flags        = $Flags
                ReplaceFlags = $ReplaceFlags.IsPresent
            }) | Out-Null
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -Be @('-nobd','-nobdcosm')
    }

    It 'honors replace mode without explicit flags' {
        $resultsPath = Join-Path $TestDrive 'env-replace.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'env2\Base.vi'
        $stagedHead = Join-Path $TestDrive 'env2\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI5.vi'
                headPath   = 'VI5.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $env:RUN_STAGED_LVCOMPARE_FLAGS_MODE = 'replace'
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS -ErrorAction SilentlyContinue

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags
            )
            $invokeCalls.Add([pscustomobject]@{
                Flags        = $Flags
                ReplaceFlags = $ReplaceFlags.IsPresent
            }) | Out-Null
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -BeNullOrEmpty
    }
}
