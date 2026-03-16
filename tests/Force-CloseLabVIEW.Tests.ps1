Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Force-CloseLabVIEW.ps1' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:scriptPath = Join-Path $repoRoot 'tools' 'Force-CloseLabVIEW.ps1'
    Test-Path -LiteralPath $script:scriptPath | Should -BeTrue
  }

  It 'ignores PID-scoped targets whose process names do not match the requested LabVIEW surface' {
    $work = Join-Path $TestDrive 'force-close'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    $fakeLabVIEW = Join-Path $work 'LabVIEW.exe'
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32' 'cmd.exe') -Destination $fakeLabVIEW -Force

    $labProc = Start-Process -FilePath $fakeLabVIEW -ArgumentList '/c','timeout /t 30 /nobreak >nul' -PassThru
    $pwshProc = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 30' -PassThru

    try {
      $raw = & $script:scriptPath -ProcessName LabVIEW -ProcessId @($labProc.Id, $pwshProc.Id) -DryRun -Quiet
      $json = ($raw | Out-String) | ConvertFrom-Json -Depth 6

      $json.result | Should -Be 'skipped'
      @($json.targets).Count | Should -Be 1
      @($json.targets | ForEach-Object { [int]$_.pid }) | Should -Contain $labProc.Id
      @($json.targets | ForEach-Object { [int]$_.pid }) | Should -Not -Contain $pwshProc.Id
    } finally {
      try { if (-not $labProc.HasExited) { $labProc.Kill() } } catch {}
      try { if (-not $pwshProc.HasExited) { $pwshProc.Kill() } } catch {}
    }
  }
}
