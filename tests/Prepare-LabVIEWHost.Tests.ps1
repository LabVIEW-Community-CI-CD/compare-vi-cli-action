$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Describe 'Prepare-LabVIEWHost helper' -Tag 'Unit','IconEditor' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:prepScript = Join-Path $script:repoRoot 'tools/icon-editor/Prepare-LabVIEWHost.ps1'
  }

  It 'parses comma/space separated lists and returns a dry-run summary' {
    $fixturePath = Join-Path $TestDrive 'icon-editor.fixture.vip'
    Set-Content -LiteralPath $fixturePath -Value 'stub' -Encoding ascii
    $workspaceRoot = Join-Path $TestDrive 'snapshots'

    $result = & $script:prepScript `
      -FixturePath $fixturePath `
      -Versions '2021,2023' `
      -Bitness '64 32' `
      -StageName 'unit-host-prep' `
      -WorkspaceRoot $workspaceRoot `
      -IconEditorRoot (Join-Path $script:repoRoot 'vendor/icon-editor') `
      -SkipStage `
      -SkipDevMode `
      -SkipClose `
      -SkipReset `
      -SkipRogueDetection `
      -SkipPostRogueDetection `
      -DryRun

    $result | Should -Not -BeNullOrEmpty
    $result.stage | Should -Be 'unit-host-prep'
    $result.dryRun | Should -BeTrue
    $result.versions | Should -Be @(2021, 2023)
    $result.bitness | Should -Be @(32, 64)
    Test-Path -LiteralPath $workspaceRoot | Should -BeTrue
    $result.telemetryPath | Should -Not -BeNullOrEmpty
    Test-Path -LiteralPath $result.telemetryPath | Should -BeTrue

    $telemetry = Get-Content -LiteralPath $result.telemetryPath -Raw | ConvertFrom-Json -Depth 6
    $telemetry.schema | Should -Be 'icon-editor/host-prep@v1'
    $telemetry.steps.stage.skipped | Should -BeTrue
    $telemetry.steps.devMode.skipped | Should -BeTrue
    $telemetry.steps.close.skipped | Should -BeTrue
    $telemetry.steps.reset.skipped | Should -BeTrue
    @($telemetry.closures).Count | Should -Be 0
  }
}
