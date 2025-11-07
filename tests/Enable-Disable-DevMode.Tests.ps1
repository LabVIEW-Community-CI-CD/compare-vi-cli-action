$ErrorActionPreference = 'Stop'

Describe 'Enable/Disable dev mode scripts' -Tag 'IconEditor','DevMode','Scripts' {
    BeforeAll {
        $script:repoRootActual = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:enableScript = Join-Path $script:repoRootActual 'tools/icon-editor/Enable-DevMode.ps1'
        $script:disableScript = Join-Path $script:repoRootActual 'tools/icon-editor/Disable-DevMode.ps1'
        Test-Path -LiteralPath $script:enableScript | Should -BeTrue
        Test-Path -LiteralPath $script:disableScript | Should -BeTrue
    }

    BeforeEach {
        $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT = '1'
    }

    AfterEach {
        Remove-Item Env:ICON_EDITOR_DEV_MODE_POLICY_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:GCLI_EXE_PATH -ErrorAction SilentlyContinue
        if ($script:StubCliPath -and (Test-Path -LiteralPath $script:StubCliPath)) {
            Remove-Item -LiteralPath $script:StubCliPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item Env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT -ErrorAction SilentlyContinue
    }

    function Script:Initialize-DevModeStubRepo {
        param([string]$Name = 'devmode-repo')

        $repoRoot = Join-Path $TestDrive $Name
        $iconRoot = Join-Path $repoRoot 'vendor' 'icon-editor'
        $actionsRoot = Join-Path $iconRoot '.github' 'actions'
        $addTokenDir = Join-Path $actionsRoot 'add-token-to-labview'
        $prepareDir  = Join-Path $actionsRoot 'prepare-labview-source'
        $closeDir    = Join-Path $actionsRoot 'close-labview'
        $restoreDir  = Join-Path $actionsRoot 'restore-setup-lv-source'
        $toolsDir    = Join-Path $repoRoot 'tools'
        $toolsIconDir = Join-Path $toolsDir 'icon-editor'

        New-Item -ItemType Directory -Path $addTokenDir,$prepareDir,$closeDir,$restoreDir,$toolsDir,$toolsIconDir -Force | Out-Null
        New-Item -ItemType Directory -Path $iconRoot -Force | Out-Null

        $gCliDir      = Join-Path $repoRoot 'fake-g-cli' 'bin'
        $gCliExePath  = Join-Path $gCliDir 'g-cli.exe'
        $gCliStubPath = Join-Path $repoRoot 'fake-g-cli' 'g-cli.ps1'
        New-Item -ItemType Directory -Path $gCliDir -Force | Out-Null
        New-Item -ItemType File -Path $gCliExePath -Value '' -Force | Out-Null

@"
function Resolve-GCliPath { return '$gCliStubPath' }
function Find-LabVIEWVersionExePath {
  param([int]`$Version, [int]`$Bitness)
  return $null
}
function Get-LabVIEWIniPath {
  param([string]`$LabVIEWExePath)
  return $null
}
Export-ModuleMember -Function Resolve-GCliPath, Find-LabVIEWVersionExePath, Get-LabVIEWIniPath
"@ | Set-Content -LiteralPath (Join-Path $toolsDir 'VendorTools.psm1') -Encoding utf8

@'
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)
exit 0
'@ | Set-Content -LiteralPath $gCliStubPath -Encoding utf8
        $env:GCLI_EXE_PATH = $gCliStubPath
        Set-Variable -Scope Script -Name StubCliPath -Value $gCliStubPath

@'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$RelativePath,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
$targetRoot = if ($IconEditorRoot) { $IconEditorRoot } elseif ($RelativePath) { $RelativePath } else { $null }
if ($targetRoot) {
  "dev-mode:on-$SupportedBitness" | Set-Content -LiteralPath (Join-Path $targetRoot 'dev-mode.txt') -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $addTokenDir 'AddTokenToLabVIEW.ps1') -Encoding utf8

        @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$RelativePath,
  [string]$LabVIEW_Project,
  [string]$Build_Spec,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
 $targetRoot = if ($IconEditorRoot) { $IconEditorRoot } elseif ($RelativePath) { $RelativePath } else { $null }
if ($targetRoot) {
  $marker = Join-Path $targetRoot ("prepare-{0}.log" -f $SupportedBitness)
  "prepare:$SupportedBitness" | Set-Content -LiteralPath $marker -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $prepareDir 'Prepare_LabVIEW_source.ps1') -Encoding utf8

        @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness
)
'@ | Set-Content -LiteralPath (Join-Path $closeDir 'Close_LabVIEW.ps1') -Encoding utf8

        @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$LabVIEW_Project,
  [string]$Build_Spec,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
$targetRoot = if ($IconEditorRoot) { $IconEditorRoot } elseif ($RelativePath) { $RelativePath } else { $null }
if ($targetRoot) {
  "dev-mode:off-$SupportedBitness" | Set-Content -LiteralPath (Join-Path $targetRoot 'dev-mode.txt') -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $restoreDir 'RestoreSetupLVSource.ps1') -Encoding utf8

        @'
[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$IconEditorRoot,
  [int[]]$Versions,
  [int[]]$Bitness,
  [switch]$SkipClose
)
$targetRoot = if ($IconEditorRoot) { $IconEditorRoot } elseif ($RelativePath) { $RelativePath } else { $null }
if ($targetRoot -and $Bitness) {
  foreach ($bit in $Bitness) {
    "dev-mode:off-$bit" | Set-Content -LiteralPath (Join-Path $targetRoot 'dev-mode.txt') -Encoding utf8
  }
}
'@ | Set-Content -LiteralPath (Join-Path $toolsIconDir 'Reset-IconEditorWorkspace.ps1') -Encoding utf8

        return [pscustomobject]@{
            RepoRoot      = $repoRoot
            IconEditorRoot = $iconRoot
        }
    }

    It 'enables dev mode via wrapper script' {
        $stub = Initialize-DevModeStubRepo -Name 'enable-script'

        $result = & $script:enableScript `
            -RepoRoot $stub.RepoRoot `
            -IconEditorRoot $stub.IconEditorRoot `
            -Versions 2026 `
            -Bitness 64

        $result.Active | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $stub.IconEditorRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-64'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
    }

    It 'disables dev mode via wrapper script after enabling' {
        $stub = Initialize-DevModeStubRepo -Name 'disable-script'

        & $script:enableScript `
            -RepoRoot $stub.RepoRoot `
            -IconEditorRoot $stub.IconEditorRoot `
            -Versions 2026 `
            -Bitness 64 | Out-Null

        $result = & $script:disableScript `
            -RepoRoot $stub.RepoRoot `
            -IconEditorRoot $stub.IconEditorRoot `
            -Versions 2026 `
            -Bitness 64

        $result.Active | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $stub.IconEditorRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:off-64'
    }

    It 'uses policy defaults when invoking enable wrapper with operation' {
        $stub = Initialize-DevModeStubRepo -Name 'enable-policy'

        $policyDir = Join-Path $stub.RepoRoot 'configs' 'icon-editor'
        New-Item -ItemType Directory -Path $policyDir -Force | Out-Null
        $policyPath = Join-Path $policyDir 'dev-mode-targets.json'
@'
{
  "schema": "icon-editor/dev-mode-targets@v1",
  "operations": {
    "Compare": {
      "versions": [2025],
      "bitness": [64]
    }
  }
}
'@ | Set-Content -LiteralPath $policyPath -Encoding utf8
        $env:ICON_EDITOR_DEV_MODE_POLICY_PATH = $policyPath

        $state = & $script:enableScript `
            -RepoRoot $stub.RepoRoot `
            -IconEditorRoot $stub.IconEditorRoot `
            -Operation 'Compare'

        $state.Active | Should -BeTrue
        $state.Source | Should -Be 'Enable-IconEditorDevelopmentMode:Compare'
        (Get-Content -LiteralPath (Join-Path $stub.IconEditorRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-64'

        $disableState = & $script:disableScript `
            -RepoRoot $stub.RepoRoot `
            -IconEditorRoot $stub.IconEditorRoot `
            -Operation 'Compare'
        $disableState.Active | Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $stub.IconEditorRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:off-64'
    }

    It 'throws when enable wrapper is missing helper scripts' {
        $stub = Initialize-DevModeStubRepo -Name 'enable-missing'
        Remove-Item -LiteralPath (Join-Path $stub.IconEditorRoot '.github/actions/add-token-to-labview/AddTokenToLabVIEW.ps1') -Force

        $threw = $false
        $exception = $null
        try {
            & $script:enableScript `
                -RepoRoot $stub.RepoRoot `
                -IconEditorRoot $stub.IconEditorRoot `
                -Versions 2026 `
                -Bitness 64
        } catch {
            $threw = $true
            $exception = $_.Exception
        }
        $threw | Should -BeTrue
        $exception.Message | Should -Match 'Icon editor dev-mode helper'
    }

    It 'throws when disable wrapper is missing helper scripts' {
        $stub = Initialize-DevModeStubRepo -Name 'disable-missing'
        Remove-Item -LiteralPath (Join-Path $stub.IconEditorRoot '.github/actions/restore-setup-lv-source/RestoreSetupLVSource.ps1') -Force

        $threw = $false
        $exception = $null
        try {
            & $script:disableScript `
                -RepoRoot $stub.RepoRoot `
                -IconEditorRoot $stub.IconEditorRoot `
                -Versions 2026 `
                -Bitness 64
        } catch {
            $threw = $true
            $exception = $_.Exception
        }
        $threw | Should -BeTrue
        $exception.Message | Should -Match 'Icon editor dev-mode helper'
    }

    It 'throws when reset helper script is missing' {
        $stub = Initialize-DevModeStubRepo -Name 'disable-reset-missing'
        Remove-Item -LiteralPath (Join-Path $stub.RepoRoot 'tools/icon-editor/Reset-IconEditorWorkspace.ps1') -Force

        { & $script:disableScript -RepoRoot $stub.RepoRoot -IconEditorRoot $stub.IconEditorRoot -Versions 2026 -Bitness 64 } | Should -Throw '*Icon editor dev-mode helper*'
    }
}
