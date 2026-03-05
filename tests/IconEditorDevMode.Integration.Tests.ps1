Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'IconEditor development mode (integration)' -Tag 'IconEditor','Integration','DevMode' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:iconEditorRoot = Join-Path $script:repoRoot 'vendor' 'icon-editor'

        $vendorModule = Join-Path $script:repoRoot 'tools' 'VendorTools.psm1'
        if (Test-Path -LiteralPath $vendorModule -PathType Leaf) {
            Import-Module $vendorModule -Force
        }

        $devModeModule = Join-Path $script:repoRoot 'tools' 'icon-editor' 'IconEditorDevMode.psm1'
        if (Test-Path -LiteralPath $devModeModule -PathType Leaf) {
            Import-Module $devModeModule -Force
        }
    }

    It 'enables development mode for LabVIEW 2025 x64 when available' {
        if (-not (Get-Command Get-IconEditorDevModeLabVIEWTargets -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'IconEditorDevMode module not available.'
            return
        }

        $targets = Get-IconEditorDevModeLabVIEWTargets `
            -RepoRoot $script:repoRoot `
            -IconEditorRoot $script:iconEditorRoot `
            -Versions @(2025) `
            -Bitness @(64)

        $presentTarget = $targets | Where-Object { $_.Present -and $_.Version -eq 2025 -and $_.Bitness -eq 64 } | Select-Object -First 1
        if (-not $presentTarget) {
            Set-ItResult -Skipped -Because 'LabVIEW 2025 x64 not detected on this machine.'
            return
        }

        if (-not (Get-Command Find-LabVIEWVersionExePath -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'VendorTools module missing LabVIEW helpers.'
            return
        }

        $labviewExe = Find-LabVIEWVersionExePath -Version 2025 -Bitness 64
        if (-not $labviewExe) {
            Set-ItResult -Skipped -Because 'LabVIEW 2025 x64 executable path unresolved.'
            return
        }

        $labviewIniPath = Get-LabVIEWIniPath -LabVIEWExePath $labviewExe
        if (-not $labviewIniPath) {
            Set-ItResult -Skipped -Because 'LabVIEW 2025 x64 INI path unresolved.'
            return
        }

        $enableScript = Join-Path $script:repoRoot 'tools/icon-editor/Enable-DevMode.ps1'
        $disableScript = Join-Path $script:repoRoot 'tools/icon-editor/Disable-DevMode.ps1'
        if (-not (Test-Path -LiteralPath $enableScript -PathType Leaf) -or -not (Test-Path -LiteralPath $disableScript -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'Enable/Disable DevMode helper scripts not found.'
            return
        }

        $stateOriginal = Get-IconEditorDevModeState -RepoRoot $script:repoRoot
        $previousActive = [bool]$stateOriginal.Active
        $restoreOperation = 'BuildPackage'
        if ($stateOriginal.Source -match 'Enable-IconEditorDevelopmentMode:(?<op>.+)$') {
            $restoreOperation = $Matches['op']
        }

        $proofDir = Join-Path $script:repoRoot 'tests/results/_agent/icon-editor'
        if (-not (Test-Path -LiteralPath $proofDir -PathType Container)) {
            New-Item -ItemType Directory -Path $proofDir -Force | Out-Null
        }
        $proofPath = Join-Path $proofDir 'dev-mode-proof.json'

        try {
            & pwsh -NoLogo -NoProfile -File $enableScript `
                -RepoRoot $script:repoRoot `
                -IconEditorRoot $script:iconEditorRoot `
                -Operation 'Compare' | Out-Null

            $stateAfterEnable = Get-IconEditorDevModeState -RepoRoot $script:repoRoot
            $stateAfterEnable.Active | Should -BeTrue
            Test-Path -LiteralPath $stateAfterEnable.Path -PathType Leaf | Should -BeTrue

            $tokenValue = Get-LabVIEWIniValue -LabVIEWExePath $labviewExe -Key 'Localhost.LibraryPaths'
            $tokenValue | Should -Not -BeNullOrEmpty

            $iconRootResolved = (Resolve-Path -LiteralPath $script:iconEditorRoot).Path
            $tokenValue | Should -Match ([regex]::Escape($iconRootResolved))

            $proof = [ordered]@{
                schema      = 'icon-editor/dev-mode-proof@v1'
                generatedAt = (Get-Date).ToString('o')
                operation   = 'Compare'
                state       = [ordered]@{
                    path      = $stateAfterEnable.Path
                    active    = $stateAfterEnable.Active
                    updatedAt = $stateAfterEnable.UpdatedAt
                    source    = $stateAfterEnable.Source
                }
                ini         = [ordered]@{
                    path  = $labviewIniPath
                    value = $tokenValue
                }
            }
            $proof | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $proofPath -Encoding UTF8
        }
        finally {
            & pwsh -NoLogo -NoProfile -File $disableScript `
                -RepoRoot $script:repoRoot `
                -IconEditorRoot $script:iconEditorRoot `
                -Operation 'Compare' | Out-Null
            if ($previousActive) {
                & pwsh -NoLogo -NoProfile -File $enableScript `
                    -RepoRoot $script:repoRoot `
                    -IconEditorRoot $script:iconEditorRoot `
                    -Operation $restoreOperation | Out-Null
            }
        }

        if (-not $previousActive) {
            $stateAfterDisable = Get-IconEditorDevModeState -RepoRoot $script:repoRoot
            $stateAfterDisable.Active | Should -BeFalse
        }
    }
}
