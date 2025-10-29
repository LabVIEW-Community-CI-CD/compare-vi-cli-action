Describe 'Run-StagedLVCompare.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Run-StagedLVCompare.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    AfterEach {
        Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS_MODE -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_REPLACE_FLAGS -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_LEAK_CHECK -ErrorAction SilentlyContinue
        Remove-Item Env:RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS -ErrorAction SilentlyContinue
        Remove-Item Env:VI_STAGE_COMPARE_FLAGS -ErrorAction SilentlyContinue
        Remove-Item Env:VI_STAGE_COMPARE_FLAGS_MODE -ErrorAction SilentlyContinue
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
                    AllowSameLeaf= $false
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
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $call = [pscustomobject]@{
                Base         = $BaseVi
                Head         = $HeadVi
                OutputDir    = $OutputDir
                AllowSameLeaf= $AllowSameLeaf.IsPresent
                RenderReport = $RenderReport.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            }
            $null = $invokeCalls.Add($call)
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

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $entry = $updated[0]
        $entry.compare.status | Should -Be 'match'
        $entry.compare.exitCode | Should -Be 0
        $entry.compare.capturePath | Should -Not -BeNullOrEmpty
        $entry.compare.reportPath | Should -Match 'compare-report\.html$'

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].AllowSameLeaf | Should -BeFalse
        $invokeCalls[0].RenderReport | Should -BeTrue

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        $compareSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $compareSummary[0].status | Should -Be 'match'
        $compareSummary[0].stagedBase | Should -Be $stagedBase
        $compareSummary[0].stagedHead | Should -Be $stagedHead

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

    It 'fails when staged filenames are identical' {
        $resultsPath = Join-Path $TestDrive 'vi-sameleaf-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $sharedPath = Join-Path $TestDrive 'mirror\same\Sample.vi'
        New-Item -ItemType Directory -Path (Split-Path $sharedPath -Parent) -Force | Out-Null
        Set-Content -LiteralPath $sharedPath -Value 'both'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'fixtures/vi-attr/Base.vi'
                headPath   = 'fixtures/vi-attr/Base.vi'
                staged     = [ordered]@{
                    Base = $sharedPath
                    Head = $sharedPath
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $invoke = {
            throw 'LVCompare should not be called when staged paths match.'
        }.GetNewClosure()

        { & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke } |
            Should -Throw -ExpectedMessage '*identical Base/Head*'
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
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 1
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs2.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

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
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            return [pscustomobject]@{
                ExitCode = 2
            }
        }.GetNewClosure()

        $caughtError = $null
        try {
            & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke
        } catch {
            $caughtError = $_
        }
        $caughtError | Should -Not -BeNullOrEmpty
        $caughtError.Exception.Message | Should -Match 'LVCompare reported failures'
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
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -ReplaceFlags -Flags @('-nobd','-nobdcosm') -InvokeLVCompare $invoke

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

        $env:VI_STAGE_COMPARE_FLAGS_MODE = 'replace'
        $env:VI_STAGE_COMPARE_FLAGS = @('-nobd','-nobdcosm') -join "`n"

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

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

        $env:VI_STAGE_COMPARE_FLAGS_MODE = 'replace'
        Remove-Item Env:RUN_STAGED_LVCOMPARE_FLAGS -ErrorAction SilentlyContinue
        Remove-Item Env:VI_STAGE_COMPARE_FLAGS -ErrorAction SilentlyContinue

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = $Flags
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -BeNullOrEmpty
    }

    It 'honors append mode via VI_STAGE env' {
        $resultsPath = Join-Path $TestDrive 'env-append.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'env3\Base.vi'
        $stagedHead = Join-Path $TestDrive 'env3\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI6.vi'
                headPath   = 'VI6.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $env:VI_STAGE_COMPARE_FLAGS_MODE = 'append'
        $env:VI_STAGE_COMPARE_FLAGS = '-nobd'

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].ReplaceFlags | Should -BeFalse
        @($invokeCalls[0].Flags) | Should -Contain '-nobd'
    }

    It 'records leak warnings when leak summary present' {
        $resultsPath = Join-Path $TestDrive 'leak-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'leak\Base.vi'
        $stagedHead = Join-Path $TestDrive 'leak\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI7.vi'
                headPath   = 'VI7.vi'
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
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            })

            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
            '{"capture":true}' | Set-Content -LiteralPath $capturePath -Encoding utf8
            $reportPath = Join-Path $OutputDir 'compare-report.html'
            '<html />' | Set-Content -LiteralPath $reportPath -Encoding utf8

            $leakPath = Join-Path $OutputDir 'compare-leak.json'
            $leakPayload = [ordered]@{
                schema    = 'prime-lvcompare-leak/v1'
                at        = (Get-Date).ToString('o')
                lvcompare = @{
                    remaining = @(1234, 5678)
                    count     = 2
                }
                labview   = @{
                    remaining = @(4444)
                    count     = 1
                }
            }
            $leakPayload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $leakPath -Encoding utf8

            return [pscustomobject]@{
                ExitCode    = 1
                CapturePath = $capturePath
                ReportPath  = $reportPath
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs-leak.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].LeakCheck | Should -BeTrue

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $entry = $updated[0].compare
        $entry.status | Should -Be 'diff'
        $entry.leakWarning | Should -BeTrue
        $entry.leak.lvcompare | Should -Be 2
        $entry.leak.labview | Should -Be 1
        $entry.leak.path | Should -Match 'compare-leak\.json$'

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        Test-Path -LiteralPath $summaryPath | Should -BeTrue
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $summary[0].leakWarning | Should -BeTrue
        $summary[0].leakLvcompare | Should -Be 2
        $summary[0].leakLabVIEW | Should -Be 1

        $outputMap = @{}
        foreach ($line in Get-Content -LiteralPath $outputFile) {
            if ($line -match '=') {
                $key, $value = $line.Split('=', 2)
                $outputMap[$key] = $value
            }
        }
        $outputMap['leak_warning_count'] | Should -Be '1'
    }

    It 'honors timeout and leak env overrides' {
        $resultsPath = Join-Path $TestDrive 'timeout-results.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'timeout\Base.vi'
        $stagedHead = Join-Path $TestDrive 'timeout\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI8.vi'
                headPath   = 'VI8.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $env:RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS = '45'
        $env:RUN_STAGED_LVCOMPARE_LEAK_CHECK = 'false'
        $env:RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS = '2.5'

        $invokeCalls = New-Object System.Collections.Generic.List[object]
        $invoke = {
            param(
                [string]$BaseVi,
                [string]$HeadVi,
                [string]$OutputDir,
                [switch]$AllowSameLeaf,
                [switch]$RenderReport,
                [string[]]$Flags,
                [switch]$ReplaceFlags,
                [switch]$LeakCheck,
                [Nullable[int]]$TimeoutSeconds,
                [Nullable[double]]$LeakGraceSeconds
            )
            $call = [pscustomobject]@{
                LeakCheck        = $LeakCheck.IsPresent
                TimeoutProvided  = $PSBoundParameters.ContainsKey('TimeoutSeconds')
                TimeoutSeconds   = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceProvided= $PSBoundParameters.ContainsKey('LeakGraceSeconds')
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
            }
            $null = $invokeCalls.Add($call)
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs-timeout.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].LeakCheck | Should -BeFalse
        $invokeCalls[0].TimeoutProvided | Should -BeTrue
        $invokeCalls[0].TimeoutSeconds | Should -Be 45
        $invokeCalls[0].LeakGraceProvided | Should -BeFalse
        $invokeCalls[0].LeakGraceSeconds | Should -Be $null

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $compareObject = $updated[0].compare
        ($compareObject.PSObject.Properties.Name) | Should -Not -Contain 'leakWarning'

        $outputMap = @{}
        foreach ($line in Get-Content -LiteralPath $outputFile) {
            if ($line -match '=') {
                $key, $value = $line.Split('=', 2)
                $outputMap[$key] = $value
            }
        }
        $outputMap['leak_warning_count'] | Should -Be '0'
    }
}



