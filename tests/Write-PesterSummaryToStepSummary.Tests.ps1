Describe 'Write-PesterSummaryToStepSummary script' -Tag 'Unit' {
  BeforeAll {
  $scriptPath = Join-Path (Join-Path $PSScriptRoot '..') 'scripts/Write-PesterSummaryToStepSummary.ps1'
    $resultsDir = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Path $resultsDir | Out-Null
    # Minimal summary JSON
    $summary = [pscustomobject]@{
      total = 3; passed = 2; failed = 1; errors = 0; skipped = 0; duration = 1.23; executionPack = 'comparevi'
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    # Failures JSON (single failure)
    $fail = [pscustomobject]@{
      results = @([pscustomobject]@{ Name = 'Sample.Test'; result = 'Failed'; Duration = 0.45 })
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $resultsDir 'pester-failures.json') -Value $fail -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY.md'
  }

  It 'writes Markdown summary with metrics and failed test table (details wrapper default)' {
    & $scriptPath -ResultsDir $resultsDir
    Test-Path $env:GITHUB_STEP_SUMMARY | Should -BeTrue
    $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match '## Pester Test Summary'
    $content | Should -Match '\| Metric \| Value \|'
    $content | Should -Match '\| Total \| 3 \|'
    $content | Should -Match '\| Passed \| 2 \|'
    $content | Should -Match '\| Failed \| 1 \|'
    $content | Should -Match '\| Execution Pack \| comparevi \|'
    $content | Should -Match '<details><summary><strong>Failed Tests</strong></summary>'
    $content | Should -Match 'Sample.Test'
    $content | Should -Match '</details>'
  }

  It 'can emit failed tests without collapse when style=None' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_nocollapse.md'
    & $scriptPath -ResultsDir $resultsDir -FailedTestsCollapseStyle None
    $c2 = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $c2 | Should -Match '### Failed Tests'
    $c2 | Should -Match '\| Execution Pack \| comparevi \|'
    $c2 | Should -Not -Match '<details>'
  }

  It 'omits duration column when -IncludeFailedDurations:$false' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_nodurations.md'
    & $scriptPath -ResultsDir $resultsDir -IncludeFailedDurations:$false
    $c3 = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $c3 | Should -Not -Match 'Duration (s)'
    # Table header single column
  $c3 | Should -Match '\| Name \|\r?\n\|------\|'
  }

  It 'emits failure badge line when -EmitFailureBadge' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_badge.md'
    & $scriptPath -ResultsDir $resultsDir -EmitFailureBadge
    (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match '\*\*❌ Tests Failed:\*\* 1 of 3'
  }

  It 'emits explicit unavailable-details note when canonical payload marks failure detail unavailable' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_unavailable.md'
    $summary = [pscustomobject]@{
      total = 3
      passed = 2
      failed = 1
      errors = 0
      skipped = 0
      duration = 1.23
      executionPack = 'comparevi'
      failureDetailsStatus = 'unavailable'
      failureDetailsReason = 'results-xml-truncated'
    } | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    $fail = [pscustomobject]@{
      schema = 'pester-failures@v2'
      schemaVersion = '1.1.0'
      detailStatus = 'unavailable'
      unavailableReason = 'results-xml-truncated'
      detailCount = 0
      summary = [pscustomobject]@{ total = 3; failed = 1; errors = 0; skipped = 0 }
      results = @()
    } | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $resultsDir 'pester-failures.json') -Value $fail -Encoding UTF8

    & $scriptPath -ResultsDir $resultsDir

    $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'Failure details unavailable'
    $content | Should -Match 'results-xml-truncated'
  }

  It 'surfaces operator outcome classification and next action when present' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_outcome.md'
    $summary = [pscustomobject]@{
      schemaVersion = '1.7.1'
      total = 3
      passed = 2
      failed = 1
      errors = 0
      skipped = 0
      duration = 1.23
      executionPack = 'comparevi'
    } | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    $outcome = [pscustomobject]@{
      schema = 'pester-operator-outcome@v1'
      gateStatus = 'fail'
      classification = 'unsupported-schema'
      reasons = @('execution-receipt-unsupported-schema')
      nextAction = 'Regenerate retained artifacts with the supported schema contract or update readers before rerunning the gate.'
    } | ConvertTo-Json -Depth 6
    Set-Content -Path (Join-Path $resultsDir 'pester-operator-outcome.json') -Value $outcome -Encoding UTF8

    & $scriptPath -ResultsDir $resultsDir

    $content = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match '### Operator Outcome'
    $content | Should -Match 'Classification: unsupported-schema'
    $content | Should -Match 'Next action: Regenerate retained artifacts'
  }

  It 'links failed test name when Relative link style selected' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_links.md'
    $summary = [pscustomobject]@{
      total = 3; passed = 2; failed = 1; errors = 0; skipped = 0; duration = 1.23; executionPack = 'comparevi'
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    $fail = [pscustomobject]@{
      results = @([pscustomobject]@{ Name = 'Sample.Test'; result = 'Failed'; Duration = 0.45 })
    } | ConvertTo-Json -Depth 5
    Set-Content -Path (Join-Path $resultsDir 'pester-failures.json') -Value $fail -Encoding UTF8
    & $scriptPath -ResultsDir $resultsDir -FailedTestsLinkStyle Relative
    $c4 = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
    $c4 | Should -Match '\[Sample.Test\]\(tests/Sample.Test.Tests.ps1\)'
  }

  It 'no-ops gracefully when GITHUB_STEP_SUMMARY unset' {
    Remove-Item Env:GITHUB_STEP_SUMMARY -ErrorAction SilentlyContinue
    # Create alternate directory with summary but unset env -> should not throw
    $alt = Join-Path $TestDrive 'alt-results'
    New-Item -ItemType Directory -Path $alt | Out-Null
    Set-Content -Path (Join-Path $alt 'pester-summary.json') -Value '{"total":0,"passed":0,"failed":0}' -Encoding UTF8
  { & $scriptPath -ResultsDir $alt } | Should -Not -Throw
  }

  It 'tolerates array-shaped failures payloads without throwing' {
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'STEP_SUMMARY_array.md'
    Set-Content -Path (Join-Path $resultsDir 'pester-failures.json') -Value '[]' -Encoding UTF8
    { & $scriptPath -ResultsDir $resultsDir } | Should -Not -Throw
    (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) | Should -Match '\| Failed \| 1 \|'
  }
}
