#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Compare-ExitCodeClassifier.ps1' -Tag 'Unit' {
  BeforeAll {
    $scriptPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'tools' 'Compare-ExitCodeClassifier.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
      throw "Compare-ExitCodeClassifier.ps1 not found at $scriptPath"
    }
    . $scriptPath
  }

  It 'classifies exit 0 as success-no-diff' {
    $classification = Get-CompareExitClassification -ExitCode 0 -CaptureStatus 'ok'
    $classification.resultClass | Should -Be 'success-no-diff'
    $classification.isDiff | Should -BeFalse
    $classification.gateOutcome | Should -Be 'pass'
    $classification.failureClass | Should -Be 'none'
  }

  It 'classifies exit 1 with diff status as success-diff' {
    $classification = Get-CompareExitClassification -ExitCode 1 -CaptureStatus 'diff'
    $classification.resultClass | Should -Be 'success-diff'
    $classification.isDiff | Should -BeTrue
    $classification.gateOutcome | Should -Be 'pass'
    $classification.failureClass | Should -Be 'none'
  }

  It 'classifies exit 1 with CLI error signature as failure-tool' {
    $classification = Get-CompareExitClassification `
      -ExitCode 1 `
      -CaptureStatus 'error' `
      -StdErr 'Error code: 8'
    $classification.resultClass | Should -Be 'failure-tool'
    $classification.isDiff | Should -BeFalse
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'cli/tool'
  }

  It 'classifies startup connectivity signature as failure-tool startup-connectivity' {
    $classification = Get-CompareExitClassification `
      -ExitCode 1 `
      -CaptureStatus 'error' `
      -StdErr 'Error code: -350000'
    $classification.resultClass | Should -Be 'failure-tool'
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'startup-connectivity'
  }

  It 'classifies timeout as failure-timeout' {
    $classification = Get-CompareExitClassification -ExitCode 124 -CaptureStatus 'timeout' -TimedOut
    $classification.resultClass | Should -Be 'failure-timeout'
    $classification.isDiff | Should -BeFalse
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'timeout'
  }

  It 'classifies runtime determinism mismatch as failure-runtime' {
    $classification = Get-CompareExitClassification `
      -ExitCode 2 `
      -CaptureStatus 'preflight-error' `
      -Message 'Runtime determinism guard failed with exit code 1.' `
      -RuntimeDeterminismStatus 'mismatch-failed'
    $classification.resultClass | Should -Be 'failure-runtime'
    $classification.isDiff | Should -BeFalse
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'runtime-determinism'
  }

  It 'treats exit 1 without failure signatures as diff by policy' {
    $classification = Get-CompareExitClassification `
      -ExitCode 1 `
      -CaptureStatus 'error' `
      -StdOut 'CreateComparisonReport completed with differences.'
    $classification.resultClass | Should -Be 'success-diff'
    $classification.isDiff | Should -BeTrue
    $classification.gateOutcome | Should -Be 'pass'
    $classification.failureClass | Should -Be 'none'
  }

  It 'prioritizes runtime determinism failure over timeout signature' {
    $classification = Get-CompareExitClassification `
      -ExitCode 124 `
      -CaptureStatus 'timeout' `
      -Message 'Runtime determinism mismatch after repair.' `
      -RuntimeDeterminismStatus 'mismatch-failed' `
      -TimedOut
    $classification.resultClass | Should -Be 'failure-runtime'
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'runtime-determinism'
  }

  It 'classifies capture objects through Get-CompareCaptureClassification' {
    $capture = [pscustomobject]@{
      exitCode = 1
      status = 'diff'
      timedOut = $false
      stdout = 'CreateComparisonReport completed with differences.'
      stderr = ''
      message = ''
      runtimeDeterminism = [pscustomobject]@{
        status = 'ok'
        reason = ''
      }
    }

    $classification = Get-CompareCaptureClassification -Capture $capture
    $classification.resultClass | Should -Be 'success-diff'
    $classification.isDiff | Should -BeTrue
    $classification.gateOutcome | Should -Be 'pass'
    $classification.failureClass | Should -Be 'none'
  }

  It 'classifies generic preflight errors as failure-preflight' {
    $classification = Get-CompareExitClassification `
      -ExitCode 2 `
      -CaptureStatus 'preflight-error' `
      -Message 'Docker image missing.'
    $classification.resultClass | Should -Be 'failure-preflight'
    $classification.isDiff | Should -BeFalse
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'preflight'
  }

  It 'classifies startup connectivity from message text' {
    $classification = Get-CompareExitClassification `
      -ExitCode 1 `
      -CaptureStatus 'error' `
      -Message 'OpenAppReferenceTimeoutInSecond exceeded with -350000'
    $classification.resultClass | Should -Be 'failure-tool'
    $classification.gateOutcome | Should -Be 'fail'
    $classification.failureClass | Should -Be 'startup-connectivity'
  }
}
