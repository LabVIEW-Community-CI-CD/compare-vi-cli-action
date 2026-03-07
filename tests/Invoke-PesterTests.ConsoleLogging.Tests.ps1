Describe 'Invoke-PesterTests console logging' -Tag 'Unit' {
  BeforeAll {
    . (Join-Path $PSScriptRoot '_TestPathHelper.ps1')
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $script:dispatcher = Join-Path $repoRoot 'Invoke-PesterTests.ps1'
    $script:pwsh = (Get-Command pwsh -ErrorAction Stop).Source
  }

  It 'emits explicit info-level lifecycle lines for local dispatcher runs' {
    $testsRoot = Join-Path $TestDrive 'console-logging-tests'
    New-Item -ItemType Directory -Force -Path $testsRoot | Out-Null
    @(
      "Describe 'Console logging' {",
      "  It 'passes' { 1 | Should -Be 1 }",
      "}"
    ) | Set-Content -LiteralPath (Join-Path $testsRoot 'Console.Logging.Tests.ps1') -Encoding UTF8

    $resultsDir = Join-Path $TestDrive 'results'
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:pwsh
    foreach ($arg in @(
      '-NoLogo',
      '-NoProfile',
      '-File',
      $script:dispatcher,
      '-TestsPath',
      $testsRoot,
      '-ResultsPath',
      $resultsDir,
      '-IntegrationMode',
      'exclude',
      '-TimeoutSeconds',
      '0'
    )) {
      $psi.ArgumentList.Add($arg)
    }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Environment['LOCAL_DISPATCHER'] = '1'
    $psi.Environment['DISABLE_STEP_SUMMARY'] = '1'
    $psi.Environment['STUCK_GUARD'] = '0'

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
      $proc.WaitForExit(30000) | Should -BeTrue
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.ExitCode | Should -Be 0
      $stderr | Should -BeNullOrEmpty
      $stdout | Should -Match '\[info\] Checking for Pester availability'
      $stdout | Should -Match '\[info\] Configuring Pester'
      $stdout | Should -Match '\[info\] Executing Pester tests'
      $stdout | Should -Match '\[info\] execution-mode: singleInvoker='
    } finally {
      try { $proc.Dispose() } catch {}
    }
  }

}
