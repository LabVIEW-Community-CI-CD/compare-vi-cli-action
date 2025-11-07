$ErrorActionPreference = 'Stop'

Describe 'Invoke-MissingInProjectCLI.ps1' -Tag 'MissingInProject','Unit' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:invokeScriptPath = Join-Path $script:repoRoot '.github/actions/missing-in-project/Invoke-MissingInProjectCLI.ps1'
        Test-Path -LiteralPath $script:invokeScriptPath | Should -BeTrue
    }

    function Script:New-MissingInProjectHarness {

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $actionDir = Join-Path $root 'missing-in-project'
        New-Item -ItemType Directory -Path $actionDir -Force | Out-Null

        $scriptPath = Join-Path $actionDir 'Invoke-MissingInProjectCLI.ps1'
        Copy-Item -LiteralPath $script:invokeScriptPath -Destination $scriptPath

        $helperPath = Join-Path $actionDir 'RunMissingCheckWithGCLI.ps1'
        $missingFilePath = Join-Path $actionDir 'missing_files.txt'

        $helperTemplate = @'
[CmdletBinding()]
param(
    [string]$LVVersion,
    [string]$Arch,
    [string]$ProjectFile
)

$missingPath = Join-Path $PSScriptRoot 'missing_files.txt'
switch ($env:MIP_TEST_MODE) {
    'missing' {
        $entries = 1..2 | ForEach-Object { "missing/placeholder_{0:D2}.txt" -f $_ }
        Set-Content -LiteralPath $missingPath -Value $entries -Encoding utf8
        $global:LASTEXITCODE = 0
        return
    }
    'failure' {
        if (Test-Path $missingPath) {
            Remove-Item $missingPath -Force -ErrorAction SilentlyContinue
        }
        $global:LASTEXITCODE = 5
        return
    }
    default {
        Set-Content -LiteralPath $missingPath -Value @() -Encoding utf8
        $global:LASTEXITCODE = 0
        return
    }
}

Describe 'RunMissingCheckWithGCLI.ps1' -Tag 'MissingInProject','Unit' {
    It 'passes the VI path via -v when invoking g-cli' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $helperPath = Join-Path $repoRoot '.github/actions/missing-in-project/RunMissingCheckWithGCLI.ps1'
        Test-Path -LiteralPath $helperPath | Should -BeTrue

        $sandbox = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

        $logPath = Join-Path $sandbox 'g-cli-args.log'
        $stubPath = Join-Path $sandbox 'g-cli.cmd'
        $stubContent = @"
@echo off
echo %*>>"$logPath%"
exit /b 0
"@
        Set-Content -LiteralPath $stubPath -Value $stubContent -Encoding ascii

        $projectFile = Join-Path $sandbox 'example.lvproj'
        Set-Content -LiteralPath $projectFile -Value '<Project/>' -Encoding utf8

        $originalGCli = $env:GCLI_EXE_PATH
        $env:GCLI_EXE_PATH = $stubPath
        Push-Location (Split-Path $helperPath -Parent)
        try {
            & $helperPath -LVVersion '2021' -Arch '64' -ProjectFile $projectFile | Out-Null
        }
        finally {
            Pop-Location
            if ($null -ne $originalGCli) {
                $env:GCLI_EXE_PATH = $originalGCli
            } else {
                Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
            }
        }

        Test-Path -LiteralPath $logPath | Should -BeTrue
        $argsLine = Get-Content -LiteralPath $logPath | Select-Object -Last 1
        $argsLine | Should -Match ' --lv-ver 2021 '
        $argsLine | Should -Match ' --arch 64 '
        $argsLine | Should -Match ' -v '
        $argsLine | Should -Match ([regex]::Escape((Resolve-Path (Join-Path $repoRoot '.github/actions/missing-in-project/MissingInProjectCLI.vi')).Path))
        $argsLine | Should -Match ([regex]::Escape((Resolve-Path $projectFile).Path))
    }
}
'@
        Set-Content -LiteralPath $helperPath -Value $helperTemplate -Encoding utf8

        $cliDir = Join-Path $root 'bin'
        New-Item -ItemType Directory -Path $cliDir -Force | Out-Null
        $cliShim = "@echo off`nexit /b 0`n"
        $gCliStubPath = Join-Path $cliDir 'g-cli.cmd'
        Set-Content -LiteralPath $gCliStubPath -Value $cliShim -Encoding ascii

        $projectFile = Join-Path $root 'example.lvproj'
        Set-Content -LiteralPath $projectFile -Value '<Project/>' -Encoding utf8

        $githubOutput = Join-Path $root 'github_output.txt'
        $resultsRoot  = Join-Path $root 'results'
        New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

        $resetHelperPath = Join-Path $actionDir 'ResetWorkspaceStub.ps1'
        $resetLogPath    = Join-Path $actionDir 'reset-log.txt'
        $resetHelperTemplate = @"
param(
    [string]`$RepoRoot,
    [string]`$IconEditorRoot,
    [int[]]`$Versions,
    [int[]]`$Bitness
)
`$entry = [pscustomobject]@{
    RepoRoot = `$RepoRoot
    IconEditorRoot = `$IconEditorRoot
    Versions = `$Versions
    Bitness = `$Bitness
    Timestamp = (Get-Date).ToString('o')
}
`$entry | ConvertTo-Json -Compress | Add-Content -Path "$resetLogPath"
"@
        Set-Content -LiteralPath $resetHelperPath -Value $resetHelperTemplate -Encoding utf8
        New-Item -ItemType File -Path $resetLogPath -Force | Out-Null

        $originalPath       = $env:PATH
        $originalGhOutput   = $env:GITHUB_OUTPUT
        $originalRepoRoot   = $env:MIP_REPO_ROOT
        $originalSkip       = $env:MIP_SKIP_DEVMODE
        $originalGCliPath     = $env:GCLI_EXE_PATH
        $originalResultsRoot  = $env:MIP_RESULTS_ROOT
        $originalResetScript  = $env:MIP_RESET_WORKSPACE_SCRIPT

        $env:PATH = "$cliDir;$originalPath"
        $env:GCLI_EXE_PATH = $gCliStubPath
        $env:GITHUB_OUTPUT = $githubOutput
        $env:MIP_REPO_ROOT = $script:repoRoot
        $env:MIP_SKIP_DEVMODE = '1'
        $env:MIP_RESULTS_ROOT = $resultsRoot
        $env:MIP_RESET_WORKSPACE_SCRIPT = $resetHelperPath

        return [pscustomobject]@{
            Root            = $root
            ActionDir       = $actionDir
            ScriptPath      = $scriptPath
            HelperPath      = $helperPath
            MissingFilePath = $missingFilePath
            ProjectFile     = $projectFile
            GithubOutput    = $githubOutput
            ResultsRoot     = $resultsRoot
            TelemetryPath   = Join-Path $resultsRoot 'last-run.json'
            ResetLogPath    = $resetLogPath
            OriginalPath    = $originalPath
            OriginalGh      = $originalGhOutput
            OriginalRepo    = $originalRepoRoot
            OriginalSkip    = $originalSkip
            OriginalGCliPath = $originalGCliPath
            OriginalResults  = $originalResultsRoot
            OriginalResetScript = $originalResetScript
            Restore         = {
                param($origPath,$origGh,$origMode,$origRepo,$origSkip,$origGCliPath,$origResults,$origResetScript)
                if ($null -ne $origPath) { $env:PATH = $origPath } else { Remove-Item Env:PATH -ErrorAction SilentlyContinue }
                if ($null -ne $origGCliPath) { $env:GCLI_EXE_PATH = $origGCliPath } else { Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue }
                if ($null -ne $origGh) { $env:GITHUB_OUTPUT = $origGh } else { Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue }
                if ($null -ne $origRepo) { $env:MIP_REPO_ROOT = $origRepo } else { Remove-Item Env:MIP_REPO_ROOT -ErrorAction SilentlyContinue }
                Remove-Item Env:MIP_TEST_MODE -ErrorAction SilentlyContinue
                if ($null -ne $origSkip) { $env:MIP_SKIP_DEVMODE = $origSkip } else { Remove-Item Env:MIP_SKIP_DEVMODE -ErrorAction SilentlyContinue }
                if ($null -ne $origResults) { $env:MIP_RESULTS_ROOT = $origResults } else { Remove-Item Env:MIP_RESULTS_ROOT -ErrorAction SilentlyContinue }
                if ($null -ne $origResetScript) { $env:MIP_RESET_WORKSPACE_SCRIPT = $origResetScript } else { Remove-Item Env:MIP_RESET_WORKSPACE_SCRIPT -ErrorAction SilentlyContinue }
            }
        }
    }

    It 'succeeds when helper reports no missing files' {
        $originalMode = $env:MIP_TEST_MODE
        $env:MIP_TEST_MODE = 'success'
        $harness = New-MissingInProjectHarness
        try {
            & $harness.ScriptPath -LVVersion '2023' -Arch '64' -ProjectFile $harness.ProjectFile | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path -LiteralPath $harness.MissingFilePath | Should -BeFalse
            (Get-Content -LiteralPath $harness.GithubOutput) | Should -Contain 'passed=true'
            Test-Path -LiteralPath $harness.TelemetryPath | Should -BeTrue
            $telemetry = Get-Content -LiteralPath $harness.TelemetryPath -Raw | ConvertFrom-Json
            $telemetry.passed | Should -BeTrue
            $telemetry.missingFiles.Count | Should -Be 0
            Test-Path -LiteralPath $telemetry.projectFile | Should -BeTrue
            [System.IO.Path]::IsPathRooted($telemetry.projectFile) | Should -BeTrue
            $telemetry.transcriptPath | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $telemetry.transcriptPath | Should -BeTrue
            Test-Path -LiteralPath $harness.ResetLogPath | Should -BeTrue
            $resetEntries = Get-Content -LiteralPath $harness.ResetLogPath
            @($resetEntries).Count | Should -BeGreaterThan 0
            ($resetEntries | Select-Object -Last 1 | ConvertFrom-Json).Versions | Should -Contain 2023
            ($resetEntries | Select-Object -Last 1 | ConvertFrom-Json).Bitness | Should -Contain 64
        }
        finally {
            & $harness.Restore $harness.OriginalPath $harness.OriginalGh $originalMode $harness.OriginalRepo $harness.OriginalSkip $harness.OriginalGCliPath $harness.OriginalResults $harness.OriginalResetScript
        }
    }

    It 'fails when helper reports missing files' {
        $originalMode = $env:MIP_TEST_MODE
        $env:MIP_TEST_MODE = 'missing'
        $harness = New-MissingInProjectHarness
        try {
            & $harness.ScriptPath -LVVersion '2023' -Arch '64' -ProjectFile $harness.ProjectFile | Out-Null
            $LASTEXITCODE | Should -Be 2
            Test-Path -LiteralPath $harness.MissingFilePath | Should -BeTrue
            (Get-Content -LiteralPath $harness.GithubOutput) | Should -Contain 'passed=false'
            Test-Path -LiteralPath $harness.TelemetryPath | Should -BeTrue
            $telemetry = Get-Content -LiteralPath $harness.TelemetryPath -Raw | ConvertFrom-Json
            $telemetry.passed | Should -BeFalse
            $telemetry.missingFiles.Count | Should -BeGreaterThan 0
        }
        finally {
            & $harness.Restore $harness.OriginalPath $harness.OriginalGh $originalMode $harness.OriginalRepo $harness.OriginalSkip $harness.OriginalGCliPath $harness.OriginalResults $harness.OriginalResetScript
        }
    }

    It 'fails with exit code 1 when helper does not emit results and fails' {
        $originalMode = $env:MIP_TEST_MODE
        $env:MIP_TEST_MODE = 'failure'
        $harness = New-MissingInProjectHarness
        try {
            & $harness.ScriptPath -LVVersion '2023' -Arch '64' -ProjectFile $harness.ProjectFile | Out-Null
            $LASTEXITCODE | Should -Be 1
            Test-Path -LiteralPath $harness.TelemetryPath | Should -BeTrue
            $telemetry = Get-Content -LiteralPath $harness.TelemetryPath -Raw | ConvertFrom-Json
            $telemetry.parsingFailed | Should -BeTrue
        }
        finally {
            & $harness.Restore $harness.OriginalPath $harness.OriginalGh $originalMode $harness.OriginalRepo $harness.OriginalSkip $harness.OriginalGCliPath $harness.OriginalResults $harness.OriginalResetScript
        }
    }

    It 'exits with error when helper script is missing' {
        $originalMode = $env:MIP_TEST_MODE
        $env:MIP_TEST_MODE = 'success'
        $harness = New-MissingInProjectHarness
        Remove-Item -LiteralPath $harness.HelperPath -Force

        try {
            & $harness.ScriptPath -LVVersion '2023' -Arch '64' -ProjectFile $harness.ProjectFile | Out-Null
            $LASTEXITCODE | Should -Be 100
            Test-Path -LiteralPath $harness.TelemetryPath | Should -BeFalse
        }
        finally {
            & $harness.Restore $harness.OriginalPath $harness.OriginalGh $originalMode $harness.OriginalRepo $harness.OriginalSkip $harness.OriginalGCliPath $harness.OriginalResults $harness.OriginalResetScript
        }
    }
}
