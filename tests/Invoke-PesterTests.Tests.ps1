Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-PesterTests.ps1 Dispatcher' -Tag 'Unit' {
  BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:dispatcherPath = Join-Path $script:repoRoot 'Invoke-PesterTests.ps1'
    $script:dispatcherSkip = $false
    $script:dispatcherSkipReason = $null

    try {
      Import-Module (Join-Path $script:repoRoot 'tests' '_helpers' 'DispatcherTestHelper.psm1') -Force -ErrorAction Stop
      $pwshPath = Get-PwshExePath
      if (-not $pwshPath) {
        $script:dispatcherSkip = $true
        $script:dispatcherSkipReason = 'pwsh executable not available on PATH'
      }
    } catch {
      $script:dispatcherSkip = $true
      $script:dispatcherSkipReason = "failed to import dispatcher test helper: $_"
    }

    $script:invokeSelfDispatcher = {
      param(
        [Parameter(Mandatory)][string]$ResultsPath,
        [string[]]$AdditionalArgs
      )

      Push-Location $script:repoRoot
      try {
        Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath `
          -ResultsPath $ResultsPath `
          -IncludePatterns 'Invoke-PesterTests.Tests.ps1' `
          -AdditionalArgs $AdditionalArgs `
          -TimeoutSeconds 60
      } finally {
        Pop-Location
      }
    }
  }

  It 'writes a guard crumb when ResultsPath points to a file' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'guard-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null

    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) { Remove-Item -LiteralPath $crumbPath -Force }

    $res = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IntegrationMode','exclude')

    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 1

    $joinedOutput = ($res.StdOut + "`n" + $res.StdErr)
    $joinedOutput | Should -Match 'guard crumb'
    $joinedOutput | Should -Match ([regex]::Escape('tests/results/_diagnostics/guard.json'))

    Test-Path -LiteralPath $crumbPath | Should -BeTrue
    $crumb = Get-Content -LiteralPath $crumbPath -Raw | ConvertFrom-Json -Depth 4
    $crumb.schema | Should -Be 'dispatcher-results-guard/v1'
    $crumb.path   | Should -Be $resultsFile
  }

  It 'resolves IntegrationMode include to enable integration tests' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'mode-include-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null

    $res = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IntegrationMode','include')

    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 1
    $joined = ($res.StdOut + "`n" + $res.StdErr)
    $joined | Should -Match 'Integration Mode: include'
    $joined | Should -Match 'Include Integration: True'
  }

  It 'honors INCLUDE_INTEGRATION for auto integration mode' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'mode-auto-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null
    $previousValue = $env:INCLUDE_INTEGRATION
    $env:INCLUDE_INTEGRATION = 'true'

    $res = $null
    try {
      $res = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IntegrationMode','auto')
    } finally {
      if ($null -ne $previousValue) {
        $env:INCLUDE_INTEGRATION = $previousValue
      } else {
        Remove-Item Env:\INCLUDE_INTEGRATION -ErrorAction SilentlyContinue
      }
    }

    $res | Should -Not -BeNullOrEmpty
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 1
    $joined = ($res.StdOut + "`n" + $res.StdErr)
    $joined | Should -Match 'Integration Mode: auto'
    $joined | Should -Match 'Include Integration: True'
    $joined | Should -Match 'Mode Source: auto:env:INCLUDE_INTEGRATION'
  }

  It 'maintains legacy IncludeIntegration compatibility' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'legacy-include-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null

    $res = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IncludeIntegration','true')
    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 1
    $joined = ($res.StdOut + "`n" + $res.StdErr)
    $joined | Should -Match 'Integration Mode: include'
    $joined | Should -Match 'Include Integration: True'
    $joined | Should -Match 'IncludeIntegration is deprecated'
  }

  It 'accepts repo-relative IncludePatterns without crashing dispatcher selection' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsDir = Join-Path $TestDrive 'relative-include-results'
    Push-Location $script:repoRoot
    try {
      $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath `
        -ResultsPath $resultsDir `
        -IncludePatterns 'tests/Invoke-GitHubIntakeScenario.Tests.ps1' `
        -AdditionalArgs @('-IntegrationMode','exclude') `
        -TimeoutSeconds 90
    } finally {
      Pop-Location
    }

    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    ($res.StdOut + "`n" + $res.StdErr) | Should -Match 'Applied IncludePatterns \(tests/Invoke-GitHubIntakeScenario\.Tests\.ps1\) -> kept 1/'
  }

  It 'emits placeholder artifacts when IncludePatterns matches zero files' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsDir = Join-Path $TestDrive 'zero-match-results'
    Push-Location $script:repoRoot
    try {
      $res = Invoke-DispatcherSafe -DispatcherPath $script:dispatcherPath `
        -ResultsPath $resultsDir `
        -IncludePatterns 'tests/DoesNotExist.Tests.ps1' `
        -AdditionalArgs @('-IntegrationMode','exclude') `
        -TimeoutSeconds 60
    } finally {
      Pop-Location
    }

    $res.TimedOut | Should -BeFalse
    $res.ExitCode | Should -Be 0
    ($res.StdOut + "`n" + $res.StdErr) | Should -Match 'No test files found\. Placeholder artifacts emitted\.'
    Test-Path -LiteralPath (Join-Path $resultsDir 'pester-results.xml') | Should -BeTrue
  }

  It 'does not override an existing FAST_PESTER value when integrations excluded' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'fast-preserve-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null

    $hadFast = Test-Path Env:\FAST_PESTER
    $previousFast = $null
    if ($hadFast) { $previousFast = $env:FAST_PESTER }

    try {
      $env:FAST_PESTER = '0'
      $null = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IntegrationMode','exclude')

      Test-Path Env:\FAST_PESTER | Should -BeTrue
      $env:FAST_PESTER | Should -Be '0'
    } finally {
      if ($hadFast) {
        $env:FAST_PESTER = $previousFast
      } else {
        Remove-Item Env:\FAST_PESTER -ErrorAction SilentlyContinue
      }
    }
  }

  It 'honors FAST_TESTS when determining auto fast mode' {
    if ($script:dispatcherSkip) {
      Set-ItResult -Skipped -Because $script:dispatcherSkipReason
      return
    }

    $resultsFile = Join-Path $TestDrive 'fast-tests-blocker.txt'
    New-Item -ItemType File -Path $resultsFile -Force | Out-Null

    $hadFast = Test-Path Env:\FAST_PESTER
    $previousFast = if ($hadFast) { $env:FAST_PESTER } else { $null }
    $hadFastTests = Test-Path Env:\FAST_TESTS
    $previousFastTests = if ($hadFastTests) { $env:FAST_TESTS } else { $null }

    try {
      Remove-Item Env:\FAST_PESTER -ErrorAction SilentlyContinue
      $env:FAST_TESTS = '0'

      $null = & $script:invokeSelfDispatcher -ResultsPath $resultsFile -AdditionalArgs @('-IntegrationMode','exclude')

      Test-Path Env:\FAST_PESTER | Should -BeFalse
      $env:FAST_TESTS | Should -Be '0'
    } finally {
      if ($hadFast) {
        $env:FAST_PESTER = $previousFast
      } else {
        Remove-Item Env:\FAST_PESTER -ErrorAction SilentlyContinue
      }
      if ($hadFastTests) {
        $env:FAST_TESTS = $previousFastTests
      } else {
        Remove-Item Env:\FAST_TESTS -ErrorAction SilentlyContinue
      }
    }
  }

  It 'emits placeholder artifacts with null timing metrics when no tests are discovered' {
    $workspace = Join-Path $TestDrive 'zero-tests'
    $testsDir = Join-Path $workspace 'tests'
    $resultsDir = Join-Path $workspace 'results'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null

    Push-Location $script:repoRoot
    try {
      & pwsh -NoLogo -NoProfile -File $script:dispatcherPath -TestsPath $testsDir -ResultsPath $resultsDir -IntegrationMode exclude | Out-Null
      $exitCode = $LASTEXITCODE
    } finally {
      Pop-Location
    }

    $exitCode | Should -Be 0

    $summaryPath = Join-Path $resultsDir 'pester-summary.json'
    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -Depth 4
    $summary.total | Should -Be 0
    $summary.meanTest_ms | Should -Be $null
    $summary.p95Test_ms | Should -Be $null
    $summary.maxTest_ms | Should -Be $null
    $summary.timedOut | Should -BeFalse

    $xmlPath = Join-Path $resultsDir 'pester-results.xml'
    Test-Path -LiteralPath $xmlPath | Should -BeTrue

    $sessionIndexPath = Join-Path $resultsDir 'session-index.json'
    Test-Path -LiteralPath $sessionIndexPath | Should -BeTrue
    $session = Get-Content -LiteralPath $sessionIndexPath -Raw | ConvertFrom-Json -Depth 4
    $session.summary.meanTest_ms | Should -Be $null
    $session.summary.maxTest_ms | Should -Be $null
  }

  AfterEach {
    $crumbPath = Join-Path $script:repoRoot 'tests/results/_diagnostics/guard.json'
    if (Test-Path -LiteralPath $crumbPath) {
      Remove-Item -LiteralPath $crumbPath -Force
      $diagDir = Split-Path -Parent $crumbPath
      if ((Test-Path -LiteralPath $diagDir) -and -not (Get-ChildItem -LiteralPath $diagDir -Force)) {
        Remove-Item -LiteralPath $diagDir -Force
      }
    }
  }
}
