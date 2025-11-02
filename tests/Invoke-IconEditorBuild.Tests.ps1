#Requires -Version 7.0

Describe 'Invoke-IconEditorBuild.ps1' -Tag 'IconEditor','Build','Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Invoke-IconEditorBuild.ps1'

    Import-Module (Join-Path $script:repoRoot 'tools' 'VendorTools.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'tools' 'icon-editor' 'IconEditorDevMode.psm1') -Force
  }

  AfterAll {
    Remove-Module IconEditorDevMode -Force -ErrorAction SilentlyContinue
    Remove-Module VendorTools -Force -ErrorAction SilentlyContinue
  }

  BeforeEach {
    $workRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
    $script:iconRoot = Join-Path $workRoot 'icon'
    $script:resultsRoot = Join-Path $workRoot 'results'

    $null = New-Item -ItemType Directory -Path $script:iconRoot -Force
    $null = New-Item -ItemType Directory -Path $script:resultsRoot -Force

    $actionsRoot = Join-Path (Join-Path $script:iconRoot '.github') 'actions'

    $null = New-Item -ItemType Directory -Path (Join-Path $script:iconRoot 'resource\plugins') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $script:iconRoot 'Tooling\deployment') -Force
    $null = New-Item -ItemType File -Path (Join-Path $script:iconRoot 'Tooling\deployment\NI Icon editor.vipb') -Force

    function New-StubScript {
      param([string]$RelativePath, [string]$Content)
      $scriptPath = Join-Path $actionsRoot $RelativePath
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force
      Set-Content -LiteralPath $scriptPath -Value $Content -Encoding utf8
    }

    New-StubScript 'build-lvlibp/Build_lvlibp.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [int]$Major,
  [int]$Minor,
  [int]$Patch,
  [int]$Build,
  [string]$Commit
)
$target = Join-Path $RelativePath 'resource\plugins\lv_icon.lvlibp'
New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
"build-$SupportedBitness-$Major.$Minor.$Patch.$Build" | Set-Content -LiteralPath $target -Encoding utf8
'@

    New-StubScript 'close-labview/Close_LabVIEW.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness
)
"closed:$MinimumSupportedLVVersion-$SupportedBitness" | Out-Null
'@

    New-StubScript 'rename-file/Rename-file.ps1' @'
param(
  [string]$CurrentFilename,
  [string]$NewFilename
)
Rename-Item -LiteralPath $CurrentFilename -NewName $NewFilename -Force
'@

    New-StubScript 'add-token-to-labview/AddTokenToLabVIEW.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath
)
"token:$MinimumSupportedLVVersion-$SupportedBitness" | Out-Null
'@

    New-StubScript 'prepare-labview-source/Prepare_LabVIEW_source.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [string]$LabVIEW_Project,
  [string]$Build_Spec
)
$prepFlag = Join-Path $RelativePath 'Tooling\deployment\prepare-flag.txt'
"prepared:$MinimumSupportedLVVersion-$SupportedBitness" | Set-Content -LiteralPath $prepFlag -Encoding utf8
'@

    New-StubScript 'modify-vipb-display-info/ModifyVIPBDisplayInfo.ps1' @'
param(
  [string]$SupportedBitness,
  [string]$RelativePath,
  [string]$VIPBPath,
  [int]$MinimumSupportedLVVersion,
  [string]$LabVIEWMinorRevision,
  [int]$Major,
  [int]$Minor,
  [int]$Patch,
  [int]$Build,
  [string]$Commit,
  [string]$ReleaseNotesFile,
  [string]$DisplayInformationJSON
)
$infoPath = Join-Path $RelativePath 'Tooling\deployment\display-info.json'
Set-Content -LiteralPath $infoPath -Value $DisplayInformationJSON -Encoding utf8
if (-not (Test-Path -LiteralPath $ReleaseNotesFile -PathType Leaf)) {
  New-Item -ItemType File -Path $ReleaseNotesFile -Force | Out-Null
}
'@

    New-StubScript 'restore-setup-lv-source/RestoreSetupLVSource.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$RelativePath,
  [string]$LabVIEW_Project,
  [string]$Build_Spec
)
"restore:$MinimumSupportedLVVersion-$SupportedBitness" | Out-Null
'@

    New-StubScript 'build-vi-package/build_vip.ps1' @'
param(
  [string]$SupportedBitness,
  [int]$MinimumSupportedLVVersion,
  [string]$LabVIEWMinorRevision,
  [int]$Major,
  [int]$Minor,
  [int]$Patch,
  [int]$Build,
  [string]$Commit,
  [string]$ReleaseNotesFile,
  [string]$DisplayInformationJSON
)
$iconRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$vipOut = Join-Path $iconRoot 'Tooling\deployment\IconEditor_Test.vip'
"vip-$SupportedBitness" | Set-Content -LiteralPath $vipOut -Encoding utf8
'@

    $global:IconBuildDevModeState = [pscustomobject]@{
      Active    = $false
      UpdatedAt = (Get-Date).ToString('o')
      Source    = 'initial'
    }

    $global:IconBuildRecorded = New-Object System.Collections.Generic.List[object]

    Mock Resolve-GCliPath { 'C:\Program Files\G-CLI\bin\g-cli.exe' }

    Mock Find-LabVIEWVersionExePath {
      param([int]$Version, [int]$Bitness)
      "C:\Program Files\National Instruments\LabVIEW $Version\LabVIEW.exe"
    }

    Mock Enable-IconEditorDevelopmentMode {
      $global:IconBuildDevModeState = [pscustomobject]@{
        Active    = $true
        UpdatedAt = (Get-Date).ToString('o')
        Source    = 'enable'
      }
      $global:IconBuildRecorded.Add([pscustomobject]@{ Script = 'EnableDevMode'; Arguments = @() }) | Out-Null
      return $global:IconBuildDevModeState
    }

    Mock Disable-IconEditorDevelopmentMode {
      $global:IconBuildDevModeState = [pscustomobject]@{
        Active    = $false
        UpdatedAt = (Get-Date).ToString('o')
        Source    = 'disable'
      }
      $global:IconBuildRecorded.Add([pscustomobject]@{ Script = 'DisableDevMode'; Arguments = @() }) | Out-Null
      return $global:IconBuildDevModeState
    }

    Mock Get-IconEditorDevModeState {
      return [pscustomobject]@{
        Active    = $global:IconBuildDevModeState.Active
        UpdatedAt = $global:IconBuildDevModeState.UpdatedAt
        Source    = $global:IconBuildDevModeState.Source
      }
    }

    Mock Invoke-IconEditorDevModeScript {
      param(
        [string]$ScriptPath,
        [string[]]$ArgumentList,
        [string]$RepoRoot,
        [string]$IconEditorRoot
      )

      $scriptName = Split-Path -Leaf $ScriptPath
      $global:IconBuildRecorded.Add([pscustomobject]@{
        Script    = $scriptName
        Arguments = $ArgumentList
      }) | Out-Null

      $argsMap = @{}
      if ($ArgumentList) {
        for ($i = 0; $i -lt $ArgumentList.Count; $i += 2) {
          $key = $ArgumentList[$i].TrimStart('-')
          $value = $null
          if ($i + 1 -lt $ArgumentList.Count) {
            $value = $ArgumentList[$i + 1]
          }
          $argsMap[$key] = $value
        }
      }

      switch ($scriptName) {
        'Build_lvlibp.ps1' {
          $relativePath = $argsMap['RelativePath']
          if ($relativePath) {
            $target = Join-Path $relativePath 'resource\plugins\lv_icon.lvlibp'
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            "build-$($argsMap['SupportedBitness'])" | Set-Content -LiteralPath $target -Encoding utf8
          }
        }
        'Rename-file.ps1' {
          if ($argsMap['CurrentFilename']) {
            Rename-Item -LiteralPath $argsMap['CurrentFilename'] -NewName $argsMap['NewFilename'] -Force
          }
        }
        'ModifyVIPBDisplayInfo.ps1' {
          $relativePath = $argsMap['RelativePath']
          if ($relativePath) {
            $infoPath = Join-Path $relativePath 'Tooling\deployment\display-info.json'
            $argsMap['DisplayInformationJSON'] | Set-Content -LiteralPath $infoPath -Encoding utf8
          }
          if ($argsMap['ReleaseNotesFile'] -and -not (Test-Path -LiteralPath $argsMap['ReleaseNotesFile'] -PathType Leaf)) {
            New-Item -ItemType File -Path $argsMap['ReleaseNotesFile'] -Force | Out-Null
          }
        }
        'build_vip.ps1' {
          $iconRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptPath)))
          $vipOut = Join-Path $iconRoot 'Tooling\deployment\IconEditor_Test.vip'
          if (Test-Path -LiteralPath $vipOut) {
            Remove-Item -LiteralPath $vipOut -Force
          }

          $tempRoot = Join-Path $iconRoot 'Tooling\deployment\_vip_temp'
          if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
          }

          $null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'resource\plugins') -Force
          $null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'support') -Force

          'dummy' | Set-Content -LiteralPath (Join-Path $tempRoot 'resource\plugins\lv_icon_x86.lvlibp') -Encoding utf8
          'dummy' | Set-Content -LiteralPath (Join-Path $tempRoot 'resource\plugins\lv_icon_x64.lvlibp') -Encoding utf8

          $major = $argsMap['Major']
          $minor = $argsMap['Minor']
          $patch = $argsMap['Patch']
          $build = $argsMap['Build']
          $versionString = '{0}.{1}.{2}.{3}' -f $major, $minor, $patch, $build
          $versionString | Set-Content -LiteralPath (Join-Path $tempRoot 'support\build.txt') -Encoding utf8

          Compress-Archive -Path (Join-Path $tempRoot '*') -DestinationPath $vipOut -Force
          Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
        default { }
      }
    }
  }

  AfterEach {
    Remove-Variable -Name IconBuildRecorded -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name IconBuildDevModeState -Scope Global -ErrorAction SilentlyContinue
  }

  It 'runs full build and packaging flow' {
    { & $script:scriptPath `
        -IconEditorRoot $script:iconRoot `
        -ResultsRoot $script:resultsRoot `
        -Major 1 -Minor 2 -Patch 3 -Build 4 -Commit 'abc123'
    } | Should -Not -Throw

    $calledScripts = $global:IconBuildRecorded | Where-Object { $_.Script -like '*.ps1' } | Select-Object -ExpandProperty Script
    $calledScripts | Should -Contain 'Build_lvlibp.ps1'
    ($calledScripts | Where-Object { $_ -eq 'Build_lvlibp.ps1' }).Count | Should -Be 2
    ($calledScripts | Where-Object { $_ -eq 'Close_LabVIEW.ps1' }).Count | Should -Be 3
    $calledScripts | Should -Contain 'ModifyVIPBDisplayInfo.ps1'
    $calledScripts | Should -Contain 'build_vip.ps1'

    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'lv_icon_x86.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'lv_icon_x64.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'IconEditor_Test.vip') | Should -BeTrue

    $manifestPath = Join-Path $script:resultsRoot 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.packagingRequested | Should -BeTrue
    $manifest.dependenciesApplied | Should -BeTrue
    $manifest.developmentMode.toggled | Should -BeTrue
    @($manifest.artifacts | Where-Object { $_.kind -eq 'vip' }).Count | Should -BeGreaterThan 0
    $manifest.packageSmoke.status | Should -Be 'ok'
    $manifest.packageSmoke.vipCount | Should -Be 1
  }

  It 'skips packaging when requested' {
    { & $script:scriptPath `
        -IconEditorRoot $script:iconRoot `
        -ResultsRoot $script:resultsRoot `
        -SkipPackaging `
        -Commit 'skiptest'
    } | Should -Not -Throw

    $calledScripts = $global:IconBuildRecorded | Where-Object { $_.Script -like '*.ps1' } | Select-Object -ExpandProperty Script
    $calledScripts | Should -Not -Contain 'ModifyVIPBDisplayInfo.ps1'
    $calledScripts | Should -Not -Contain 'build_vip.ps1'

    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'IconEditor_Test.vip') | Should -BeFalse

    $manifest = Get-Content -LiteralPath (Join-Path $script:resultsRoot 'manifest.json') -Raw | ConvertFrom-Json
    $manifest.packagingRequested | Should -BeFalse
    @($manifest.artifacts | Where-Object { $_.kind -eq 'vip' }).Count | Should -Be 0
    $manifest.packageSmoke.status | Should -Be 'skipped'
  }
}
