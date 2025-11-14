#Requires -Version 7.0
#Requires -Modules Pester

param()

Describe 'MissingInProject honours dev-mode token' -Tag 'IconEditor','Integration','MissingInProject' {
    $script:repoRoot = $null
    $script:projectFile = $null
    $script:enableDevScript = $null
    $script:disableDevScript = $null
    $script:buildLvlibpScript = $null
    $script:renameScript = $null
    $script:invokeMissingScript = $null

    $cases = @(
        @{ Version = 2021; Bitness = 32 }
        @{ Version = 2021; Bitness = 64 }
        # add more combinations once the host has additional LabVIEW installations available
    )

    # Discovery-time readiness guard: skip this suite if LabVIEW 2021
    # (32/64) is not available on the host. This avoids discovery errors
    # on machines without those versions installed.
    try {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $repoRoot 'tools' 'VendorTools.psm1') -Force
        $missing = 0
        foreach ($c in $cases) {
            $exe = $null
            try { $exe = Find-LabVIEWVersionExePath -Version ([int]$c.Version) -Bitness ([int]$c.Bitness) } catch { $exe = $null }
            if (-not $exe) { $missing++ }
        }
        if ($missing -gt 0) {
            Write-Host "Skipping dev-mode MissingInProject tests: LabVIEW 2021 (32/64) not fully available on this host." -ForegroundColor Yellow
            return
        }
    } catch {
        Write-Host "Skipping dev-mode MissingInProject tests: vendor tool resolution failed ($($_.Exception.Message))." -ForegroundColor Yellow
        return
    }

    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:projectFile = Join-Path -Path $script:repoRoot -ChildPath 'vendor\icon-editor\lv_icon_editor.lvproj'
        $script:enableDevScript  = Join-Path -Path $script:repoRoot -ChildPath 'tools\icon-editor\Enable-DevMode.ps1'
        $script:disableDevScript = Join-Path -Path $script:repoRoot -ChildPath 'tools\icon-editor\Disable-DevMode.ps1'
        $script:buildLvlibpScript = Join-Path -Path $script:repoRoot -ChildPath 'vendor\icon-editor\.github\actions\build-lvlibp\Build_lvlibp.ps1'
        $script:closeLvScript     = Join-Path -Path $script:repoRoot -ChildPath 'vendor\icon-editor\.github\actions\close-labview\Close_LabVIEW.ps1'
        $script:renameScript      = Join-Path -Path $script:repoRoot -ChildPath 'vendor\icon-editor\.github\actions\rename-file\Rename-file.ps1'
        $script:invokeMissingScript = Join-Path -Path $script:repoRoot -ChildPath '.github\actions\missing-in-project\Invoke-MissingInProjectCLI.ps1'
        $script:expectedLvlibpSignature = @{
            '32' = 'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAA4fug4AtAnNIbgBTM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAADF2cHYgbivi4G4r4uBuK+LiMAli4C4r4uf6juLgLivi4jAPouAuK+LUmljaIG4r4sAAAAAAAAAAAAAAAAAAAAAUEUAAEwBAQBLUbFKAAAAAAAAAADgAAMhCwEJAAAAAAAAni0AAAAAAAAAAAAAEAAAABAAAAAAABAAEAAAAAIAAA=='
            '64' = 'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAAA4fug4AtAnNIbgBTM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAADF2cHYgbivi4G4r4uBuK+LiMAli4C4r4uf6juLgLivi4jAPouAuK+LUmljaIG4r4sAAAAAAAAAAAAAAAAAAAAAUEUAAEwBAQBLUbFKAAAAAAAAAADgAAMhCwEJAAAAAAAAqC0AAAAAAAAAAAAAEAAAABAAAAAAABAAEAAAAAIAAA=='
        }

        Test-Path -LiteralPath $script:projectFile | Should -BeTrue -Because 'MissingInProject tests require the icon editor project'
        Test-Path -LiteralPath $script:enableDevScript | Should -BeTrue
        Test-Path -LiteralPath $script:disableDevScript | Should -BeTrue
        Test-Path -LiteralPath $script:buildLvlibpScript | Should -BeTrue
        Test-Path -LiteralPath $script:closeLvScript | Should -BeTrue
        Test-Path -LiteralPath $script:renameScript | Should -BeTrue
        Test-Path -LiteralPath $script:invokeMissingScript | Should -BeTrue

        Import-Module (Join-Path $script:repoRoot 'tests\helpers\Invoke-PackedLibraryBuild.psm1') -Force

        $env:MIP_REPO_ROOT = $repoRoot               # allow Invoke-MissingInProjectCLI.ps1 to locate resolver helpers
        $env:MIP_SKIP_DEVMODE = '1'                  # tests toggle dev-mode directly
        Remove-Item Env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item Env:MIP_REPO_ROOT, Env:MIP_SKIP_DEVMODE -ErrorAction SilentlyContinue
        Remove-Item Env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT -ErrorAction SilentlyContinue
    }

    Context 'LabVIEW dev-mode token behaviour' {
        It "passes MissingInProject when dev mode is enabled (LabVIEW <Version> <Bitness>-bit)" -TestCases $cases {
            param([int]$Version, [int]$Bitness)

            { & $script:enableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage } | Should -Not -Throw

            Push-Location $script:repoRoot
            try {
                & $script:invokeMissingScript -LVVersion $Version -Arch $Bitness -ProjectFile $script:projectFile
                $LASTEXITCODE | Should -Be 0
            }
            finally {
                Pop-Location
                try { & $script:disableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage | Out-Null } catch {}
            }
        }

        It "fails MissingInProject after dev mode is disabled (LabVIEW <Version> <Bitness>-bit)" -TestCases $cases {
            param([int]$Version, [int]$Bitness)

            { & $script:disableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage } | Should -Not -Throw

            Push-Location $script:repoRoot
            try {
                & $script:invokeMissingScript -LVVersion $Version -Arch $Bitness -ProjectFile $script:projectFile
                $LASTEXITCODE | Should -Not -Be 0
            }
            finally {
                Pop-Location
                try { & $script:disableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage | Out-Null } catch {}
            }
        }

        It "builds the icon editor packed library after validations (LabVIEW <Version> <Bitness>-bit)" -TestCases $cases {
            param([int]$Version, [int]$Bitness)

            $iconEditorRoot = Join-Path -Path $script:repoRoot -ChildPath 'vendor\icon-editor'
            $artifactPath   = Join-Path -Path $iconEditorRoot -ChildPath 'resource\plugins\lv_icon.lvlibp'
            $artifactX86    = Join-Path -Path $iconEditorRoot -ChildPath 'resource\plugins\lv_icon_x86.lvlibp'
            $artifactX64    = Join-Path -Path $iconEditorRoot -ChildPath 'resource\plugins\lv_icon_x64.lvlibp'
            $startTimeUtc   = (Get-Date).ToUniversalTime()

            { & $script:enableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage } | Should -Not -Throw

            $renameName = if ($Bitness -eq 32) { 'lv_icon_x86.lvlibp' } else { 'lv_icon_x64.lvlibp' }
            $targets = @(
                @{
                    Label = "$Bitness-bit"
                    BuildArguments = @(
                        '-MinimumSupportedLVVersion', $Version,
                        '-SupportedBitness', $Bitness,
                        '-IconEditorRoot', $iconEditorRoot,
                        '-Major', 1,
                        '-Minor', 0,
                        '-Patch', 0,
                        '-Build', 0,
                        '-Commit', 'dev-mode-test'
                    )
                    CloseArguments = @(
                        '-MinimumSupportedLVVersion', $Version,
                        '-SupportedBitness', $Bitness
                    )
                    RenameArguments = @(
                        '-CurrentFilename', '{{BaseArtifactPath}}',
                        '-NewFilename', $renameName
                    )
                }
            )

            Write-Host '=== Setup ==='
            Write-Host ("Icon editor root : {0}" -f $iconEditorRoot)
            Write-Host ("Build script     : {0}" -f $script:buildLvlibpScript)
            Write-Host ("Close script     : {0}" -f $script:closeLvScript)
            Write-Host ("Rename script    : {0}" -f $script:renameScript)
            Write-Host ("Targets          : {0}" -f (($targets | ForEach-Object { $_.Label }) -join ', '))

            $previousSkip = $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT
            $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT = '1'

            Write-Host '=== MainSequence ==='
            Invoke-PackedLibraryBuildHelper `
                -RepoRoot $script:repoRoot `
                -BuildScriptPath $script:buildLvlibpScript `
                -CloseScriptPath $script:closeLvScript `
                -RenameScriptPath $script:renameScript `
                -ArtifactDirectory (Join-Path $iconEditorRoot 'resource\plugins') `
                -BaseArtifactName 'lv_icon.lvlibp' `
                -CleanupPatterns @('lv_icon*.lvlibp') `
                -Targets $targets

            if ($null -ne $previousSkip) {
                $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT = $previousSkip
            } else {
                Remove-Item Env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT -ErrorAction SilentlyContinue
            }

            $artifactEntries = if ($Bitness -eq 32) {
                @(@{ Path = $artifactX86; Label = 'lv_icon_x86.lvlibp'; Bitness = '32' })
            } else {
                @(@{ Path = $artifactX64; Label = 'lv_icon_x64.lvlibp'; Bitness = '64' })
            }

            foreach ($artifactEntry in $artifactEntries) {
                Test-Path -LiteralPath $artifactEntry.Path | Should -BeTrue -Because ("build should produce {0}" -f $artifactEntry.Label)
                $renamedInfo = Get-Item -LiteralPath $artifactEntry.Path
                $renamedInfo.Length | Should -BeGreaterThan 0 -Because ("{0} should contain the packed library payload" -f $artifactEntry.Label)
                $renamedInfo.LastWriteTimeUtc | Should -BeGreaterOrEqual ($startTimeUtc.AddSeconds(-2)) `
                    -Because ("{0} should be freshly emitted by the build sequence" -f $artifactEntry.Label)

                $bytesToInspect = 256
                $content = [IO.File]::ReadAllBytes($artifactEntry.Path)
                $content.Length | Should -BeGreaterThan $bytesToInspect -Because ("{0} should contain a LabVIEW-compiled payload" -f $artifactEntry.Label)
                $signature = [Convert]::ToBase64String($content[0..($bytesToInspect - 1)])
                if ($script:expectedLvlibpSignature.ContainsKey($artifactEntry.Bitness)) {
                    $expectedSignature = $script:expectedLvlibpSignature[$artifactEntry.Bitness]
                    $signature | Should -Be $expectedSignature -Because ("{0} should originate from LabVIEW (MZ header + canonical packed-library signature)" -f $artifactEntry.Label)
                } else {
                    Write-Warning ("No signature baseline for {0}; skipping signature check." -f $artifactEntry.Label)
                }
            }

            Write-Host '=== Cleanup ==='
            { & $script:disableDevScript -Versions $Version -Bitness $Bitness -Operation BuildPackage } | Should -Not -Throw
        }
    }
}

