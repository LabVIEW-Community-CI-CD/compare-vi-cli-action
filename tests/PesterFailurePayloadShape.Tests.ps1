Describe 'Pester failure payload shape compatibility' -Tag 'Unit' {
  BeforeAll {
    $writeScript = Join-Path (Join-Path $PSScriptRoot '..') 'tools/Write-PesterTopFailures.ps1'
    $printScript = Join-Path (Join-Path $PSScriptRoot '..') 'tools/Print-PesterTopFailures.ps1'
  }

  It 'Write-PesterTopFailures accepts object results payloads' {
    $resultsDir = Join-Path $TestDrive 'write-object'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = [pscustomobject]@{
      results = @(
        [pscustomobject]@{
          name = 'Object.Shape.Failure'
          result = 'Failed'
          message = 'object payload failure'
        }
      )
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'write-object-summary.md'

    & $writeScript -ResultsDir $resultsDir -Top 5

    $content = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'Object.Shape.Failure'
  }

  It 'Write-PesterTopFailures accepts array payloads' {
    $resultsDir = Join-Path $TestDrive 'write-array'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = @(
      [pscustomobject]@{
        name = 'Array.Shape.Failure'
        result = 'Failed'
        message = 'array payload failure'
      }
    ) | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'write-array-summary.md'

    & $writeScript -ResultsDir $resultsDir -Top 5

    $content = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'Array.Shape.Failure'
  }

  It 'Write-PesterTopFailures reports unavailable details when summary shows failures but payload is empty' {
    $resultsDir = Join-Path $TestDrive 'write-unavailable'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value '[]' -Encoding UTF8
    $summary = [pscustomobject]@{
      total = 4
      passed = 3
      failed = 1
      errors = 0
      resultsXmlStatus = 'truncated-root'
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'write-unavailable-summary.md'

    & $writeScript -ResultsDir $resultsDir -Top 5

    $content = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'failure details unavailable'
    $content | Should -Match 'resultsXmlStatus=truncated-root'
  }

  It 'Write-PesterTopFailures prefers explicit unavailable-detail reason from canonical payload' {
    $resultsDir = Join-Path $TestDrive 'write-explicit-unavailable'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = [pscustomobject]@{
      schema = 'pester-failures@v2'
      schemaVersion = '1.1.0'
      detailStatus = 'unavailable'
      unavailableReason = 'failure-payload-unparseable'
      detailCount = 0
      summary = [pscustomobject]@{
        total = 4
        failed = 1
        errors = 0
        skipped = 0
      }
      results = @()
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8
    $summary = [pscustomobject]@{
      total = 4
      passed = 3
      failed = 1
      errors = 0
      failureDetailsStatus = 'unavailable'
      failureDetailsReason = 'failure-payload-unparseable'
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'write-explicit-unavailable-summary.md'

    & $writeScript -ResultsDir $resultsDir -Top 5

    $content = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'reason=failure-payload-unparseable'
  }

  It 'Write-PesterTopFailures appends operator-outcome next action when present' {
    $resultsDir = Join-Path $TestDrive 'write-operator-outcome'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = [pscustomobject]@{
      results = @(
        [pscustomobject]@{
          name = 'Outcome.Linked.Failure'
          result = 'Failed'
          message = 'outcome-linked failure'
        }
      )
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8
    $outcome = [pscustomobject]@{
      schema = 'pester-operator-outcome@v1'
      gateStatus = 'fail'
      classification = 'test-failures'
      nextAction = 'Review pester-failures.json, the top-failures summary, and the failing test names before deciding whether to rerun or fix source.'
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-operator-outcome.json') -Value $outcome -Encoding UTF8
    $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'write-operator-outcome-summary.md'

    & $writeScript -ResultsDir $resultsDir -Top 5

    $content = Get-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Raw
    $content | Should -Match 'gate outcome: test-failures \(fail\)'
    $content | Should -Match 'next action: Review pester-failures.json'
  }

  It 'Print-PesterTopFailures returns items from object results payloads' {
    $resultsDir = Join-Path $TestDrive 'print-object'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = [pscustomobject]@{
      results = @(
        [pscustomobject]@{
          name = 'Object.Print.Failure'
          result = 'Failed'
          message = 'object print failure'
        }
      )
    } | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8

    $items = & $printScript -ResultsDir $resultsDir -Top 5 -ConsoleLevel quiet -PassThru

    @($items).Count | Should -Be 1
    $items[0].name | Should -Be 'Object.Print.Failure'
  }

  It 'Print-PesterTopFailures returns items from array payloads' {
    $resultsDir = Join-Path $TestDrive 'print-array'
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    $payload = @(
      [pscustomobject]@{
        name = 'Array.Print.Failure'
        result = 'Failed'
        message = 'array print failure'
      }
    ) | ConvertTo-Json -Depth 6
    Set-Content -LiteralPath (Join-Path $resultsDir 'pester-failures.json') -Value $payload -Encoding UTF8

    $items = & $printScript -ResultsDir $resultsDir -Top 5 -ConsoleLevel quiet -PassThru

    @($items).Count | Should -Be 1
    $items[0].name | Should -Be 'Array.Print.Failure'
  }
}
