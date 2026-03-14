BeforeAll {
  $scriptPath = Join-Path $PSScriptRoot '..' 'tools' 'Watch-PRChecksSafe.ps1'
  . $scriptPath
}

Describe 'Watch-PRChecksSafe' {
  It 'treats an initial no-check snapshot as transient until checks materialize and pass' {
    $script:callCount = 0

    Mock Resolve-GhPath { 'gh' }
    Mock Resolve-PullRequestNumber { '123' }
    Mock Get-PrChecksSnapshot {
      $script:callCount += 1
      switch ($script:callCount) {
        1 { return @() }
        2 {
          return @(
            [pscustomobject]@{
              Workflow = 'Validate'
              Name = 'lint'
              Bucket = 'pending'
              State = 'IN_PROGRESS'
              Link = 'https://example.test/checks/1'
            }
          )
        }
        default {
          return @(
            [pscustomobject]@{
              Workflow = 'Validate'
              Name = 'lint'
              Bucket = 'pass'
              State = 'COMPLETED'
              Link = 'https://example.test/checks/1'
            }
          )
        }
      }
    }
    Mock Start-Sleep {}

    $result = Invoke-SafePrChecksWatch -PullRequest 123 -IntervalSeconds 5 -HeartbeatPolls 1 -MaxPolls 5

    $result.ExitCode | Should -Be 0
    $result.Outcome | Should -Be 'passed'
    $script:callCount | Should -Be 3
    Assert-MockCalled Start-Sleep -Times 2 -Exactly
  }

  It 'fails with MaxPolls when checks never materialize' {
    Mock Resolve-GhPath { 'gh' }
    Mock Resolve-PullRequestNumber { '456' }
    Mock Get-PrChecksSnapshot { @() }
    Mock Start-Sleep {}

    $result = Invoke-SafePrChecksWatch -PullRequest 456 -IntervalSeconds 5 -HeartbeatPolls 1 -MaxPolls 2

    $result.ExitCode | Should -Be 8
    $result.Outcome | Should -Be 'no-checks-timeout'
    $result.ObservedChecks | Should -BeFalse
    Assert-MockCalled Start-Sleep -Times 1 -Exactly
  }
}
