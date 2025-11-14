#Requires -Version 7.0
#Requires -Modules Pester

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'VipmBuildHelpers module' -Tag 'Vipm','Packaging','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $modulePath = Join-Path $repoRoot 'tools' 'icon-editor' 'VipmBuildHelpers.psm1'
        Test-Path -LiteralPath $modulePath | Should -BeTrue
        $module = Import-Module $modulePath -Force -PassThru
        $script:moduleName = $module.Name
        Import-Module (Join-Path $repoRoot 'tools' 'vendor' 'IconEditorPackaging.psm1') -Force | Out-Null
    }

    Context 'Initialize-VipmBuildTelemetry' {
        It 'creates telemetry directory when missing' {
            $repoStub = Join-Path $TestDrive 'repo'
            New-Item -ItemType Directory -Path $repoStub | Out-Null

            $logPath = Initialize-VipmBuildTelemetry -RepoRoot $repoStub

            Test-Path -LiteralPath $logPath -PathType Container | Should -BeTrue
            $logPath | Should -Match '\\tests\\results\\_agent\\icon-editor\\vipm-cli-build$'
        }
    }

    Context 'Invoke-VipmPackageBuild' {
        BeforeEach {
            $script:iconEditorRoot = Join-Path $TestDrive 'icon-root'
            $script:resultsRoot = Join-Path $TestDrive 'results-root'
            foreach ($path in @($script:iconEditorRoot, $script:resultsRoot)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Recurse -Force
                }
                New-Item -ItemType Directory -Path $path | Out-Null
            }
        }

        It 'returns existing artifacts in display-only mode and records telemetry' {
            $vipPath = Join-Path $resultsRoot 'ni_icon_editor.vip'
            Set-Content -LiteralPath $vipPath -Value 'vip payload' -Encoding UTF8
            $logsRoot = Join-Path $TestDrive 'logs'

            $result = Invoke-VipmPackageBuild `
                -InvokeAction { throw 'should not invoke' } `
                -ModifyScriptPath (Join-Path $TestDrive 'modify.ps1') `
                -BuildScriptPath (Join-Path $TestDrive 'build.ps1') `
                -IconEditorRoot $iconEditorRoot `
                -ResultsRoot $resultsRoot `
                -TelemetryRoot $logsRoot `
                -DisplayOnly `
                -Toolchain 'vipm' `
                -Provider 'vipm'

            $result.DisplayOnly | Should -BeTrue
            ($result.Artifacts | Where-Object { $_.Name -eq 'ni_icon_editor.vip' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $result.TelemetryPath -PathType Leaf | Should -BeTrue
        }

        It 'invokes vendor packaging helper and writes telemetry' {
            $modifyScript = Join-Path $TestDrive 'modify.ps1'
            $buildScript  = Join-Path $TestDrive 'build.ps1'
            $closeScript  = Join-Path $TestDrive 'close.ps1'
            Set-Content -LiteralPath $modifyScript -Value 'param()' -Encoding UTF8
            Set-Content -LiteralPath $buildScript -Value 'param()' -Encoding UTF8
            Set-Content -LiteralPath $closeScript -Value 'param()' -Encoding UTF8

            $telemetryRoot = Join-Path $TestDrive 'logs'
            $artifactRecord = [ordered]@{
                SourcePath       = Join-Path $iconEditorRoot 'source.vip'
                DestinationPath  = Join-Path $resultsRoot 'source.vip'
                Name             = 'source.vip'
                Kind             = 'vip'
                SizeBytes        = 42
                LastWriteTimeUtc = (Get-Date).ToString('o')
            }

            Mock -ModuleName $script:moduleName Invoke-IconEditorVipPackaging {
                return [pscustomobject]@{
                    Artifacts = @($artifactRecord)
                    Toolchain = 'vipm'
                    Provider  = 'vipm'
                }
            }

            $result = Invoke-VipmPackageBuild `
                -InvokeAction { param($ScriptPath, $Arguments) } `
                -ModifyScriptPath $modifyScript `
                -BuildScriptPath $buildScript `
                -CloseScriptPath $closeScript `
                -IconEditorRoot $iconEditorRoot `
                -ResultsRoot $resultsRoot `
                -TelemetryRoot $telemetryRoot `
                -Metadata @{ version = @{ major = 1 } } `
                -Toolchain 'vipm' `
                -Provider 'vipm'

            $result.DisplayOnly | Should -BeFalse
            $result.Artifacts.Count | Should -Be 1
            Assert-MockCalled Invoke-IconEditorVipPackaging -ModuleName $script:moduleName -Times 1
            Test-Path -LiteralPath $result.TelemetryPath -PathType Leaf | Should -BeTrue
        }
    }
}
