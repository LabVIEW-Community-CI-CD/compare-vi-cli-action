#Requires -Version 7.0
#Requires -Modules Pester

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-IconEditorVipPackaging helper' -Tag 'IconEditor','Packaging','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $repoRoot 'tools' 'vendor' 'IconEditorPackaging.psm1') -Force
    }

    It 'runs modify/build/close scripts and captures emitted VI packages' {
        $iconRoot    = Join-Path $TestDrive 'icon-root'
        $resultsRoot = Join-Path $TestDrive 'results'
        New-Item -ItemType Directory -Path $iconRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

        $modifyScript = Join-Path $TestDrive 'modify.ps1'
        @'
param()
"modify invoked" | Out-File (Join-Path $env:TEMP 'modify-log.txt')
'@ | Set-Content -LiteralPath $modifyScript -Encoding UTF8

        $artifactPath = Join-Path $iconRoot 'ni_icon_editor_test.vip'
        $buildScript = Join-Path $TestDrive 'build.ps1'
        @"
param()
Set-Content -LiteralPath '$artifactPath' -Value 'vip payload'
"@ | Set-Content -LiteralPath $buildScript -Encoding UTF8

        $closeScript = Join-Path $TestDrive 'close.ps1'
        @'
param()
"close invoked" | Out-File (Join-Path $env:TEMP 'close-log.txt')
'@ | Set-Content -LiteralPath $closeScript -Encoding UTF8

        $actionInvoker = {
            param($ScriptPath, $Arguments)
            & pwsh -NoLogo -NoProfile -File $ScriptPath @Arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Packaging helper script '$ScriptPath' exited with $LASTEXITCODE."
            }
        }

        $result = Invoke-IconEditorVipPackaging `
            -InvokeAction $actionInvoker `
            -ModifyVipbScriptPath $modifyScript `
            -BuildVipScriptPath $buildScript `
            -CloseScriptPath $closeScript `
            -IconEditorRoot $iconRoot `
            -ResultsRoot $resultsRoot `
            -ArtifactCutoffUtc ((Get-Date).ToUniversalTime()) `
            -ModifyArguments @() `
            -BuildArguments @() `
            -CloseArguments @()

        $result.Artifacts.Count | Should -Be 1
        $copiedVip = Join-Path $resultsRoot 'ni_icon_editor_test.vip'
        Test-Path -LiteralPath $copiedVip | Should -BeTrue
        (Get-Content -LiteralPath $copiedVip -Raw).TrimEnd() | Should -Be 'vip payload'
    }
}
