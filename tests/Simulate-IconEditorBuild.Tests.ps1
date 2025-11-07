#Requires -Version 7.0

Describe 'Simulate-IconEditorBuild.ps1' -Tag 'IconEditor','Simulation','Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $script:repoRoot 'tools' 'icon-editor' 'Simulate-IconEditorBuild.ps1'
    $script:fixturePath = Join-Path $script:repoRoot 'tests' 'fixtures' 'icon-editor' 'ni_icon_editor-1.4.1.948.vip'
  }

  It 'materialises fixture artifacts and manifest' {
    if (-not (Test-Path -LiteralPath $script:fixturePath -PathType Leaf)) {
      Set-ItResult -Skip -Because 'Fixture VIP not available; skipping simulation test.'
      return
    }

    $resultsRoot = Join-Path $TestDrive 'simulate-results'
    $expected = @{
      major  = 9
      minor  = 9
      patch  = 9
      build  = 9
      commit = 'deadbeef'
    }

    $manifest = & $script:scriptPath `
      -FixturePath $script:fixturePath `
      -ResultsRoot $resultsRoot `
      -ExpectedVersion $expected

    $manifest | Should -Not -BeNullOrEmpty
    $manifest.simulation.enabled | Should -BeTrue
    $manifest.version.fixture.raw | Should -Be '1.4.1.948'
    $manifest.version.expected.commit | Should -Be 'deadbeef'

    $vipMain = Join-Path $resultsRoot 'ni_icon_editor-1.4.1.948.vip'
    $vipSystem = Join-Path $resultsRoot 'ni_icon_editor_system-1.4.1.948.vip'
    Test-Path -LiteralPath $vipMain | Should -BeTrue
    Test-Path -LiteralPath $vipSystem | Should -BeTrue

    Test-Path -LiteralPath (Join-Path $resultsRoot 'lv_icon_x86.lvlibp') | Should -BeTrue
    Test-Path -LiteralPath (Join-Path $resultsRoot 'lv_icon_x64.lvlibp') | Should -BeTrue

    $summaryPath = Join-Path $resultsRoot 'package-smoke-summary.json'
    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $summary.status | Should -Be 'ok'

    Test-Path -LiteralPath (Join-Path $resultsRoot '__fixture_extract') | Should -BeFalse
  }

  It 'handles legacy fixtures with install\plugins layout' {
    if (-not (Test-Path -LiteralPath $script:fixturePath -PathType Leaf)) {
      Set-ItResult -Skip -Because 'Fixture VIP not available; skipping simulation test.'
      return
    }

    $resultsRoot = Join-Path $TestDrive 'legacy-results'
    $fixtureRoot = Join-Path $TestDrive 'legacy-fixture'
    $systemRoot = Join-Path $TestDrive 'legacy-system'
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    New-Item -ItemType Directory -Path $systemRoot | Out-Null

    $fixtureSpec = @"
[Package]
Name="ni_icon_editor"
Version="1.2.3.4"
Release=""
File Format="vip"
Format Version="2017"
Display Name="Legacy Icon Editor"

[Description]
Description=""
Summary=""
License="MIT"
Vendor="NI"

[Files]
Num File Groups="1"
Sub-Packages="ni_icon_editor_system-1.2.3.4"
"@
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'spec') -Value $fixtureSpec -Encoding ascii
    $packagesDir = Join-Path $fixtureRoot 'Packages'
    New-Item -ItemType Directory -Path $packagesDir | Out-Null

    $systemSpec = @"
[Package]
Name="ni_icon_editor_system"
Version="1.2.3.4"
File Format="vip"
Format Version="2017"
Display Name="Legacy Icon Editor (System)"

[Files]
Num File Groups="1"
Sub-Packages=""
"@
    Set-Content -LiteralPath (Join-Path $systemRoot 'spec') -Value $systemSpec -Encoding ascii

    $pluginsDir = Join-Path $systemRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\install\plugins'
    New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $pluginsDir 'lv_icon_x64.lvlibp') -Value 'dummy64' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $pluginsDir 'lv_icon_x86.lvlibp') -Value 'dummy86' -Encoding ascii

    $systemVipPath = Join-Path $packagesDir 'ni_icon_editor_system-1.2.3.4.vip'
    Push-Location $systemRoot
    Compress-Archive -Path * -DestinationPath $systemVipPath
    Pop-Location

    $fixtureVipPath = Join-Path $TestDrive 'ni_icon_editor-1.2.3.4.vip'
    Push-Location $fixtureRoot
    Compress-Archive -Path * -DestinationPath $fixtureVipPath
    Pop-Location

    $manifest = & $script:scriptPath `
      -FixturePath $fixtureVipPath `
      -ResultsRoot $resultsRoot `
      -KeepExtract

    $manifest | Should -Not -BeNullOrEmpty
    $manifest.version.fixture.raw | Should -Be '1.2.3.4'

    $artifactNames = $manifest.artifacts | ForEach-Object name
    $artifactNames | Should -Contain 'lv_icon_x64.lvlibp'
    $artifactNames | Should -Contain 'lv_icon_x86.lvlibp'
  }

  It 'falls back to Copy-Item overlay when robocopy is unavailable' {
    if (-not (Test-Path -LiteralPath $script:fixturePath -PathType Leaf)) {
      Set-ItResult -Skip -Because 'Fixture VIP not available; skipping simulation test.'
      return
    }

    $resultsRoot = Join-Path $TestDrive 'fallback-results'
    $overlayRoot = Join-Path $TestDrive 'overlay-source'
    New-Item -ItemType Directory -Path $overlayRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $overlayRoot 'overlay.txt') -Value 'overlay-data' -Encoding utf8

    Mock -CommandName Get-Command -MockWith { return $null } -ParameterFilter { $Name -eq 'robocopy' }

    $manifest = & $script:scriptPath `
      -FixturePath $script:fixturePath `
      -ResultsRoot $resultsRoot `
      -ResourceOverlayRoot $overlayRoot `
      -KeepExtract

    $manifest | Should -Not -BeNullOrEmpty

    $resourceCopy = Join-Path $resultsRoot '__fixture_extract\__system_extract\File Group 0\National Instruments\LabVIEW Icon Editor\resource\overlay.txt'
    Test-Path -LiteralPath $resourceCopy -PathType Leaf | Should -BeTrue
  }

  It 'emits VIP diff metadata when a requests output directory is provided' {
    if (-not (Test-Path -LiteralPath $script:fixturePath -PathType Leaf)) {
      Set-ItResult -Skip -Because 'Fixture VIP not available; skipping simulation test.'
      return
    }

    $resultsRoot = Join-Path $TestDrive 'vip-diff-results'
    $vipDiffRoot = Join-Path $TestDrive 'vip-diff-output'
    $requestsPath = Join-Path $vipDiffRoot 'custom-requests.json'

    $manifest = & $script:scriptPath `
      -FixturePath $script:fixturePath `
      -ResultsRoot $resultsRoot `
      -VipDiffOutputDir $vipDiffRoot `
      -VipDiffRequestsPath $requestsPath

    $manifest | Should -Not -BeNullOrEmpty
    $manifest.vipDiff | Should -Not -BeNullOrEmpty
    $manifest.vipDiff.requestsPath | Should -Be (Resolve-Path -LiteralPath $requestsPath).Path
    $manifest.vipDiff.count | Should -BeGreaterThan 0
    Test-Path -LiteralPath $requestsPath -PathType Leaf | Should -BeTrue
    Test-Path -LiteralPath $vipDiffRoot -PathType Container | Should -BeTrue
  }
}
