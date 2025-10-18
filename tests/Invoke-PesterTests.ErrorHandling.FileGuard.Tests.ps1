Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Variable -Name skipGuardSelfTest -Scope Script -Value $false -Force
Set-Variable -Name skipReason -Scope Script -Value 'Dispatcher guard self-test suppressed in nested dispatcher context' -Force

Describe 'Dispatcher results path guard (file case)' -Tag 'Unit' {
  BeforeAll {
    if ($env:SUPPRESS_GUARD_SELFTEST -eq '1') {
      $script:skipGuardSelfTest = $true
      $script:skipReason = 'Dispatcher guard self-test suppressed in nested dispatcher context'
      return
    }

    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here '..')
    $script:repoRoot = $root
    $script:dispatcherPath = Join-Path $root 'Invoke-PesterTests.ps1'
    Test-Path -LiteralPath $script:dispatcherPath | Should -BeTrue
    Import-Module (Join-Path $root 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force

    $script:pwshPath = Get-PwshExePath
    if ($script:pwshPath) {
      $script:pwshAvailable = $true
      $script:skipReason = $null
    } else {
      $script:pwshAvailable = $false
      $script:skipReason = 'pwsh executable not available on PATH'
    }
  }

  It 'fails and emits a guard crumb when ResultsPath points to a file' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipGuardSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Dispatcher guard self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'blocked-results.txt'
    Set-Content -LiteralPath $resultsFile -Value 'blocked' -Encoding ascii

    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) { Remove-Item -LiteralPath $crumbPath -Force }

    $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath -ResultsPath $resultsFile -IncludePatterns 'Invoke-PesterTests.ErrorHandling.*.ps1' -TimeoutSeconds 20
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Not -Be 0

    $combined = ($res.StdOut + "`n" + $res.StdErr)
    $combined | Should -Match 'Results path points to a file'

    Test-Path -LiteralPath $crumbPath | Should -BeTrue
    $crumb = Get-Content -LiteralPath $crumbPath -Raw | ConvertFrom-Json
    $crumb.schema | Should -Be 'dispatcher-results-guard/v1'
    $crumb.path   | Should -Be $resultsFile
    $pattern = [regex]::Escape($resultsFile)
    $crumb.message | Should -Match $pattern
  }

  It 'clears a stale guard crumb before launching the dispatcher' {
    $skipFlag = $false
    $skipVar = Get-Variable -Name skipGuardSelfTest -Scope Script -ErrorAction SilentlyContinue
    if ($skipVar) { $skipFlag = [bool]$skipVar.Value }
    if ($skipFlag) {
      $reasonVar = Get-Variable -Name skipReason -Scope Script -ErrorAction SilentlyContinue
      $reason = if ($reasonVar) { [string]$reasonVar.Value } else { 'Dispatcher guard self-test suppressed in nested dispatcher context' }
      Set-ItResult -Skipped -Because $reason
      return
    }

    if (-not $script:pwshAvailable) {
      Set-ItResult -Skipped -Because $script:skipReason
      return
    }

    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    $crumbDir = Split-Path -Parent $crumbPath
    if (-not (Test-Path -LiteralPath $crumbDir -PathType Container)) {
      New-Item -ItemType Directory -Path $crumbDir -Force | Out-Null
    }

    $previousCrumb = $null
    $hadCrumb = $false
    if (Test-Path -LiteralPath $crumbPath -PathType Leaf) {
      $previousCrumb = Get-Content -LiteralPath $crumbPath -Raw
      $hadCrumb = $true
    }

    try {
      # Seed a stale crumb to simulate a prior guarded failure.
      $stale = '{"schema":"dispatcher-results-guard/v1","message":"stale"}'
      Set-Content -LiteralPath $crumbPath -Value $stale -Encoding utf8

      $resultsDir = Join-Path $TestDrive 'clean-results'
      $stdout = & $script:pwshPath -NoLogo -NoProfile -File $script:dispatcherPath -ResultsPath $resultsDir -GuardResetOnly 2>&1
      $exitCode = $LASTEXITCODE

      $exitCode | Should -Be 0
      ($stdout -join [Environment]::NewLine) | Should -Match '\[guard\] Cleared stale dispatcher guard crumb'

      Test-Path -LiteralPath $crumbPath | Should -BeFalse
    } finally {
      if ($hadCrumb) {
        if (-not (Test-Path -LiteralPath $crumbDir -PathType Container)) {
          New-Item -ItemType Directory -Path $crumbDir -Force | Out-Null
        }
        Set-Content -LiteralPath $crumbPath -Value $previousCrumb -Encoding utf8
      } elseif (Test-Path -LiteralPath $crumbPath) {
        Remove-Item -LiteralPath $crumbPath -Force
      }
    }
  }
}

