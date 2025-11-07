#Requires -Version 7.0

Set-StrictMode -Version Latest

Describe 'IconEditorPackage helpers' {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $modulePath = Join-Path $repoRoot 'tools\icon-editor\IconEditorPackage.psm1'
        Import-Module $modulePath -Force

        Import-Module (Join-Path $repoRoot 'tools\GCli.psm1') -Force
        Import-Module (Join-Path $repoRoot 'tools\Vipm.psm1') -Force

        $script:VipbPath = Join-Path $repoRoot '.github\actions\build-vi-package\NI Icon editor.vipb'
        if (-not (Test-Path -LiteralPath $script:VipbPath -PathType Leaf)) {
            throw "Fixture VIPB not found at '$script:VipbPath'."
        }

        $script:WorkspaceRoot = $repoRoot
    }

    It 'extracts the package file name from the VIPB' {
        Get-IconEditorPackageName -VipbPath $script:VipbPath | Should -Be 'NI_Icon_editor'
    }

    It 'computes a deterministic package path inside the default builds folder' {
        $expected = Join-Path $script:WorkspaceRoot '.github\builds\VI Package\NI_Icon_editor-0.6.0.1213.vip'
        $path = Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 0 -Minor 6 -Patch 0 -Build 1213 -WorkspaceRoot $script:WorkspaceRoot

        $path | Should -Be $expected

        # Idempotency: a second call should return the identical path without mutating state.
        Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 0 -Minor 6 -Patch 0 -Build 1213 -WorkspaceRoot $script:WorkspaceRoot |
            Should -Be $expected
    }

    It 'supports overriding the output directory when computing package path' {
        $customDir = Join-Path $TestDrive 'packages'
        $path = Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 1 -Minor 2 -Patch 3 -Build 4 -WorkspaceRoot $script:WorkspaceRoot -OutputDirectory $customDir

        $path | Should -Be (Join-Path $customDir 'NI_Icon_editor-1.2.3.4.vip')
    }

    Context 'Process helpers' {
        It 'captures stdout, stderr, and warnings from provider process failure' {
            $scriptPath = Join-Path $TestDrive 'emit-warning.ps1'
            @'
Write-Output "[WARN] simulated warning"
[Console]::Error.WriteLine("simulated error")
exit 42
'@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8
            try {
                $result = Invoke-IconEditorProcess -Binary (Get-Command pwsh).Source -Arguments @('-NoLogo','-NoProfile','-File',$scriptPath) -Quiet
                $result.ExitCode | Should -Be 42
                $result.StdErr | Should -Match 'simulated error'
                ($result.Warnings -join ' ') | Should -Match 'simulated warning'
            } finally {
                Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
            }
        }

        It 'reports exit code and warnings for successful runs' {
            $scriptPath = Join-Path $TestDrive 'emit-success.ps1'
            @'
Write-Output "[WARN] mock provider warning"
exit 0
'@ | Set-Content -LiteralPath $scriptPath -Encoding UTF8
            try {
                $result = Invoke-IconEditorProcess -Binary (Get-Command pwsh).Source -Arguments @('-NoLogo','-NoProfile','-File',$scriptPath) -Quiet
                $result.ExitCode | Should -Be 0
                $result.Warnings | Should -Contain '[WARN] mock provider warning'
                $result.DurationSeconds -ge 0 | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $scriptPath -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Package artifact helper' {
        It 'returns metadata when the package exists' {
            $packagePath = Join-Path $TestDrive 'sample.vip'
            Set-Content -LiteralPath $packagePath -Value 'payload' -Encoding UTF8

            $artifact = Confirm-IconEditorPackageArtifact -PackagePath $packagePath
            $artifact.PackagePath | Should -Be (Resolve-Path -LiteralPath $packagePath).Path
            $artifact.SizeBytes | Should -Be ((Get-Item -LiteralPath $packagePath).Length)
            $artifact.Sha256 | Should -Be ((Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash)
        }

        It 'throws when the expected package is missing' {
            { Confirm-IconEditorPackageArtifact -PackagePath (Join-Path $TestDrive 'missing.vip') } | Should -Throw
        }
    }

    Context 'VI Server snapshot captures' {
        It 'returns a structured snapshot even when LabVIEW 2023 is unavailable' {
            $snapshot = Get-IconEditorViServerSnapshot -Version 2023 -Bitness 64 -WorkspaceRoot $script:WorkspaceRoot
            $snapshot | Should -Not -BeNullOrEmpty
            $snapshot.Version | Should -Be 2023
            $snapshot.Bitness | Should -Be 64

            $allowedStatuses = @('ok','missing','missing-ini','vendor-tools-missing','error')
            $snapshot.Status | Should -BeIn $allowedStatuses
        }
    }

    Context 'Invoke-IconEditorVipBuild provider selection' {
        BeforeAll {
            $script:fakeBuildScript = Join-Path $TestDrive 'fake-build.ps1'
            $fakeScriptContent = @'
param()
$packagePath = [Environment]::GetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE')
if (-not [string]::IsNullOrWhiteSpace($packagePath)) {
    $dir = Split-Path -Parent $packagePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Set-Content -LiteralPath $packagePath -Value 'mock package' -Encoding UTF8 -Force
}
Write-Output "[WARN] mock provider warning"
exit 0
'@
            Set-Content -LiteralPath $script:fakeBuildScript -Value $fakeScriptContent -Encoding UTF8
        }

        AfterAll {
            Remove-Item -LiteralPath $script:fakeBuildScript -ErrorAction SilentlyContinue
        }

        It 'invokes g-cli provider when requested and surfaces provider metadata' {
            $expected = Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 0 -Minor 6 -Patch 0 -Build 1300 -WorkspaceRoot $script:WorkspaceRoot
            $prevEnv = [Environment]::GetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE')
            try {
                [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $expected, [System.EnvironmentVariableTarget]::Process)

                Mock -CommandName Get-IconEditorViServerSnapshot -ModuleName IconEditorPackage -MockWith {
                    [pscustomobject]@{
                        Version = 2023
                        Bitness = 64
                        Status  = 'ok'
                        ExePath = 'C:\LabVIEW.exe'
                        IniPath = 'C:\LabVIEW.ini'
                        Enabled = 'TRUE'
                        ServerEnabled = $true
                        Port    = 3368
                    }
                } -Verifiable

                Mock -CommandName Get-GCliInvocation -ModuleName IconEditorPackage -MockWith {
                    [pscustomobject]@{
                        Provider  = 'mock-gcli'
                        Binary    = (Get-Command pwsh).Source
                        Arguments = @('-NoLogo','-NoProfile','-File',$script:fakeBuildScript)
                    }
                } -Verifiable

                $result = Invoke-IconEditorVipBuild `
                    -VipbPath $script:VipbPath `
                    -Major 0 `
                    -Minor 6 `
                    -Patch 0 `
                    -Build 1300 `
                    -SupportedBitness 64 `
                    -MinimumSupportedLVVersion 2023 `
                    -LabVIEWMinorRevision 3 `
                    -ReleaseNotesPath 'Tooling/deployment/release_notes.md' `
                    -WorkspaceRoot $script:WorkspaceRoot `
                    -Provider 'gcli' `
                    -GCliProviderName 'mock-gcli'

                Assert-MockCalled -CommandName Get-GCliInvocation -ModuleName IconEditorPackage -Times 1
                Assert-MockCalled -CommandName Get-IconEditorViServerSnapshot -ModuleName IconEditorPackage -Times 1
            } finally {
                if ($null -ne $prevEnv) {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $prevEnv, [System.EnvironmentVariableTarget]::Process)
                } else {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $null, [System.EnvironmentVariableTarget]::Process)
                }
            }

            $result.Provider | Should -Be 'mock-gcli'
            $result.PackagePath | Should -Be $expected
            Test-Path -LiteralPath $expected | Should -BeTrue
            $result.Warnings | Should -Not -BeNullOrEmpty
            $result.ProviderBinary | Should -Be (Get-Command pwsh).Source
            $result.DurationSeconds -ge 0 | Should -BeTrue
            $result.PackageSha256 | Should -Be ((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash)
            $result.PackageSize | Should -Be ((Get-Item -LiteralPath $expected).Length)
            if (Test-Path -LiteralPath $expected) {
                Remove-Item -LiteralPath $expected -Force
            }
        }

        It 'invokes VIPM provider when requested and reports provider name' {
            $expected = Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 0 -Minor 6 -Patch 0 -Build 1301 -WorkspaceRoot $script:WorkspaceRoot
            $prevEnv = [Environment]::GetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE')
            try {
                [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $expected, [System.EnvironmentVariableTarget]::Process)

                Mock -CommandName Get-VipmInvocation -ModuleName IconEditorPackage -MockWith {
                    [pscustomobject]@{
                        Provider  = 'mock-vipm'
                        Binary    = (Get-Command pwsh).Source
                        Arguments = @('-NoLogo','-NoProfile','-File',$script:fakeBuildScript)
                    }
                } -Verifiable

                $result = Invoke-IconEditorVipBuild `
                    -VipbPath $script:VipbPath `
                    -Major 0 `
                    -Minor 6 `
                    -Patch 0 `
                    -Build 1301 `
                    -SupportedBitness 64 `
                    -MinimumSupportedLVVersion 2023 `
                    -LabVIEWMinorRevision 3 `
                    -ReleaseNotesPath 'Tooling/deployment/release_notes.md' `
                    -WorkspaceRoot $script:WorkspaceRoot `
                    -Provider 'vipm' `
                    -VipmProviderName 'mock-vipm'

                Assert-MockCalled -CommandName Get-VipmInvocation -ModuleName IconEditorPackage -Times 1
            } finally {
                if ($null -ne $prevEnv) {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $prevEnv, [System.EnvironmentVariableTarget]::Process)
                } else {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $null, [System.EnvironmentVariableTarget]::Process)
                }
            }

            $result.Provider | Should -Be 'mock-vipm'
            $result.PackagePath | Should -Be $expected
            Test-Path -LiteralPath $expected | Should -BeTrue
            $result.ProviderBinary | Should -Be (Get-Command pwsh).Source
            $result.PackageSha256 | Should -Be ((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash)
            $result.PackageSize | Should -Be ((Get-Item -LiteralPath $expected).Length)
            if (Test-Path -LiteralPath $expected) {
                Remove-Item -LiteralPath $expected -Force
            }
        }

        It 'throws when provider process exits non-zero and includes output' {
            Mock -CommandName Get-IconEditorViServerSnapshot -ModuleName IconEditorPackage -MockWith {
                [pscustomobject]@{
                    Version = 2023
                    Bitness = 64
                    Status  = 'ok'
                    ExePath = 'C:\LabVIEW.exe'
                    IniPath = 'C:\LabVIEW.ini'
                    Enabled = 'TRUE'
                    ServerEnabled = $true
                    Port    = 3368
                }
            }

            Mock -CommandName Get-GCliInvocation -ModuleName IconEditorPackage -MockWith {
                [pscustomobject]@{
                    Provider  = 'mock-gcli'
                    Binary    = 'C:\fake\g-cli.exe'
                    Arguments = @('--fake')
                }
            } -Verifiable

            Mock -CommandName Invoke-IconEditorProcess -ModuleName IconEditorPackage -MockWith {
                [pscustomobject]@{
                    Binary          = 'C:\fake\g-cli.exe'
                    Arguments       = @('--fake')
                    ExitCode        = 1
                    StdOut          = ''
                    StdErr          = 'ERROR: vipb.vi missing'
                    Output          = 'ERROR: vipb.vi missing'
                    DurationSeconds = 0.1
                    Warnings        = @('ERROR: vipb.vi missing')
                }
            } -Verifiable

            Mock -CommandName Confirm-IconEditorPackageArtifact -ModuleName IconEditorPackage -MockWith {
                throw 'Confirm-IconEditorPackageArtifact should not be called on failure.'
            }

            $threw = $false
            $message = $null
            try {
                Invoke-IconEditorVipBuild `
                    -VipbPath $script:VipbPath `
                    -Major 0 `
                    -Minor 6 `
                    -Patch 0 `
                    -Build 1303 `
                    -SupportedBitness 64 `
                    -MinimumSupportedLVVersion 2023 `
                    -LabVIEWMinorRevision 3 `
                    -ReleaseNotesPath 'Tooling/deployment/release_notes.md' `
                    -WorkspaceRoot $script:WorkspaceRoot `
                    -Provider 'gcli'
            } catch {
                $threw = $true
                $message = $_.Exception.Message
            }

            $threw | Should -BeTrue
            $message | Should -Match 'vipb\.vi missing'

            Assert-MockCalled -CommandName Invoke-IconEditorProcess -ModuleName IconEditorPackage -Times 1
            Assert-MockCalled -CommandName Confirm-IconEditorPackageArtifact -ModuleName IconEditorPackage -Times 0 -Exactly
        }

        It 'warns when g-cli provider detects disabled VI Server but proceeds' {
            Mock -CommandName Get-IconEditorViServerSnapshot -ModuleName IconEditorPackage -MockWith {
                [pscustomobject]@{
                    Version = 2023
                    Bitness = 64
                    Status  = 'ok'
                    Message = 'LabVIEW VI Server disabled'
                    ExePath = 'C:\LabVIEW.exe'
                    IniPath = 'C:\LabVIEW.ini'
                    Enabled = 'FALSE'
                    ServerEnabled = $false
                    Port    = 3368
                }
            }

            Mock -CommandName Get-GCliInvocation -ModuleName IconEditorPackage -MockWith {
                [pscustomobject]@{
                    Provider  = 'mock-gcli'
                    Binary    = (Get-Command pwsh).Source
                    Arguments = @('-NoLogo','-NoProfile','-File',$script:fakeBuildScript)
                }
            } -Verifiable

            Mock -CommandName Write-Warning -ModuleName IconEditorPackage -MockWith { param($Message) }

            $expected = Get-IconEditorPackagePath -VipbPath $script:VipbPath -Major 0 -Minor 6 -Patch 0 -Build 1302 -WorkspaceRoot $script:WorkspaceRoot
            $prevEnv = [Environment]::GetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE')
            try {
                [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $expected, [System.EnvironmentVariableTarget]::Process)

                $result = Invoke-IconEditorVipBuild `
                    -VipbPath $script:VipbPath `
                    -Major 0 `
                    -Minor 6 `
                    -Patch 0 `
                    -Build 1302 `
                    -SupportedBitness 64 `
                    -MinimumSupportedLVVersion 2023 `
                    -LabVIEWMinorRevision 3 `
                    -ReleaseNotesPath 'Tooling/deployment/release_notes.md' `
                    -WorkspaceRoot $script:WorkspaceRoot `
                    -Provider 'gcli' `
                    -GCliProviderName 'mock-gcli'
            } finally {
                if ($null -ne $prevEnv) {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $prevEnv, [System.EnvironmentVariableTarget]::Process)
                } else {
                    [Environment]::SetEnvironmentVariable('ICON_EDITOR_EXPECTED_PACKAGE', $null, [System.EnvironmentVariableTarget]::Process)
                }
            }

            $result.Provider | Should -Be 'mock-gcli'
            Test-Path -LiteralPath $expected | Should -BeTrue
            Assert-MockCalled -CommandName Write-Warning -ModuleName IconEditorPackage -Times 1 -ParameterFilter { $Message -like '*appears disabled*' }
            ($result.Warnings -join ' ') | Should -Match 'appears disabled'
            if (Test-Path -LiteralPath $expected) {
                Remove-Item -LiteralPath $expected -Force
            }
        }
    }
}
