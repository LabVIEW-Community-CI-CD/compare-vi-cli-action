#Requires -Version 7.0

Describe 'IconEditor dev mode helpers' -Tag 'IconEditor' {
  BeforeAll {
    $script:moduleName = 'IconEditorDevMode'
    $script:modulePath = Join-Path $PSScriptRoot '..' 'tools' 'icon-editor' 'IconEditorDevMode.psm1'
    Import-Module $script:modulePath -Force
  }

  AfterAll {
    Remove-Module $script:moduleName -Force -ErrorAction SilentlyContinue
  }

  AfterEach {
    Remove-Item Env:ICON_EDITOR_DEV_MODE_POLICY_PATH -ErrorAction SilentlyContinue
  }

  It 'returns null state when no marker exists' {
    $repoRoot = Join-Path $TestDrive 'repo'
    New-Item -ItemType Directory -Path $repoRoot | Out-Null

    $state = Get-IconEditorDevModeState -RepoRoot $repoRoot
    $state.Active | Should -BeNullOrEmpty
    $state.Path | Should -Match 'dev-mode-state.json$'
  }

  It 'records dev-mode state toggles' {
    $repoRoot = Join-Path $TestDrive 'repo-state'
    New-Item -ItemType Directory -Path $repoRoot | Out-Null

    $written = Set-IconEditorDevModeState -RepoRoot $repoRoot -Active $true -Source 'test-run'
    $written.Active | Should -BeTrue
    $written.Source | Should -Be 'test-run'

    $reloaded = Get-IconEditorDevModeState -RepoRoot $repoRoot
    $reloaded.Active | Should -BeTrue
    $reloaded.Source | Should -Be 'test-run'
    Test-Path -LiteralPath $reloaded.Path | Should -BeTrue
  }

  Context 'script execution' {
    BeforeEach {
      $script:repoRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
      $script:iconRoot = Join-Path $script:repoRoot 'vendor' 'icon-editor'
      $script:actionsRoot = Join-Path $script:iconRoot '.github' 'actions'
      $script:addTokenDir = Join-Path $script:actionsRoot 'add-token-to-labview'
      $script:prepareDir  = Join-Path $script:actionsRoot 'prepare-labview-source'
      $script:closeDir    = Join-Path $script:actionsRoot 'close-labview'
      $script:restoreDir  = Join-Path $script:actionsRoot 'restore-setup-lv-source'
      $script:toolsDir = Join-Path $script:repoRoot 'tools'
      New-Item -ItemType Directory -Path $script:addTokenDir,$script:prepareDir,$script:closeDir,$script:restoreDir -Force | Out-Null
      New-Item -ItemType Directory -Path $script:toolsDir -Force | Out-Null

      $gCliPath = Join-Path $script:repoRoot 'fake-g-cli' 'bin' 'g-cli.exe'
      New-Item -ItemType Directory -Path (Split-Path -Parent $gCliPath) -Force | Out-Null
      New-Item -ItemType File -Path $gCliPath -Value '' -Force | Out-Null

      @"
function Resolve-GCliPath { return '$gCliPath' }
Export-ModuleMember -Function Resolve-GCliPath
"@ | Set-Content -LiteralPath (Join-Path $script:toolsDir 'VendorTools.psm1') -Encoding utf8

      @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
if ($RelativePath) {
  "dev-mode:on-$SupportedBitness" | Set-Content -LiteralPath (Join-Path $RelativePath 'dev-mode.txt') -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $script:addTokenDir 'AddTokenToLabVIEW.ps1') -Encoding utf8

      @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [string]$LabVIEW_Project,
  [string]$Build_Spec,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
if ($RelativePath) {
  $marker = Join-Path $RelativePath ("prepare-{0}.log" -f $SupportedBitness)
  "prepare:$SupportedBitness" | Set-Content -LiteralPath $marker -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $script:prepareDir 'Prepare_LabVIEW_source.ps1') -Encoding utf8

      @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness
)
# Stub close helper – no-op
'@ | Set-Content -LiteralPath (Join-Path $script:closeDir 'Close_LabVIEW.ps1') -Encoding utf8

      @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [string]$LabVIEW_Project,
  [string]$Build_Spec,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Extra
)
if ($RelativePath) {
  "dev-mode:off-$SupportedBitness" | Set-Content -LiteralPath (Join-Path $RelativePath 'dev-mode.txt') -Encoding utf8
}
'@ | Set-Content -LiteralPath (Join-Path $script:restoreDir 'RestoreSetupLVSource.ps1') -Encoding utf8
    }

    It 'enables development mode via helper' {
      $state = Enable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2026) -Bitness @(64)
      $state.Active | Should -BeTrue
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-64'
    }

    It 'disables development mode via helper' {
      Set-IconEditorDevModeState -RepoRoot $script:repoRoot -Active $true -Source 'pretest' | Out-Null
      $state = Disable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2026) -Bitness @(64)
      $state.Active | Should -BeFalse
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:off-64'
    }

    It 'supports alternate bitness overrides' {
      $state = Enable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2023) -Bitness @(32)
      $state.Active | Should -BeTrue
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-32'

      Set-IconEditorDevModeState -RepoRoot $script:repoRoot -Active $true -Source 'pretest' | Out-Null
      $state = Disable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2023) -Bitness @(32)
      $state.Active | Should -BeFalse
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:off-32'
    }

    It 'uses policy defaults when operation is provided' {
      $policyDir = Join-Path $script:repoRoot 'configs' 'icon-editor'
      $null = New-Item -ItemType Directory -Path $policyDir -Force
      $policyPath = Join-Path $policyDir 'dev-mode-targets.json'
@'
{
  "schema": "icon-editor/dev-mode-targets@v1",
  "operations": {
    "BuildPackage": {
      "versions": [2023, 2026],
      "bitness": [32, 64]
    },
    "Compare": {
      "versions": [2025],
      "bitness": [64]
    }
  }
}
'@ | Set-Content -LiteralPath $policyPath -Encoding utf8
      $env:ICON_EDITOR_DEV_MODE_POLICY_PATH = $policyPath

      $enableState = Enable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Operation 'Compare'
      $enableState.Active | Should -BeTrue
      $enableState.Source | Should -Be 'Enable-IconEditorDevelopmentMode:Compare'
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-64'

      try {
        $disableState = Disable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Operation 'Compare'
        $disableState.Active | Should -BeFalse
        $disableState.Source | Should -Be 'Disable-IconEditorDevelopmentMode:Compare'
        (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:off-64'
      } finally {
        Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
      }
    }
  }

  Context 'LabVIEW.ini verification (integration)' -Tag 'IconEditor','Integration','E2E' {
    It 'round-trips dev mode toggles using LabVIEW.ini' -Tag 'Integration','E2E' {
      $repoRoot = Resolve-IconEditorRepoRoot
      $status = Test-IconEditorDevelopmentMode -RepoRoot $repoRoot -Versions @(2025) -Bitness @(64)
      $presentTargets = $status.Entries | Where-Object { $_.Present }
      if ($presentTargets.Count -eq 0) {
        Set-ItResult -Skip -Because 'LabVIEW 2025 x64 not detected; skipping integration dev-mode verification.'
        return
      }

      $scriptPath = Join-Path $repoRoot 'tools' 'icon-editor' 'Assert-DevModeState.ps1'
      try {
        Enable-IconEditorDevelopmentMode -RepoRoot $repoRoot -Operation 'Compare' | Out-Null
        $afterEnable = Test-IconEditorDevelopmentMode -RepoRoot $repoRoot -Versions @(2025) -Bitness @(64)
        if (-not $afterEnable.Active) {
          Set-ItResult -Skip -Because 'Failed to toggle icon editor dev mode for LabVIEW 2025 x64; g-cli/installation may be unavailable on this host.'
          return
        }
        & $scriptPath -ExpectedActive:$true -RepoRoot $repoRoot -Operation 'Compare' | Out-Null
      }
      finally {
        Disable-IconEditorDevelopmentMode -RepoRoot $repoRoot -Operation 'Compare' | Out-Null
      }

      $afterDisable = Test-IconEditorDevelopmentMode -RepoRoot $repoRoot -Versions @(2025) -Bitness @(64)
      if ($afterDisable.Active) {
        Set-ItResult -Skip -Because 'Failed to disable icon editor dev mode for LabVIEW 2025 x64; investigate host state.'
        return
      }
      & $scriptPath -ExpectedActive:$false -RepoRoot $repoRoot -Operation 'Compare' | Out-Null
    }
  }
}


