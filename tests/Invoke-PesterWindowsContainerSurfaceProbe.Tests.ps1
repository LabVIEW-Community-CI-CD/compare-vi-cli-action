Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterWindowsContainerSurfaceProbe' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:toolPath = Join-Path $script:repoRoot 'tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1'
  }

  It 'records not-windows-host explicitly when the current host is not Windows' {
    $resultsDir = Join-Path $TestDrive 'linux'

    & $script:toolPath -ResultsDir $resultsDir -HostPlatformOverride 'Unix' | Out-Host
    $LASTEXITCODE | Should -Be 0

    $receipt = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-windows-container-surface.json') -Raw | ConvertFrom-Json
    $receipt.status | Should -Be 'not-windows-host'
    $receipt.reason | Should -Be 'surface-requires-windows-host'
    $receipt.recommendedCommands | Should -Contain 'npm run compare:docker:ni:windows:probe'
  }

  It 'records ready when Docker reports a Windows engine and the pinned NI image is available' {
    $resultsDir = Join-Path $TestDrive 'ready'
    $server = '{"Os":"windows","Version":"27.5.1","Platform":{"Name":"Docker Desktop 4.43.0"}}'
    $image = '{"Id":"sha256:1234","RepoTags":["nationalinstruments/labview:2026q1-windows"]}'

    & $script:toolPath -ResultsDir $resultsDir -HostPlatformOverride 'Win32NT' -DockerServerJson $server -ImageInspectJson $image | Out-Host
    $LASTEXITCODE | Should -Be 0

    $receipt = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-windows-container-surface.json') -Raw | ConvertFrom-Json
    $receipt.status | Should -Be 'ready'
    $receipt.reason | Should -Be 'windows-container-surface-ready'
    $receipt.pinnedImagePresent | Should -BeTrue
  }

  It 'records docker-engine-not-windows when the Docker server resolves to Linux' {
    $resultsDir = Join-Path $TestDrive 'linux-engine'
    $server = '{"Os":"linux","Version":"27.5.1","Platform":{"Name":"Docker Desktop 4.43.0"}}'

    & $script:toolPath -ResultsDir $resultsDir -HostPlatformOverride 'Win32NT' -DockerServerJson $server | Out-Host
    $LASTEXITCODE | Should -Be 0

    $receipt = Get-Content -LiteralPath (Join-Path $resultsDir 'pester-windows-container-surface.json') -Raw | ConvertFrom-Json
    $receipt.status | Should -Be 'docker-engine-not-windows'
    $receipt.reason | Should -Be 'docker-server-not-windows'
    $receipt.pinnedImagePresent | Should -BeFalse
  }
}
