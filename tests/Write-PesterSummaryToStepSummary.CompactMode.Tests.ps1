Describe 'Write-PesterSummaryToStepSummary compact & metadata' -Tag 'Unit' {
  BeforeAll {
    $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'scripts/Write-PesterSummaryToStepSummary.ps1'
    Set-Variable -Name ScriptPath -Value $scriptPath -Scope Script
  }

  Context 'With summary + failures' {
    BeforeEach {
      $resultsDir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
      New-Item -ItemType Directory -Path $resultsDir | Out-Null
      $summary = [pscustomobject]@{ total=5; passed=4; failed=1; skipped=0; errors=0; duration=2.5 } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-summary.json') $summary -Encoding UTF8
      $fails = [pscustomobject]@{ results=@([pscustomobject]@{ Name='Failing.Test'; result='Failed'; Duration=0.12 }) } | ConvertTo-Json -Depth 5
      Set-Content (Join-Path $resultsDir 'pester-failures.json') $fails -Encoding UTF8
      $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ("STEP_" + [System.Guid]::NewGuid().ToString() + '.md')
    }

    It 'emits compact block with totals list' {
      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge
      $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
      $content | Should -Match '\*\*Totals:\*\* 5 total'
      $content | Should -Match '4 passed'
      $content | Should -Match '1 failed'
      $content | Should -Match '\*\*Failures:\*\* Failing.Test'
      $content | Should -Not -Match '\| Metric \| Value \|'
    }

    It 'writes comment file when -CommentPath specified (no step summary env needed)' {
      Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
      $commentPath = Join-Path $TestDrive 'comment/comment.md'
      & $ScriptPath -ResultsDir $resultsDir -Compact -CommentPath $commentPath
      Test-Path $commentPath | Should -BeTrue
      (Get-Content $commentPath -Raw) | Should -Match 'Totals:'
    }

    It 'emits badge JSON metadata when -BadgeJsonPath provided' {
      $badgeJson = Join-Path $TestDrive 'badge/meta.json'
      $outcome = [pscustomobject]@{
        schema = 'pester-operator-outcome@v1'
        gateStatus = 'fail'
        classification = 'test-failures'
        nextActionId = 'review-top-failures'
        nextAction = 'Review pester-failures.json, the top-failures summary, and the failing test names before deciding whether to rerun or fix source.'
        reasons = @('summary-failed=1')
      } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-operator-outcome.json') $outcome -Encoding UTF8
      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge -BadgeJsonPath $badgeJson
      Test-Path $badgeJson | Should -BeTrue
      $obj = Get-Content $badgeJson -Raw | ConvertFrom-Json
      $obj.status | Should -Be 'failed'
      $obj.total | Should -Be 5
      $obj.failedTests | Should -Contain 'Failing.Test'
      $obj.failureDetailsStatus | Should -Be 'available'
      $obj.classification | Should -Be 'test-failures'
      $obj.gateStatus | Should -Be 'fail'
      $obj.nextActionId | Should -Be 'review-top-failures'
      $obj.badgeMarkdown | Should -Match '❌ Tests Failed:'
    }

    It 'reads array-shaped failures payloads in compact mode' {
      $fails = @([pscustomobject]@{ Name='Failing.ArrayTest'; result='Failed'; Duration=0.12 }) | ConvertTo-Json -Depth 5
      Set-Content (Join-Path $resultsDir 'pester-failures.json') $fails -Encoding UTF8
      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge
      $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
      $content | Should -Match '\*\*Failures:\*\* Failing.ArrayTest'
    }

    It 'surfaces explicit unavailable-details state in compact mode' {
      $summary = [pscustomobject]@{
        total = 5
        passed = 4
        failed = 1
        skipped = 0
        errors = 0
        duration = 2.5
        failureDetailsStatus = 'unavailable'
        failureDetailsReason = 'results-xml-truncated'
      } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-summary.json') $summary -Encoding UTF8
      $fails = [pscustomobject]@{
        schema = 'pester-failures@v2'
        schemaVersion = '1.1.0'
        detailStatus = 'unavailable'
        unavailableReason = 'results-xml-truncated'
        detailCount = 0
        summary = [pscustomobject]@{ total = 5; failed = 1; errors = 0; skipped = 0 }
        results = @()
      } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-failures.json') $fails -Encoding UTF8

      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge
      $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
      $content | Should -Match '\*\*Failure Details:\*\* unavailable'
      $content | Should -Match 'results-xml-truncated'
    }

    It 'surfaces operator outcome in compact mode when present' {
      $outcome = [pscustomobject]@{
        schema = 'pester-operator-outcome@v1'
        gateStatus = 'fail'
        classification = 'unsupported-schema'
        nextAction = 'Regenerate retained artifacts with the supported schema contract or update readers before rerunning the gate.'
      } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-operator-outcome.json') $outcome -Encoding UTF8

      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge
      $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
      $content | Should -Match '\*\*Gate Outcome:\*\* unsupported-schema \(fail\)'
      $content | Should -Match '\*\*Next Action:\*\* Regenerate retained artifacts'
    }
  }

  Context 'All passing compact' {
    BeforeEach {
      $resultsDir = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
      New-Item -ItemType Directory -Path $resultsDir | Out-Null
      $summary = [pscustomobject]@{ total=4; passed=4; failed=0; skipped=0; errors=0; duration=1.1 } | ConvertTo-Json -Depth 6
      Set-Content (Join-Path $resultsDir 'pester-summary.json') $summary -Encoding UTF8
      $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ("PASS_" + [System.Guid]::NewGuid().ToString() + '.md')
    }

    It 'produces passing badge and compact totals' {
      & $ScriptPath -ResultsDir $resultsDir -Compact -EmitFailureBadge
      $c = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
      $c | Should -Match '\*\*✅ All Tests Passed:'
      $c | Should -Match '4 total'
      $c | Should -Not -Match 'Failures:'
    }
  }
}
