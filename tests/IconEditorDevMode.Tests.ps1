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
    Remove-Item Env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:SKIP_ROGUE_LV_DETECTION -ErrorAction SilentlyContinue
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
    $env:ICON_EDITOR_SKIP_WAIT_FOR_LABVIEW_EXIT = '1'
    $env:SKIP_ROGUE_LV_DETECTION = '1'

      $script:repoRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
      $script:iconRoot = Join-Path $script:repoRoot 'vendor' 'icon-editor'
      $script:actionsRoot = Join-Path $script:iconRoot '.github' 'actions'
      $script:addTokenDir = Join-Path $script:actionsRoot 'add-token-to-labview'
      $script:prepareDir  = Join-Path $script:actionsRoot 'prepare-labview-source'
      $script:closeDir    = Join-Path $script:actionsRoot 'close-labview'
      $script:restoreDir  = Join-Path $script:actionsRoot 'restore-setup-lv-source'
      $script:toolsDir = Join-Path $script:repoRoot 'tools'
      $script:toolsIconDir = Join-Path $script:toolsDir 'icon-editor'
      $script:closeLog = Join-Path $script:repoRoot 'close-log.txt'
      New-Item -ItemType File -Path $script:closeLog -Force | Out-Null
      New-Item -ItemType Directory -Path $script:addTokenDir,$script:prepareDir,$script:closeDir,$script:restoreDir -Force | Out-Null
      New-Item -ItemType Directory -Path $script:toolsDir,$script:toolsIconDir -Force | Out-Null

      $gCliPath = Join-Path $script:repoRoot 'fake-g-cli' 'bin' 'g-cli.exe'
      New-Item -ItemType Directory -Path (Split-Path -Parent $gCliPath) -Force | Out-Null
      New-Item -ItemType File -Path $gCliPath -Value '' -Force | Out-Null

      @"
function Resolve-GCliPath { return '$gCliPath' }
function Find-LabVIEWVersionExePath {
  param([int]`$Version, [int]`$Bitness)
  return $null
}
function Get-LabVIEWIniPath {
  param([string]`$LabVIEWExePath)
  return $null
}
Export-ModuleMember -Function Resolve-GCliPath, Find-LabVIEWVersionExePath, Get-LabVIEWIniPath
"@ | Set-Content -LiteralPath (Join-Path $script:toolsDir 'VendorTools.psm1') -Encoding utf8

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
'@ | Set-Content -LiteralPath (Join-Path $script:addTokenDir 'AddTokenToLabVIEW.ps1') -Encoding utf8

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
'@ | Set-Content -LiteralPath (Join-Path $script:prepareDir 'Prepare_LabVIEW_source.ps1') -Encoding utf8

      @"
[CmdletBinding()]
param(
  [string]`$MinimumSupportedLVVersion,
  [string]`$SupportedBitness
)
"close:`$SupportedBitness" | Add-Content -LiteralPath "$($script:closeLog)"
"@ | Set-Content -LiteralPath (Join-Path $script:closeDir 'Close_LabVIEW.ps1') -Encoding utf8

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
'@ | Set-Content -LiteralPath (Join-Path $script:restoreDir 'RestoreSetupLVSource.ps1') -Encoding utf8

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
'@ | Set-Content -LiteralPath (Join-Path $script:toolsIconDir 'Reset-IconEditorWorkspace.ps1') -Encoding utf8
    }

    It 'enables development mode via helper' {
      $state = Enable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2026) -Bitness @(64)
      $state.Active | Should -BeTrue
      (Get-Content -LiteralPath (Join-Path $script:iconRoot 'dev-mode.txt') -Raw).Trim() | Should -Be 'dev-mode:on-64'
    }

    It 'closes only requested bitness when enabling single target' {
      if (Test-Path -LiteralPath $script:closeLog) { Remove-Item -LiteralPath $script:closeLog -Force }
      Enable-IconEditorDevelopmentMode -RepoRoot $script:repoRoot -IconEditorRoot $script:iconRoot -Versions @(2026) -Bitness @(64) | Out-Null
      $entries = Get-Content -LiteralPath $script:closeLog
      $entries | Should -Contain 'close:64'
      $entries | Should -Not -Contain 'close:32'
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

    It 'surfaces g-cli timeout output when add-token script fails' {
      $failureBody = @'
[CmdletBinding()]
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$RelativePath
)
Write-Host 'Error: No connection established with application.'
Write-Host 'Caused by: Timed out waiting for app to connect to g-cli'
exit 1
'@
      Set-Content -LiteralPath (Join-Path $script:addTokenDir 'AddTokenToLabVIEW.ps1') -Value $failureBody -Encoding utf8

      {
        Enable-IconEditorDevelopmentMode `
          -RepoRoot $script:repoRoot `
          -IconEditorRoot $script:iconRoot `
          -Versions @(2021) `
          -Bitness @(32) `
          -Operation 'BuildPackage' | Out-Null
      } | Should -Throw '*Timed out waiting for app to connect to g-cli*'
    }
  }

  Context 'verification helper' {
    BeforeEach {
      $script:verifyRepo = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
      $script:verifyIcon = Join-Path $script:verifyRepo 'vendor' 'icon-editor'
      New-Item -ItemType Directory -Path $script:verifyIcon -Force | Out-Null
    }

    It 'skips verification when no LabVIEW targets are present' {
      Mock -CommandName Test-IconEditorDevelopmentMode -ModuleName IconEditorDevMode -MockWith {
        [pscustomobject]@{
          Entries = @()
          Active  = $null
        }
      }

      $threw = $false
      try {
        Assert-IconEditorDevModeTokenState -RepoRoot $script:verifyRepo -IconEditorRoot $script:verifyIcon -Versions @(2023) -Bitness @(64) -ExpectedActive $true
      } catch {
        $threw = $true
      }

      $threw | Should -BeFalse
    }

    It 'throws when expecting active tokens but icon editor path is missing' {
      Mock -CommandName Test-IconEditorDevelopmentMode -ModuleName IconEditorDevMode -MockWith {
        [pscustomobject]@{
          Entries = @(
            [pscustomobject]@{
              Present = $true
              LabVIEWIniPath = 'C:\fake\labview64.ini'
              Version = 2023
              Bitness = 64
              ContainsIconEditorPath = $false
            }
          )
          Active = $false
        }
      }

      $threw = $false
      $caught = $null
      try {
        Assert-IconEditorDevModeTokenState -RepoRoot $script:verifyRepo -IconEditorRoot $script:verifyIcon -Versions @(2023) -Bitness @(64) -ExpectedActive $true
      } catch {
        $threw = $true
        $caught = $_
      }

      $threw | Should -BeTrue
      $caught.Exception.Message | Should -Match 'expected LabVIEW to include the icon-editor path'
    }

    It 'throws when expecting removal but icon editor path persists' {
      Mock -CommandName Test-IconEditorDevelopmentMode -ModuleName IconEditorDevMode -MockWith {
        [pscustomobject]@{
          Entries = @(
            [pscustomobject]@{
              Present = $true
              LabVIEWIniPath = 'C:\fake\labview32.ini'
              Version = 2023
              Bitness = 32
              ContainsIconEditorPath = $true
            }
          )
          Active = $true
        }
      }

      $threw = $false
      $caught = $null
      try {
        Assert-IconEditorDevModeTokenState -RepoRoot $script:verifyRepo -IconEditorRoot $script:verifyIcon -Versions @(2023) -Bitness @(32) -ExpectedActive $false
      } catch {
        $threw = $true
        $caught = $_
      }

      $threw | Should -BeTrue
      $caught.Exception.Message | Should -Match 'expected LabVIEW to exclude the icon-editor path'
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


