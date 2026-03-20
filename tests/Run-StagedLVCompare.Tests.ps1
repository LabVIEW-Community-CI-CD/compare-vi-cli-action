. (Join-Path $PSScriptRoot 'ReportFixtureHelpers.ps1')
$reportFixtureCases = Get-ReportFixtureCases

Describe 'Run-StagedLVCompare.ps1' -Tag 'Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:scriptPath = Join-Path $script:repoRoot 'tools' 'Run-StagedLVCompare.ps1'
        $script:originalLocation = Get-Location
        Set-Location $script:repoRoot
        $script:originalGithubOutput = $env:GITHUB_OUTPUT
    }

    BeforeEach {
        $script:envSnapshot = @{
            GITHUB_OUTPUT                         = $env:GITHUB_OUTPUT
            RUN_STAGED_LVCOMPARE_FLAGS            = $env:RUN_STAGED_LVCOMPARE_FLAGS
            RUN_STAGED_LVCOMPARE_FLAGS_MODE       = $env:RUN_STAGED_LVCOMPARE_FLAGS_MODE
            RUN_STAGED_LVCOMPARE_REPLACE_FLAGS    = $env:RUN_STAGED_LVCOMPARE_REPLACE_FLAGS
            RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS  = $env:RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS
            RUN_STAGED_LVCOMPARE_LEAK_CHECK       = $env:RUN_STAGED_LVCOMPARE_LEAK_CHECK
            RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS = $env:RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS
            VI_STAGE_COMPARE_FLAGS                = $env:VI_STAGE_COMPARE_FLAGS
            VI_STAGE_COMPARE_FLAGS_MODE           = $env:VI_STAGE_COMPARE_FLAGS_MODE
        }
    }

    AfterAll {
        if ($script:originalLocation) {
            Set-Location $script:originalLocation
        }
    }

    AfterEach {
        $keys = @(
            'RUN_STAGED_LVCOMPARE_FLAGS',
            'RUN_STAGED_LVCOMPARE_FLAGS_MODE',
            'RUN_STAGED_LVCOMPARE_REPLACE_FLAGS',
            'RUN_STAGED_LVCOMPARE_TIMEOUT_SECONDS',
            'RUN_STAGED_LVCOMPARE_LEAK_CHECK',
            'RUN_STAGED_LVCOMPARE_LEAK_GRACE_SECONDS',
            'VI_STAGE_COMPARE_FLAGS',
            'VI_STAGE_COMPARE_FLAGS_MODE'
        )
        foreach ($key in $keys) {
            $value = $script:envSnapshot[$key]
            if ($null -ne $value -and $value -ne '') {
                Set-Item -Path ("Env:{0}" -f $key) -Value $value
            } else {
                Remove-Item -Path ("Env:{0}" -f $key) -ErrorAction SilentlyContinue
            }
        }
        if ($script:originalGithubOutput) {
            Set-Item -Path Env:GITHUB_OUTPUT -Value $script:originalGithubOutput
        } else {
            Remove-Item -Path Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name envSnapshot -Scope Script -ErrorAction SilentlyContinue
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
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
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
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
        $entry.compare.primaryMode | Should -Be 'full'
        $entry.compare.modes | Should -Not -BeNullOrEmpty
        $entry.compare.modes.Count | Should -Be 1
        $entry.compare.modes[0].name | Should -Be 'full'
        @($entry.compare.modes[0].flags).Count | Should -Be 0

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].AllowSameLeaf | Should -BeFalse
        $invokeCalls[0].RenderReport | Should -BeTrue
        $invokeCalls[0].NoiseProfile | Should -Be 'full'

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        $compareSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $compareSummary[0].status | Should -Be 'match'
        $compareSummary[0].stagedBase | Should -Be $stagedBase
        $compareSummary[0].stagedHead | Should -Be $stagedHead
        $compareSummary[0].primaryMode | Should -Be 'full'
        $compareSummary[0].modes.Count | Should -Be 1

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

    It 'resolves custom report artifact paths from capture metadata when the invoke result omits ReportPath' {
        $resultsPath = Join-Path $TestDrive 'vi-staging-results-custom-report.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts-custom-report'
        New-Item -ItemType Directory -Path (Split-Path $resultsPath -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'staged-custom\Base.vi'
        $stagedHead = Join-Path $TestDrive 'staged-custom\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
                headPath   = 'resource/plugins/NIIconEditor/Miscellaneous/User Events/Initialization_UserEvents.vi'
                staged     = [ordered]@{
                    Base         = $stagedBase
                    Head         = $stagedHead
                    AllowSameLeaf= $false
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
            $reportPath  = Join-Path $OutputDir 'diff-report-Initialization_UserEvents.vi.html'
            @'
{
  "schema": "lvcompare-capture-v1",
  "out": {
    "reportHtml": "./diff-report-Initialization_UserEvents.vi.html"
  },
  "cli": {
    "reportPath": "./diff-report-Initialization_UserEvents.vi.html"
  }
}
'@ | Set-Content -LiteralPath $capturePath -Encoding utf8
            '<html><body>custom report</body></html>' | Set-Content -LiteralPath $reportPath -Encoding utf8
            return [pscustomobject]@{
                ExitCode    = 0
                CapturePath = $capturePath
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $entry = $updated[0]
        $entry.compare.reportPath | Should -Match 'diff-report-Initialization_UserEvents\.vi\.html$'

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        $compareSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $compareSummary[0].reportPath | Should -Match 'diff-report-Initialization_UserEvents\.vi\.html$'
    }

    It 'treats exit 0 with diff headings as diff' {
        $resultsPath = Join-Path $TestDrive 'vi-staging-results-diff.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts-diff'
        New-Item -ItemType Directory -Path (Split-Path $resultsPath -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedBase = Join-Path $TestDrive 'staged-diff\Base.vi'
        $stagedHead = Join-Path $TestDrive 'staged-diff\Head.vi'
        New-Item -ItemType Directory -Path (Split-Path $stagedBase -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base'
        Set-Content -LiteralPath $stagedHead -Value 'head'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'VI2.vi'
                headPath   = 'VI2.vi'
                staged     = [ordered]@{
                    Base         = $stagedBase
                    Head         = $stagedHead
                    AllowSameLeaf= $false
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
            $reportPath  = Join-Path $OutputDir 'compare-report.html'
            '{"capture":true}' | Set-Content -LiteralPath $capturePath -Encoding utf8
            @'
<!doctype html>
<html>
  <body>
    <details class="difference">
      <summary class="difference-heading">Block Diagram objects</summary>
      <ul>
        <li class="diff-detail">Probe - added</li>
      </ul>
    </details>
  </body>
</html>
'@ | Set-Content -LiteralPath $reportPath -Encoding utf8
            return [pscustomobject]@{
                ExitCode    = 0
                CapturePath = $capturePath
                ReportPath  = $reportPath
            }
        }.GetNewClosure()

        $outputFile = Join-Path $TestDrive 'outputs-diff.txt'
        $env:GITHUB_OUTPUT = $outputFile

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $compareSummary = Get-Content -LiteralPath (Join-Path $artifactsDir 'vi-staging-compare.json') -Raw | ConvertFrom-Json
        $compareSummary[0].status | Should -Be 'diff'
        $compareSummary[0].PSObject.Properties['diffDetected'] | Should -Not -Be $null
        $compareSummary[0].diffDetected | Should -BeTrue

        $outputMap = @{ }
        foreach ($line in Get-Content -LiteralPath $outputFile) {
            if ($line -match '=') {
                $k, $v = $line.Split('=', 2)
                $outputMap[$k] = $v
            }
        }
        $outputMap['diff_count'] | Should -Be '1'
        $outputMap['match_count'] | Should -Be '0'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
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
        $entry = $updated[0].compare
        $entry.status | Should -Be 'diff'
        $entry.exitCode | Should -Be 1
        $entry.primaryMode | Should -Be 'full'
        $entry.modes | Should -Not -BeNullOrEmpty
        $entry.modes.Count | Should -Be 1

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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -ReplaceFlags -Flags @('-nobd','-nobdcosm') -NoiseProfile legacy -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 2
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -Be @('-nobd','-nobdcosm')
        $invokeCalls[1].ReplaceFlags | Should -BeTrue
        (@($invokeCalls[1].Flags | Where-Object { $_ })).Count | Should -Be 0
        $invokeCalls[0].NoiseProfile | Should -Be 'legacy'
        $invokeCalls[1].NoiseProfile | Should -Be 'legacy'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 2
        $invokeCalls[0].ReplaceFlags | Should -BeTrue
        $invokeCalls[0].Flags | Should -Be @('-nobd','-nobdcosm')
        $invokeCalls[1].ReplaceFlags | Should -BeTrue
        (@($invokeCalls[1].Flags | Where-Object { $_ })).Count | Should -Be 0
        $invokeCalls[0].NoiseProfile | Should -Be 'full'
        $invokeCalls[1].NoiseProfile | Should -Be 'full'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = $Flags
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 1
        $invokeCalls[0].NoiseProfile | Should -Be 'full'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                Flags        = @($Flags)
                ReplaceFlags = $ReplaceFlags.IsPresent
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
            })
            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            return [pscustomobject]@{
                ExitCode = 0
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 2
        $invokeCalls[0].ReplaceFlags | Should -BeFalse
        @($invokeCalls[0].Flags) | Should -Contain '-nobd'
        $invokeCalls[1].ReplaceFlags | Should -BeTrue
        (@($invokeCalls[1].Flags | Where-Object { $_ })).Count | Should -Be 0
        $invokeCalls[0].NoiseProfile | Should -Be 'full'
        $invokeCalls[1].NoiseProfile | Should -Be 'full'
    }

    It 'detects diffs via full profile when filtered flags suppress changes' {
        $resultsPath = Join-Path $TestDrive 'dual-mode.json'
        $artifactsDir = Join-Path $TestDrive 'artifacts'
        New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

        $stagedRoot = Join-Path $TestDrive 'dual-mode-staged'
        $stagedBase = Join-Path $stagedRoot 'Base.vi'
        $stagedHead = Join-Path $stagedRoot 'Head.vi'
        New-Item -ItemType Directory -Path $stagedRoot -Force | Out-Null
        Set-Content -LiteralPath $stagedBase -Value 'base contents'
        Set-Content -LiteralPath $stagedHead -Value 'head contents'

        @(
            [ordered]@{
                changeType = 'modify'
                basePath   = 'fixtures/vi-stage/bd-cosmetic/Base.vi'
                headPath   = 'fixtures/vi-stage/bd-cosmetic/Head.vi'
                staged     = [ordered]@{
                    Base = $stagedBase
                    Head = $stagedHead
                }
            }
        ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

        $env:VI_STAGE_COMPARE_FLAGS_MODE = 'replace'
        $env:VI_STAGE_COMPARE_FLAGS = '-nobdcosm'

        $diffHtml = @'
<!DOCTYPE html>
<html>
  <body>
    <details open>
      <summary class="difference-heading">1. Block Diagram Cosmetic - Wiring</summary>
      <ol class="detailed-description-list">
        <li class="diff-detail">Wire adjusted</li>
      </ol>
    </details>
  </body>
</html>
'@

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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $flagList = @($Flags | Where-Object { $_ })
            $invokeCalls.Add([pscustomobject]@{
                Flags        = $flagList
                ReplaceFlags = $ReplaceFlags.IsPresent
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
            }) | Out-Null

            New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
            $capturePath = Join-Path $OutputDir 'lvcompare-capture.json'
            '{"capture":true}' | Set-Content -LiteralPath $capturePath -Encoding utf8
            $reportPath = Join-Path $OutputDir 'compare-report.html'

            if ($flagList -and $flagList -contains '-nobdcosm') {
                '<html />' | Set-Content -LiteralPath $reportPath -Encoding utf8
                return [pscustomobject]@{
                    ExitCode    = 0
                    CapturePath = $capturePath
                    ReportPath  = $reportPath
                }
            } else {
                $diffHtml | Set-Content -LiteralPath $reportPath -Encoding utf8
                return [pscustomobject]@{
                    ExitCode    = 1
                    CapturePath = $capturePath
                    ReportPath  = $reportPath
                }
            }
        }.GetNewClosure()

        & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

        $invokeCalls.Count | Should -Be 2
        @($invokeCalls[0].Flags) | Should -Contain '-nobdcosm'
        @($invokeCalls[1].Flags).Count | Should -Be 0
        $invokeCalls[0].NoiseProfile | Should -Be 'full'
        $invokeCalls[1].NoiseProfile | Should -Be 'full'

        $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
        $compareInfo = $updated[0].compare
        $compareInfo.status | Should -Be 'diff'
        $compareInfo.primaryMode | Should -Be 'full'
        $compareInfo.modes.Count | Should -Be 2
        ($compareInfo.modes | Where-Object { $_.name -eq 'filtered' }).status | Should -Be 'match'
        ($compareInfo.modes | Where-Object { $_.name -eq 'full' }).status | Should -Be 'diff'

        $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $summary[0].status | Should -Be 'diff'
        $summary[0].primaryMode | Should -Be 'full'
        $summary[0].modes.Count | Should -Be 2

        $summarizeScript = Join-Path $script:repoRoot 'tools' 'Summarize-VIStaging.ps1'
        $summaryResult = & $summarizeScript -CompareJson $summaryPath
        $summaryResult.pairs[0].flagSummary | Should -Match 'filtered'
        $summaryResult.pairs[0].flagSummary | Should -Match 'full'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $null = $invokeCalls.Add([pscustomobject]@{
                LeakCheck    = $LeakCheck.IsPresent
                TimeoutSeconds = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
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
        $invokeCalls[0].NoiseProfile | Should -Be 'full'
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
                [Nullable[double]]$LeakGraceSeconds,
                [string]$NoiseProfile
            )
            $call = [pscustomobject]@{
                LeakCheck        = $LeakCheck.IsPresent
                TimeoutProvided  = $PSBoundParameters.ContainsKey('TimeoutSeconds')
                TimeoutSeconds   = if ($PSBoundParameters.ContainsKey('TimeoutSeconds') -and $TimeoutSeconds -ne $null) { [int]$TimeoutSeconds } else { $null }
                LeakGraceProvided= $PSBoundParameters.ContainsKey('LeakGraceSeconds')
                LeakGraceSeconds = if ($PSBoundParameters.ContainsKey('LeakGraceSeconds') -and $LeakGraceSeconds -ne $null) { [double]$LeakGraceSeconds } else { $null }
                NoiseProfile     = if ($PSBoundParameters.ContainsKey('NoiseProfile')) { $NoiseProfile } else { $null }
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
        $invokeCalls[0].NoiseProfile | Should -Be 'full'

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

    Context 'report fixtures' {
    It 'preserves report artifact content for <Name>' -TestCases $reportFixtureCases {
        param($Name, $FixtureRoot, $Headings, $Expected)

            $FixtureRoot | Should -Not -BeNullOrEmpty
            $Headings | Should -Not -BeNullOrEmpty

            $resultsPath = Join-Path $TestDrive ("report-{0}.json" -f $Name)
            $artifactsDir = Join-Path $TestDrive ("report-artifacts-{0}" -f $Name)
            New-Item -ItemType Directory -Path $artifactsDir -Force | Out-Null

            $stagedRoot = Join-Path $TestDrive ("staged-{0}" -f $Name)
            $stagedBase = Join-Path $stagedRoot 'Base.vi'
            $stagedHead = Join-Path $stagedRoot 'Head.vi'
            New-Item -ItemType Directory -Path $stagedRoot -Force | Out-Null
            Set-Content -LiteralPath $stagedBase -Value 'base VI contents'
            Set-Content -LiteralPath $stagedHead -Value 'head VI contents'

            @(
                [ordered]@{
                    changeType = 'modify'
                    basePath   = "fixtures/vi-report/$Name/Base.vi"
                    headPath   = "fixtures/vi-report/$Name/Head.vi"
                    staged     = [ordered]@{
                        Base = $stagedBase
                        Head = $stagedHead
                    }
                }
            ) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultsPath -Encoding utf8

            $fixtureReport = Join-Path $FixtureRoot 'compare-report.html'
            $fixtureCapture = Join-Path $FixtureRoot 'lvcompare-capture.json'

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
            Copy-Item -LiteralPath $fixtureReport -Destination (Join-Path $OutputDir 'compare-report.html') -Force
            Copy-Item -LiteralPath $fixtureCapture -Destination (Join-Path $OutputDir 'lvcompare-capture.json') -Force
            return [pscustomobject]@{
                ExitCode    = 1
                CapturePath = Join-Path $OutputDir 'lvcompare-capture.json'
                ReportPath  = Join-Path $OutputDir 'compare-report.html'
            }
            }.GetNewClosure()

            $env:GITHUB_OUTPUT = Join-Path $TestDrive ("report-output-{0}.txt" -f $Name)

            & $script:scriptPath -ResultsPath $resultsPath -ArtifactsDir $artifactsDir -RenderReport -InvokeLVCompare $invoke

            $updated = @(Get-Content -LiteralPath $resultsPath -Raw | ConvertFrom-Json)
            $compareInfo = $updated[0].compare
            $compareInfo.status | Should -Be 'diff'
            $compareInfo.reportPath | Should -Not -BeNullOrEmpty
            $compareInfo.capturePath | Should -Not -BeNullOrEmpty

            Test-Path -LiteralPath $compareInfo.reportPath | Should -BeTrue
            Test-Path -LiteralPath $compareInfo.capturePath | Should -BeTrue

            $reportHtml = Get-Content -LiteralPath $compareInfo.reportPath -Raw
            foreach ($heading in $Headings) {
                $reportHtml | Should -Match ([regex]::Escape($heading))
            }

            $summaryPath = Join-Path $artifactsDir 'vi-staging-compare.json'
            Test-Path -LiteralPath $summaryPath | Should -BeTrue
            $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
            $summaryEntries = @($summary)
            $summaryEntries.Count | Should -Be 1
            $summaryEntries[0].reportPath | Should -Be $compareInfo.reportPath
            $summaryEntries[0].status | Should -Be 'diff'

            $summarizeScript = Join-Path $script:repoRoot 'tools' 'Summarize-VIStaging.ps1'
            $summaryResult = & $summarizeScript -CompareJson $summaryPath
            $summaryResult | Should -Not -BeNullOrEmpty
            $summaryResult.pairs.Count | Should -Be 1
            $summaryResult.pairs[0].diffCategoryDetails | Should -Not -BeNullOrEmpty
            foreach ($expectedEntry in $Expected) {
                $match = @($summaryResult.pairs[0].diffCategoryDetails | Where-Object { $_.slug -eq $expectedEntry.slug })
                $match.Count | Should -BeGreaterThan 0
                if ($expectedEntry.PSObject.Properties['classification']) {
                    $match[0].classification | Should -Be $expectedEntry.classification
                }
            }
        }
    }
}


