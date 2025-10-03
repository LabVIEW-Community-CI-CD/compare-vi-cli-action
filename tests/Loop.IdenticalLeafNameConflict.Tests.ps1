<#[
  Test: Identical leaf filename conflict guard in Run-AutonomousIntegrationLoop.
  Approach:
    * Create two files with the same filename in different directories.
    * Point Base and Head to those paths via env vars.
    * Enable LOOP_SIMULATE to avoid actual CLI usage.
    * Expect script to exit 1 early after emitting identicalLeafConflict JSON event in log.
#>]
Set-StrictMode -Version Latest

Describe 'Run-AutonomousIntegrationLoop identical leaf conflict guard' -Tag 'Unit' {
  $root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')
  $loopScript = Join-Path $root 'scripts/Run-AutonomousIntegrationLoop.ps1'

  It 'fails fast with identicalLeafConflict event' {
    $dirA = Join-Path $TestDrive 'A'; $dirB = Join-Path $TestDrive 'B'
    New-Item -ItemType Directory -Path $dirA | Out-Null
    New-Item -ItemType Directory -Path $dirB | Out-Null
    $fileA = Join-Path $dirA 'SameName.vi'
    $fileB = Join-Path $dirB 'SameName.vi'
    Set-Content $fileA 'a' -Encoding utf8
    Set-Content $fileB 'b' -Encoding utf8

    $env:LV_BASE_VI = $fileA
    $env:LV_HEAD_VI = $fileB
    $env:LOOP_SIMULATE = '1'
    $env:LOOP_JSON_LOG = Join-Path $TestDrive 'conflict.ndjson'
    Remove-Item $env:LOOP_JSON_LOG -ErrorAction SilentlyContinue

    $proc = Start-Process pwsh -ArgumentList '-NoLogo','-NoProfile','-File',$loopScript -PassThru -Wait -WindowStyle Hidden
    $proc.ExitCode | Should -Not -Be 0
    Test-Path $env:LOOP_JSON_LOG | Should -BeTrue
    $conflict = Get-Content $env:LOOP_JSON_LOG | Where-Object { $_ -match 'identicalLeafConflict' }
    $conflict.Count | Should -Be 1
    ($conflict | ConvertFrom-Json).leaf | Should -Be 'SameName.vi'
  }
}
