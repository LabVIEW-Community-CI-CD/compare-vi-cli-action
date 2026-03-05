#Requires -Version 7.0

Describe 'Test-IconEditorPackage.ps1' -Tag 'IconEditor','Packaging','Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Test-IconEditorPackage.ps1'
  }

  It 'returns skipped summary when no VIP artifacts supplied' {
    $resultsRoot = Join-Path $TestDrive 'results'
    $summary = & $script:scriptPath -ResultsRoot $resultsRoot

    $summary.status | Should -Be 'skipped'
    $summary.vipCount | Should -Be 0
    Test-Path -LiteralPath (Join-Path $resultsRoot 'package-smoke-summary.json') | Should -BeTrue
  }

  It 'throws when VIPs are required but missing' {
    { & $script:scriptPath -RequireVip } | Should -Throw
  }

  It 'validates a well-formed VIP package' {
    $resultsRoot = Join-Path $TestDrive 'results-ok'
    $vipPath = Join-Path $TestDrive 'IconEditor_Test.vip'
    $workDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $pluginsDir = Join-Path $workDir 'resource\plugins'
    $supportDir = Join-Path $workDir 'support'
    $null = New-Item -ItemType Directory -Path $pluginsDir -Force
    $null = New-Item -ItemType Directory -Path $supportDir -Force
    'x86' | Set-Content -LiteralPath (Join-Path $pluginsDir 'lv_icon_x86.lvlibp') -Encoding utf8
    'x64' | Set-Content -LiteralPath (Join-Path $pluginsDir 'lv_icon_x64.lvlibp') -Encoding utf8
    '1.2.3.4' | Set-Content -LiteralPath (Join-Path $supportDir 'build.txt') -Encoding utf8
    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $vipPath -Force
    Remove-Item -LiteralPath $workDir -Recurse -Force

    $summary = & $script:scriptPath `
      -VipPath $vipPath `
      -ResultsRoot $resultsRoot `
      -VersionInfo @{ major = 1; minor = 2; patch = 3; build = 4 }

    $summary.status | Should -Be 'ok'
    $summary.vipCount | Should -Be 1
    $summary.items[0].status | Should -Be 'ok'
    $summary.items[0].checks.hasLvIconX86 | Should -BeTrue
    $summary.items[0].checks.hasLvIconX64 | Should -BeTrue
    $summary.items[0].checks.versionMatch | Should -BeTrue
  }

  It 'flags missing artifacts inside the VIP' {
    $resultsRoot = Join-Path $TestDrive 'results-missing'
    $vipPath = Join-Path $TestDrive 'IconEditor_Incomplete.vip'
    $workDir = Join-Path $TestDrive ([guid]::NewGuid().ToString())
    $pluginsDir = Join-Path $workDir 'resource\plugins'
    $supportDir = Join-Path $workDir 'support'
    $null = New-Item -ItemType Directory -Path $pluginsDir -Force
    $null = New-Item -ItemType Directory -Path $supportDir -Force
    'x86' | Set-Content -LiteralPath (Join-Path $pluginsDir 'lv_icon_x86.lvlibp') -Encoding utf8
    '0.0.0.0' | Set-Content -LiteralPath (Join-Path $supportDir 'build.txt') -Encoding utf8
    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $vipPath -Force
    Remove-Item -LiteralPath $workDir -Recurse -Force

    $summary = & $script:scriptPath -VipPath $vipPath -ResultsRoot $resultsRoot

    $summary.status | Should -Be 'fail'
    $summary.items[0].status | Should -Be 'fail'
    $summary.items[0].checks.hasLvIconX64 | Should -BeFalse
  }
}
