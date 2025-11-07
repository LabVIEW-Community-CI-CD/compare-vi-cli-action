#Requires -Version 7.0
#Requires -Modules Pester

Describe 'Invoke-LVPackedLibraryBuild' -Tag 'PackedLibrary','Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $script:repoRoot 'tools' 'vendor' 'PackedLibraryBuild.psm1') -Force
  }

  AfterAll {
    Remove-Module PackedLibraryBuild -Force -ErrorAction SilentlyContinue
  }

  It 'builds and renames packed libraries for each target' {
    $artifactDir = Join-Path $TestDrive 'artifacts'
    $null = New-Item -ItemType Directory -Path $artifactDir -Force
    'stale' | Set-Content -LiteralPath (Join-Path $artifactDir 'lv_icon_x86.lvlibp') -Encoding utf8
    'stale' | Set-Content -LiteralPath (Join-Path $artifactDir 'lv_icon_x64.lvlibp') -Encoding utf8

    $buildScript  = Join-Path $TestDrive 'build.ps1'
    $closeScript  = Join-Path $TestDrive 'close.ps1'
    $renameScript = Join-Path $TestDrive 'rename.ps1'

    '# build stub'  | Set-Content -LiteralPath $buildScript -Encoding ascii
    '# close stub'  | Set-Content -LiteralPath $closeScript -Encoding ascii
    '# rename stub' | Set-Content -LiteralPath $renameScript -Encoding ascii

    $callLog = New-Object System.Collections.Generic.List[object]
    $invokeAction = {
      param(
        [string]$ScriptPath,
        [string[]]$Arguments
      )

      $scriptName = Split-Path -Leaf $ScriptPath
      $callLog.Add([pscustomobject]@{
        Script = $scriptName
        Arguments = $Arguments
      }) | Out-Null

      $argsMap = @{}
      if ($Arguments) {
        for ($i = 0; $i -lt $Arguments.Count; $i += 2) {
          $argsMap[$Arguments[$i].TrimStart('-')] = $Arguments[$i + 1]
        }
      }

      switch ($scriptName) {
        'build.ps1' {
          $content = "build-$($argsMap['SupportedBitness'])"
          $content | Set-Content -LiteralPath (Join-Path $artifactDir 'lv_icon.lvlibp') -Encoding utf8
        }
        'rename.ps1' {
          Rename-Item -LiteralPath $argsMap['CurrentFilename'] -NewName $argsMap['NewFilename'] -Force
        }
        default { }
      }
    }

    $targets = @(
      @{
        Label = '32-bit'
        BuildArguments = @('-SupportedBitness','32')
        CloseArguments = @('-SupportedBitness','32')
        RenameArguments = @('-CurrentFilename','{{BaseArtifactPath}}','-NewFilename','lv_icon_x86.lvlibp')
      },
      @{
        Label = '64-bit'
        BuildArguments = @('-SupportedBitness','64')
        CloseArguments = @('-SupportedBitness','64')
        RenameArguments = @('-CurrentFilename','{{BaseArtifactPath}}','-NewFilename','lv_icon_x64.lvlibp')
      }
    )

    { Invoke-LVPackedLibraryBuild `
        -InvokeAction $invokeAction `
        -BuildScriptPath $buildScript `
        -CloseScriptPath $closeScript `
        -RenameScriptPath $renameScript `
        -ArtifactDirectory $artifactDir `
        -BaseArtifactName 'lv_icon.lvlibp' `
        -CleanupPatterns @('lv_icon*.lvlibp') `
        -Targets $targets } | Should -Not -Throw

    Test-Path -LiteralPath (Join-Path $artifactDir 'lv_icon_x86.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $artifactDir 'lv_icon_x64.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $artifactDir 'lv_icon.lvlibp')     | Should -BeFalse

    ($callLog | Where-Object { $_.Script -eq 'build.ps1' }).Count  | Should -Be 2
    ($callLog | Where-Object { $_.Script -eq 'close.ps1' }).Count  | Should -Be 2
    ($callLog | Where-Object { $_.Script -eq 'rename.ps1' }).Count | Should -Be 2
  }

  It 'projects build failures through the handler' {
    $artifactDir = Join-Path $TestDrive 'artifacts'
    $null = New-Item -ItemType Directory -Path $artifactDir -Force

    $buildScript  = Join-Path $TestDrive 'build.ps1'
    $renameScript = Join-Path $TestDrive 'rename.ps1'

    '# build stub'  | Set-Content -LiteralPath $buildScript -Encoding ascii
    '# rename stub' | Set-Content -LiteralPath $renameScript -Encoding ascii

    $invokeAction = {
      param(
        [string]$ScriptPath,
        [string[]]$Arguments
      )

      $argsMap = @{}
      if ($Arguments) {
        for ($i = 0; $i -lt $Arguments.Count; $i += 2) {
          $argsMap[$Arguments[$i].TrimStart('-')] = $Arguments[$i + 1]
        }
      }

      if (Split-Path -Leaf $ScriptPath -eq 'build.ps1' -and $argsMap['SupportedBitness'] -eq '32') {
        throw [System.Exception]::new('simulated failure')
      }
    }

    $targets = @(
      @{
        Label = '32-bit'
        BuildArguments = @('-SupportedBitness','32')
        RenameArguments = @('-CurrentFilename','{{BaseArtifactPath}}','-NewFilename','lv_icon_x86.lvlibp')
      }
    )

    $handler = {
      param(
        [hashtable]$Target,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
      )
      return [System.InvalidOperationException]::new("build failure: $($Target.Label)", $ErrorRecord.Exception)
    }

    $threw = $false
    $captured = $null
    try {
      Invoke-LVPackedLibraryBuild `
        -InvokeAction $invokeAction `
        -BuildScriptPath $buildScript `
        -RenameScriptPath $renameScript `
        -ArtifactDirectory $artifactDir `
        -BaseArtifactName 'lv_icon.lvlibp' `
        -Targets $targets `
        -OnBuildError $handler
    } catch {
      $threw = $true
      $captured = $_.Exception
    }

    $threw | Should -BeTrue
    $captured | Should -BeOfType ([System.InvalidOperationException])
    $captured.Message | Should -Be 'build failure: 32-bit'
  }
}
