$ErrorActionPreference = 'Stop'

Describe 'Stage-IconEditorSnapshot.ps1' -Tag 'IconEditor','Snapshot','Unit' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Set-Variable -Scope Script -Name repoRoot -Value $repoRoot
        Set-Variable -Scope Script -Name stageScript -Value (Join-Path $repoRoot 'tools/icon-editor/Stage-IconEditorSnapshot.ps1')
        Set-Variable -Scope Script -Name vendorPath -Value (Join-Path $repoRoot 'vendor/icon-editor')

        Test-Path -LiteralPath $script:stageScript | Should -BeTrue
        Test-Path -LiteralPath $script:vendorPath | Should -BeTrue
    }

    BeforeEach {
        Set-Variable -Name StageDevModeLog -Scope Global -Value (New-Object System.Collections.Generic.List[object])
        function Get-IconEditorDevModePolicyEntry {
            param(
                [string]$Operation,
                [string]$RepoRoot
            )
            return [pscustomobject]@{
                Operation = $Operation
                Versions  = @(2025)
                Bitness   = @(64)
                Path      = 'tests-policy.json'
            }
        }
        function Enable-IconEditorDevelopmentMode {
            param(
                [int[]]$Versions,
                [int[]]$Bitness,
                [string]$RepoRoot,
                [string]$IconEditorRoot,
                [string]$Operation
            )
            $Global:StageDevModeLog.Add([pscustomobject]@{
                Action   = 'enable'
                Versions = $Versions
                Bitness  = $Bitness
                Operation = $Operation
            }) | Out-Null
        }
        function Disable-IconEditorDevelopmentMode {
            param(
                [int[]]$Versions,
                [int[]]$Bitness,
                [string]$RepoRoot,
                [string]$IconEditorRoot,
                [string]$Operation
            )
            $Global:StageDevModeLog.Add([pscustomobject]@{
                Action   = 'disable'
                Versions = $Versions
                Bitness  = $Bitness
                Operation = $Operation
            }) | Out-Null
        }
        function Get-IconEditorDevModeLabVIEWTargets {
            param(
                [string]$RepoRoot,
                [string]$IconEditorRoot,
                [int[]]$Versions,
                [int[]]$Bitness
            )
            return @(
                [pscustomobject]@{
                    Version = 2025
                    Bitness = 64
                    Present = $true
                },
                [pscustomobject]@{
                    Version = 2021
                    Bitness = 64
                    Present = $true
                }
            )
        }
    }

    AfterEach {
        Remove-Item Function:Enable-IconEditorDevelopmentMode -ErrorAction SilentlyContinue
        Remove-Item Function:Disable-IconEditorDevelopmentMode -ErrorAction SilentlyContinue
        Remove-Item Function:Get-IconEditorDevModeLabVIEWTargets -ErrorAction SilentlyContinue
        Remove-Item Function:Get-IconEditorDevModePolicyEntry -ErrorAction SilentlyContinue
        Remove-Variable -Name StageDevModeLog -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stages a snapshot using an existing source and skips validation' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $result = & $script:stageScript `
            -SourcePath $script:vendorPath `
            -WorkspaceRoot $workspaceRoot `
            -StageName 'unit-snapshot' `
            -SkipValidate

        $result | Should -Not -BeNullOrEmpty
        $result.stageRoot | Should -Match 'unit-snapshot$'
        Test-Path -LiteralPath $result.stageRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $result.resourceOverlay -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $result.headManifestPath -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $result.headReportPath -PathType Leaf | Should -BeTrue
        $result.validateRoot | Should -BeNullOrEmpty

        $manifest = Get-Content -LiteralPath $result.headManifestPath -Raw | ConvertFrom-Json -Depth 10
        $manifest.schema | Should -Be 'icon-editor/fixture-manifest@v1'
        ($manifest.entries | Measure-Object).Count | Should -BeGreaterThan 0

        $report = Get-Content -LiteralPath $result.headReportPath -Raw | ConvertFrom-Json -Depth 10
        $report.schema | Should -Be 'icon-editor/fixture-report@v1'
        $Global:StageDevModeLog.Count | Should -Be 0
    }

    It 'invokes the provided validate helper with dry-run semantics' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $validateStubDir = Join-Path $TestDrive 'validate-stub'
        $null = New-Item -ItemType Directory -Path $validateStubDir -Force
        $logPath = Join-Path $validateStubDir 'log.json'
        $validateStub = Join-Path $validateStubDir 'Invoke-ValidateLocal.ps1'
$stubTemplate = @'
param(
  [string]$BaselineFixture,
  [string]$BaselineManifest,
  [string]$ResourceOverlayRoot,
  [string]$ResultsRoot,
  [switch]$SkipLVCompare,
  [switch]$DryRun,
  [switch]$SkipBootstrap
)
$payload = [ordered]@{
  baselineFixture  = $BaselineFixture
  baselineManifest = $BaselineManifest
  resourceOverlay  = $ResourceOverlayRoot
  resultsRoot      = $ResultsRoot
  skipLVCompare    = $SkipLVCompare.IsPresent
  dryRun           = $DryRun.IsPresent
  skipBootstrap    = $SkipBootstrap.IsPresent
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "__LOG_PATH__" -Encoding utf8
'@
$stubTemplate.Replace('__LOG_PATH__', $logPath) | Set-Content -LiteralPath $validateStub -Encoding utf8

        $result = & $script:stageScript `
            -SourcePath $script:vendorPath `
            -WorkspaceRoot $workspaceRoot `
            -StageName 'unit-dryrun' `
            -InvokeValidateScript $validateStub `
            -DryRun `
            -SkipBootstrapForValidate

        $result | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.validateRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $logPath -PathType Leaf | Should -BeTrue

        $log = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json -Depth 4
        $log.resultsRoot | Should -Be $result.validateRoot
        ($log.skipLVCompare -eq $true) | Should -BeTrue
        ($log.dryRun -eq $true) | Should -BeTrue
        ($log.skipBootstrap -eq $true) | Should -BeTrue
        Test-Path -LiteralPath $log.resourceOverlay -PathType Container | Should -BeTrue

        $Global:StageDevModeLog.Count | Should -Be 2
        $Global:StageDevModeLog[0].Action | Should -Be 'enable'
        $Global:StageDevModeLog[0].Operation | Should -Be 'Compare'
        ($Global:StageDevModeLog[0].Versions -join ',') | Should -Be '2025'
        ($Global:StageDevModeLog[0].Bitness -join ',')  | Should -Be '64'
        $Global:StageDevModeLog[1].Action | Should -Be 'disable'
        $Global:StageDevModeLog[1].Operation | Should -Be 'Compare'
        ($Global:StageDevModeLog[1].Versions -join ',') | Should -Be '2025'
        ($Global:StageDevModeLog[1].Bitness -join ',')  | Should -Be '64'
    }

    It 'honors dev mode overrides' {
        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $validateStubDir = Join-Path $TestDrive 'validate-override'
        $null = New-Item -ItemType Directory -Path $validateStubDir -Force
        $logPath = Join-Path $validateStubDir 'log.json'
        $validateStub = Join-Path $validateStubDir 'Invoke-ValidateLocal.ps1'
$stubTemplate = @'
param(
  [string]$BaselineFixture,
  [string]$BaselineManifest,
  [string]$ResourceOverlayRoot,
  [string]$ResultsRoot,
  [switch]$SkipLVCompare,
  [switch]$DryRun,
  [switch]$SkipBootstrap
)
$payload = [ordered]@{
  baselineFixture  = $BaselineFixture
  baselineManifest = $BaselineManifest
  resourceOverlay  = $ResourceOverlayRoot
  resultsRoot      = $ResultsRoot
  skipLVCompare    = $SkipLVCompare.IsPresent
  dryRun           = $DryRun.IsPresent
  skipBootstrap    = $SkipBootstrap.IsPresent
}
$payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "__LOG_PATH__" -Encoding utf8
'@
$stubTemplate.Replace('__LOG_PATH__', $logPath) | Set-Content -LiteralPath $validateStub -Encoding utf8

        $result = & $script:stageScript `
            -SourcePath $script:vendorPath `
            -WorkspaceRoot $workspaceRoot `
            -StageName 'unit-override' `
            -InvokeValidateScript $validateStub `
            -DryRun `
            -SkipBootstrapForValidate `
            -DevModeVersions @(2025) `
            -DevModeBitness @(32)

        $result | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.validateRoot -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $logPath -PathType Leaf | Should -BeTrue

        $Global:StageDevModeLog.Count | Should -Be 2
        $Global:StageDevModeLog[0].Action | Should -Be 'enable'
        $Global:StageDevModeLog[0].Operation | Should -Be 'Compare'
        ($Global:StageDevModeLog[0].Versions -join ',') | Should -Be '2025'
        ($Global:StageDevModeLog[0].Bitness -join ',')  | Should -Be '32'
        $Global:StageDevModeLog[1].Action | Should -Be 'disable'
        $Global:StageDevModeLog[1].Operation | Should -Be 'Compare'
        ($Global:StageDevModeLog[1].Versions -join ',') | Should -Be '2025'
        ($Global:StageDevModeLog[1].Bitness -join ',')  | Should -Be '32'
    }

    It 'fails when LabVIEW 2025 x64 is unavailable' {
        function Get-IconEditorDevModeLabVIEWTargets {
            param(
                [string]$RepoRoot,
                [string]$IconEditorRoot,
                [int[]]$Versions,
                [int[]]$Bitness
            )
            return @(
                [pscustomobject]@{
                    Version = 2021
                    Bitness = 64
                    Present = $true
                }
            )
        }

        $workspaceRoot = Join-Path $TestDrive 'workspace-missing'
        $validateStubDir = Join-Path $TestDrive 'validate-missing'
        $null = New-Item -ItemType Directory -Path $validateStubDir -Force
        $validateStub = Join-Path $validateStubDir 'Invoke-ValidateLocal.ps1'
        $logPath = Join-Path $validateStubDir 'log.txt'
$stubTemplate = @'
param()
"validate-called" | Set-Content -LiteralPath "__LOG_PATH__" -Encoding utf8
'@
$stubTemplate.Replace('__LOG_PATH__', $logPath) | Set-Content -LiteralPath $validateStub -Encoding utf8

        $threw = $false
        try {
            & $script:stageScript `
                -SourcePath $script:vendorPath `
                -WorkspaceRoot $workspaceRoot `
                -StageName 'missing-dev-mode' `
                -InvokeValidateScript $validateStub `
                -DryRun `
                -SkipBootstrapForValidate
        } catch {
            $threw = $true
            $_.Exception.Message | Should -Match 'LabVIEW 2025 64-bit not detected'
        }
        $threw | Should -BeTrue

        $Global:StageDevModeLog.Count | Should -Be 0
    }
}
