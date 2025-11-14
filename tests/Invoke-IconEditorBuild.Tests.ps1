#Requires -Version 7.0

Describe 'Invoke-IconEditorBuild.ps1' -Tag 'IconEditor','Build','Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Invoke-IconEditorBuild.ps1'

    Import-Module (Join-Path $script:repoRoot 'tools' 'VendorTools.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'tools' 'icon-editor' 'IconEditorDevMode.psm1') -Force
    Import-Module (Join-Path $script:repoRoot 'tools' 'icon-editor' 'IconEditorPackage.psm1') -Force
  }

  AfterAll {
    Remove-Module IconEditorDevMode -Force -ErrorAction SilentlyContinue
    Remove-Module VendorTools -Force -ErrorAction SilentlyContinue
    Remove-Module IconEditorPackage -Force -ErrorAction SilentlyContinue
    Remove-Module PackedLibraryBuild -Force -ErrorAction SilentlyContinue
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
    $null = New-Item -ItemType File -Path (Join-Path $script:iconRoot 'lv_icon_editor.lvproj') -Force

    function New-StubScript {
      param([string]$ActionRelativePath, [string]$Content)
      $scriptPath = Join-Path $actionsRoot $ActionRelativePath
      $null = New-Item -ItemType Directory -Path (Split-Path -Parent $scriptPath) -Force
      Set-Content -LiteralPath $scriptPath -Value $Content -Encoding utf8
    }

    New-StubScript 'build-lvlibp/Build_lvlibp.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [int]$Major,
  [int]$Minor,
  [int]$Patch,
  [int]$Build,
  [string]$Commit
)
$target = Join-Path $IconEditorRoot 'resource\plugins\lv_icon.lvlibp'
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
  [string]$IconEditorRoot
)
"token:$MinimumSupportedLVVersion-$SupportedBitness" | Out-Null
'@

    New-StubScript 'prepare-labview-source/Prepare_LabVIEW_source.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
  [string]$LabVIEW_Project,
  [string]$Build_Spec
)
$prepFlag = Join-Path $IconEditorRoot 'Tooling\deployment\prepare-flag.txt'
"prepared:$MinimumSupportedLVVersion-$SupportedBitness" | Set-Content -LiteralPath $prepFlag -Encoding utf8
'@

    $updateVipbPath = Join-Path $TestDrive 'Update-VipbDisplayInfo.ps1'
    $env:ICON_EDITOR_UPDATE_VIPB_HELPER = $updateVipbPath
    @'
param(
  [int]$MinimumSupportedLVVersion,
  [string]$LabVIEWMinorRevision,
  [string]$SupportedBitness,
  [int]$Major,
  [int]$Minor,
  [int]$Patch,
  [int]$Build,
  [string]$Commit,
  [string]$IconEditorRoot,
  [string]$VIPBPath,
  [string]$ReleaseNotesFile,
  [string]$DisplayInformationJSON
)
$infoPath = Join-Path $IconEditorRoot 'Tooling\deployment\display-info.json'
Set-Content -LiteralPath $infoPath -Value $DisplayInformationJSON -Encoding utf8
if (-not (Test-Path -LiteralPath $ReleaseNotesFile -PathType Leaf)) {
  New-Item -ItemType File -Path $ReleaseNotesFile -Force | Out-Null
}
'@ | Set-Content -LiteralPath $updateVipbPath -Encoding utf8

    $unitReadyHelper = Join-Path $TestDrive 'UnitTestReady.ps1'
    $env:ICON_EDITOR_UNIT_READY_HELPER = $unitReadyHelper
    @'
param([switch]$Validate)
"unit-ready" | Out-File (Join-Path $env:TEMP 'unit-ready.log')
'@ | Set-Content -LiteralPath $unitReadyHelper -Encoding utf8

    New-StubScript 'restore-setup-lv-source/RestoreSetupLVSource.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$IconEditorRoot,
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
  [string]$BuildToolchain,
  [string]$BuildProvider,
  [string]$DisplayInformationJSON
)
$iconRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$vipOut = Join-Path $iconRoot 'Tooling\deployment\IconEditor_Test.vip'
"vip-$SupportedBitness" | Set-Content -LiteralPath $vipOut -Encoding utf8
'@

    New-StubScript 'missing-in-project/Invoke-MissingInProjectCLI.ps1' @'
param(
  [string]$LVVersion,
  [string]$Arch,
  [string]$ProjectFile
)
'@

    New-StubScript 'run-unit-tests/RunUnitTests.ps1' @'
param(
  [string]$MinimumSupportedLVVersion,
  [string]$SupportedBitness,
  [string]$ProjectPath
)
$reportPath = Join-Path $PSScriptRoot 'UnitTestReport.xml'
"<Report lv='$MinimumSupportedLVVersion' arch='$SupportedBitness' />" | Set-Content -LiteralPath $reportPath -Encoding utf8
'@

    $global:IconBuildDevModeState = [pscustomobject]@{
      Active    = $false
      UpdatedAt = (Get-Date).ToString('o')
      Source    = 'initial'
    }

    $global:IconBuildRecorded = New-Object System.Collections.Generic.List[object]

    Mock Resolve-GCliPath { 'C:\Program Files\G-CLI\bin\g-cli.exe' }

    Mock -CommandName Get-IconEditorViServerSnapshot -ModuleName IconEditorPackage -MockWith {
      param([int]$Version, [int]$Bitness, [string]$WorkspaceRoot)
      [pscustomobject]@{
        Version = $Version
        Bitness = $Bitness
        Status  = 'ok'
        ExePath = 'C:\LabVIEW.exe'
        IniPath = 'C:\LabVIEW.ini'
        Enabled = 'TRUE'
        Port    = 3368
      }
    }

    Mock Find-LabVIEWVersionExePath {
      param([int]$Version, [int]$Bitness)
      "C:\Program Files\National Instruments\LabVIEW $Version\LabVIEW.exe"
    }

    Mock Enable-IconEditorDevelopmentMode {
      param(
        [int[]]$Versions,
        [int[]]$Bitness,
        [string]$RepoRoot,
        [string]$IconEditorRoot,
        [string]$Operation
      )
      if (-not $Versions) { $Versions = @(2023) }
      if (-not $Bitness) { $Bitness = @(32,64) }
      if (-not $Operation) { $Operation = 'BuildPackage' }
      $global:IconBuildDevModeState = [pscustomobject]@{
        Active    = $true
        UpdatedAt = (Get-Date).ToString('o')
        Source    = 'enable'
      }
      $global:IconBuildRecorded.Add([pscustomobject]@{
        Script    = 'EnableDevMode'
        Arguments = [ordered]@{
          Versions = $Versions
          Bitness  = $Bitness
          Operation = $Operation
        }
      }) | Out-Null
      return $global:IconBuildDevModeState
    }

    Mock Disable-IconEditorDevelopmentMode {
      param(
        [int[]]$Versions,
        [int[]]$Bitness,
        [string]$RepoRoot,
        [string]$IconEditorRoot,
        [string]$Operation
      )
      if (-not $Versions) { $Versions = @(2023) }
      if (-not $Bitness) { $Bitness = @(32,64) }
      if (-not $Operation) { $Operation = 'BuildPackage' }
      $global:IconBuildDevModeState = [pscustomobject]@{
        Active    = $false
        UpdatedAt = (Get-Date).ToString('o')
        Source    = 'disable'
      }
      $global:IconBuildRecorded.Add([pscustomobject]@{
        Script    = 'DisableDevMode'
        Arguments = [ordered]@{
          Versions = $Versions
          Bitness  = $Bitness
          Operation = $Operation
        }
      }) | Out-Null
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
          $IconEditorRoot = $argsMap['IconEditorRoot']
          if ($IconEditorRoot) {
            $target = Join-Path $IconEditorRoot 'resource\plugins\lv_icon.lvlibp'
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            "build-$($argsMap['SupportedBitness'])" | Set-Content -LiteralPath $target -Encoding utf8
          }
        }
        'Rename-file.ps1' {
          if ($argsMap['CurrentFilename']) {
            Rename-Item -LiteralPath $argsMap['CurrentFilename'] -NewName $argsMap['NewFilename'] -Force
          }
        }
        'Update-VipbDisplayInfo.ps1' {
          $IconEditorRoot = $argsMap['IconEditorRoot']
          if ($IconEditorRoot) {
            $infoPath = Join-Path $IconEditorRoot 'Tooling\deployment\display-info.json'
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
        'Invoke-MissingInProjectCLI.ps1' {
          $resultsDir = Join-Path $RepoRoot 'tests\results\_agent\missing-in-project'
          New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
          $payload = [ordered]@{
            schema       = 'test/missing-in-project'
            generatedAt  = (Get-Date).ToString('o')
            lvVersion    = $argsMap['LVVersion']
            arch         = $argsMap['Arch']
            missingFiles = @()
            passed       = $true
          }
          $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $resultsDir 'last-run.json') -Encoding utf8
        }
        default { }
      }
    }
  }

  AfterEach {
    Remove-Variable -Name IconBuildRecorded -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name IconBuildDevModeState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item Env:ICON_EDITOR_UPDATE_VIPB_HELPER -ErrorAction SilentlyContinue
    Remove-Item Env:ICON_EDITOR_UNIT_READY_HELPER -ErrorAction SilentlyContinue
    $missingTelemetry = Join-Path $script:repoRoot 'tests\results\_agent\missing-in-project\last-run.json'
    if (Test-Path -LiteralPath $missingTelemetry -PathType Leaf) {
      Remove-Item -LiteralPath $missingTelemetry -Force -ErrorAction SilentlyContinue
    }
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
    $calledScripts | Should -Contain 'Update-VipbDisplayInfo.ps1'
    $calledScripts | Should -Contain 'build_vip.ps1'

    $enableCalls = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'EnableDevMode' }
    $enableCalls | Should -Not -BeNullOrEmpty
    $enableCalls.Count | Should -Be 2
    $enableCalls[0].Arguments.Operation | Should -Be 'BuildPackage'
    ($enableCalls[0].Arguments.Versions -join ',') | Should -Be '2023'
    ($enableCalls[0].Arguments.Bitness -join ',')  | Should -Be '32,64'
    $enableCalls[1].Arguments.Operation | Should -Be 'BuildPackage'
    ($enableCalls[1].Arguments.Versions -join ',') | Should -Be '2026'
    ($enableCalls[1].Arguments.Bitness -join ',')  | Should -Be '64'

    $disableCalls = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'DisableDevMode' }
    $disableCalls | Should -Not -BeNullOrEmpty
    $disableCalls.Count | Should -Be 2
    $disableCalls[0].Arguments.Operation | Should -Be 'BuildPackage'
    ($disableCalls[0].Arguments.Versions -join ',') | Should -Be '2023'
    ($disableCalls[0].Arguments.Bitness -join ',')  | Should -Be '32,64'
    $disableCalls[1].Arguments.Operation | Should -Be 'BuildPackage'
    ($disableCalls[1].Arguments.Versions -join ',') | Should -Be '2026'
    ($disableCalls[1].Arguments.Bitness -join ',')  | Should -Be '64'

    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'lv_icon_x86.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'lv_icon_x64.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'IconEditor_Test.vip') | Should -BeTrue

    $manifestPath = Join-Path $script:resultsRoot 'manifest.json'
    Test-Path -LiteralPath $manifestPath | Should -BeTrue

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.packagingRequested | Should -BeTrue
    $manifest.dependenciesApplied | Should -BeTrue
    $manifest.developmentMode.toggled | Should -BeTrue
    $manifest.packaging.requestedToolchain | Should -Be 'gcli'
    $manifest.packaging.packedLibVersion   | Should -Be 2023
    $manifest.packaging.packagingLabviewVersion | Should -Be 2026
    [string]::IsNullOrEmpty($manifest.packaging.requestedProvider) | Should -BeTrue
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
    $calledScripts | Should -Not -Contain 'Update-VipbDisplayInfo.ps1'
    $calledScripts | Should -Not -Contain 'build_vip.ps1'

    Test-Path -LiteralPath (Join-Path $script:resultsRoot 'IconEditor_Test.vip') | Should -BeFalse

    $enableCalls = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'EnableDevMode' }
    $enableCalls.Count | Should -Be 2
    ($enableCalls[0].Arguments.Versions -join ',') | Should -Be '2023'
    ($enableCalls[0].Arguments.Bitness -join ',')  | Should -Be '32,64'
    ($enableCalls[1].Arguments.Versions -join ',') | Should -Be '2026'
    ($enableCalls[1].Arguments.Bitness -join ',')  | Should -Be '64'

    $disableCalls = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'DisableDevMode' }
    $disableCalls.Count | Should -Be 2
    ($disableCalls[0].Arguments.Versions -join ',') | Should -Be '2023'
    ($disableCalls[0].Arguments.Bitness -join ',')  | Should -Be '32,64'
    ($disableCalls[1].Arguments.Versions -join ',') | Should -Be '2026'
    ($disableCalls[1].Arguments.Bitness -join ',')  | Should -Be '64'

    $manifest = Get-Content -LiteralPath (Join-Path $script:resultsRoot 'manifest.json') -Raw | ConvertFrom-Json
    $manifest.packagingRequested | Should -BeFalse
    $manifest.packaging.requestedToolchain | Should -Be 'gcli'
    @($manifest.artifacts | Where-Object { $_.kind -eq 'vip' }).Count | Should -Be 0
    $manifest.packageSmoke.status | Should -Be 'skipped'
  }

  It 'forwards toolchain overrides to the build script and manifest' {
    { & $script:scriptPath `
        -IconEditorRoot $script:iconRoot `
        -ResultsRoot $script:resultsRoot `
        -BuildToolchain 'vipm' `
        -BuildProvider 'vipm-custom' `
        -Commit 'vipmtest'
    } | Should -Not -Throw

    $buildCall = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'build_vip.ps1' } | Select-Object -Last 1
    $buildCall | Should -Not -BeNullOrEmpty

    $argMap = @{}
    for ($i = 0; $i -lt $buildCall.Arguments.Count; $i += 2) {
      $key = $buildCall.Arguments[$i].TrimStart('-')
      $value = if ($i + 1 -lt $buildCall.Arguments.Count) { $buildCall.Arguments[$i + 1] } else { $null }
      $argMap[$key] = $value
    }

    $argMap['BuildToolchain'] | Should -Be 'vipm'
    $argMap['BuildProvider']  | Should -Be 'vipm-custom'
    $argMap['MinimumSupportedLVVersion'] | Should -Be '2026'
    $argMap['LabVIEWMinorRevision']      | Should -Be '0'

    $manifest = Get-Content -LiteralPath (Join-Path $script:resultsRoot 'manifest.json') -Raw | ConvertFrom-Json
    $manifest.packaging.requestedToolchain | Should -Be 'vipm'
    $manifest.packaging.requestedProvider  | Should -Be 'vipm-custom'
  }

  It 'runs missing-in-project checks before executing unit tests' {
    { & $script:scriptPath `
        -IconEditorRoot $script:iconRoot `
        -ResultsRoot $script:resultsRoot `
        -SkipPackaging `
        -RunUnitTests `
        -Commit 'unittest' } | Should -Not -Throw

    $missingCalls = $global:IconBuildRecorded | Where-Object { $_.Script -eq 'Invoke-MissingInProjectCLI.ps1' }
    $missingCalls.Count | Should -Be 2

    $arches = @()
    foreach ($call in $missingCalls) {
      $map = @{}
      for ($i = 0; $i -lt $call.Arguments.Count; $i += 2) {
        $key = $call.Arguments[$i].TrimStart('-')
        $value = if ($i + 1 -lt $call.Arguments.Count) { $call.Arguments[$i + 1] } else { $null }
        $map[$key] = $value
      }
      $map['LVVersion'] | Should -Be '2023'
      $arches += $map['Arch']
    }
    (($arches | Sort-Object -Unique) -join ',') | Should -Be '32,64'

    $telemetryPath = Join-Path $script:repoRoot 'tests\results\_agent\missing-in-project\last-run.json'
    Test-Path -LiteralPath $telemetryPath | Should -BeTrue

    $unitReport = Join-Path $script:resultsRoot 'UnitTestReport.xml'
    Test-Path -LiteralPath $unitReport | Should -BeTrue
  }
}
