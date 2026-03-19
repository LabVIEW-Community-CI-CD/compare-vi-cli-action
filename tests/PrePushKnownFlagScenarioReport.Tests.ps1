#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Pre-push known-flag scenario pack report' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:PrePushScriptPath = Join-Path $repoRoot 'tools' 'PrePush-Checks.ps1'
    $script:KnownFlagContractPath = Join-Path $repoRoot 'tools' 'policy' 'prepush-known-flag-scenarios.json'

    if (-not (Test-Path -LiteralPath $script:PrePushScriptPath -PathType Leaf)) {
      throw "PrePush-Checks.ps1 not found at $script:PrePushScriptPath"
    }
    if (-not (Test-Path -LiteralPath $script:KnownFlagContractPath -PathType Leaf)) {
      throw "Known-flag scenario contract not found at $script:KnownFlagContractPath"
    }

    function script:Get-ScriptFunctionDefinition {
      param(
        [string]$ScriptPath,
        [string]$FunctionName
      )

      $tokens = $null
      $parseErrors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
      if ($parseErrors.Count -gt 0) {
        throw ("Failed to parse {0}: {1}" -f $ScriptPath, ($parseErrors | ForEach-Object { $_.Message } | Join-String -Separator '; '))
      }

      $functionAst = $ast.Find(
        {
          param($node)
          $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -eq $FunctionName
        },
        $true
      )
      if ($null -eq $functionAst) {
        throw ("Function {0} not found in {1}" -f $FunctionName, $ScriptPath)
      }

      return $functionAst.Extent.Text
    }

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Resolve-PrePushKnownFlagScenarioPack')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Write-PrePushKnownFlagScenarioReport')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Write-PrePushSupportLaneReport')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Get-PrePushKnownFlagScenarioSemanticEvidence')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Test-PrePushKnownFlagReviewerAssertion')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'Test-PrePushKnownFlagRawModeBoundary')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'New-PrePushTransportMatrixScenarios')
    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $script:PrePushScriptPath -FunctionName 'ConvertTo-PrePushKnownFlagScenarioResultArray')

    $script:KnownFlagContract = Get-Content -LiteralPath $script:KnownFlagContractPath -Raw | ConvertFrom-Json -Depth 20
    $script:ActiveScenarioPack = @($script:KnownFlagContract.scenarioPacks | Where-Object { $_.isActive -eq $true }) | Select-Object -First 1
    if ($null -eq $script:ActiveScenarioPack) {
      throw 'Active known-flag scenario pack not found in contract.'
    }
  }

  It 'resolves the active scenario pack and preserves declared scenario order without generating flag combinations' {
    $resolved = Resolve-PrePushKnownFlagScenarioPack -repoRoot (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    $resolved.pack.id | Should -Be $script:KnownFlagContract.activeScenarioPackId
    $resolved.pack.image | Should -Be 'nationalinstruments/labview:2026q1-linux'
    $resolved.pack.priorityClass | Should -Be 'pre-push'
    @($resolved.pack.planeApplicability) | Should -Be @('linux-proof')
    $resolved.baseVi | Should -Match '[\\/]VI1\.vi$'
    $resolved.headVi | Should -Match '[\\/]VI2\.vi$'
    @($resolved.scenarios | ForEach-Object { $_.id }) | Should -Be @(
      'baseline-review-surface',
      'attribute-suppression-boundary',
      'front-panel-position-boundary',
      'block-diagram-cosmetic-boundary'
    )
    @($resolved.scenarios[0].requestedFlags) | Should -Be @()
    @($resolved.scenarios[1].requestedFlags) | Should -Be @('-noattr')
    @($resolved.scenarios[2].requestedFlags) | Should -Be @('-nofppos')
    @($resolved.scenarios[3].requestedFlags) | Should -Be @('-nobdcosm')
  }

  It 'derives the transport smoke matrix from the unique declared requested flags' {
    $transportMatrixScenarios = New-PrePushTransportMatrixScenarios -scenarioDefinitions @(
      [pscustomobject]@{ requestedFlags = @() },
      [pscustomobject]@{ requestedFlags = @('-noattr') },
      [pscustomobject]@{ requestedFlags = @('-nofppos') },
      [pscustomobject]@{ requestedFlags = @('-nobdcosm') }
    )

    @($transportMatrixScenarios | ForEach-Object { $_.name }) | Should -Be @(
      'baseline',
      'noattr',
      'nofppos',
      'nobdcosm',
      'noattr__nofppos',
      'noattr__nobdcosm',
      'nofppos__nobdcosm',
      'noattr__nofppos__nobdcosm'
    )
  }

  It 'parses rendered semantic evidence from the inclusion list and headings' {
    $reportPath = Join-Path $TestDrive 'compare-report.html'
    @'
<html>
  <body>
    <ul>
      <li class="checked">Front Panel</li>
      <li class="checked">Front Panel Position/Size</li>
      <li class="checked">Block Diagram Functional</li>
      <li class="checked">Block Diagram Cosmetic</li>
      <li class="unchecked">VI Attribute</li>
    </ul>
    <details><summary class="difference-heading">1. Front Panel - Panel</summary></details>
    <details><summary class="difference-heading">2. Front Panel objects</summary></details>
  </body>
</html>
'@ | Set-Content -LiteralPath $reportPath -Encoding utf8

    $evidence = Get-PrePushKnownFlagScenarioSemanticEvidence -ReportPath $reportPath

    $evidence.inclusionCount | Should -Be 5
    $evidence.headingCount | Should -Be 2
    $evidence.trackedCategories.'Front Panel' | Should -BeTrue
    $evidence.trackedCategories.'Front Panel Position/Size' | Should -BeTrue
    $evidence.trackedCategories.'Block Diagram Cosmetic' | Should -BeTrue
    $evidence.trackedCategories.'VI Attribute' | Should -BeFalse
    @($evidence.headingTexts) | Should -Contain 'Front Panel - Panel'
    @($evidence.headingTexts) | Should -Contain 'Front Panel objects'
  }

  It 'evaluates reviewer assertions and raw boundaries from rendered semantics instead of broad heading absence' {
    $semanticEvidence = [pscustomobject]@{
      reportPath = 'compare-report.html'
      inclusionStates = [pscustomobject]@{
        'Front Panel' = $true
        'Front Panel Position/Size' = $false
        'Block Diagram Functional' = $true
        'Block Diagram Cosmetic' = $true
        'VI Attribute' = $true
      }
      trackedCategories = [pscustomobject]@{
        'Front Panel' = $true
        'Front Panel Position/Size' = $false
        'Block Diagram Functional' = $true
        'Block Diagram Cosmetic' = $true
        'VI Attribute' = $true
      }
      headingTexts = @(
        'Front Panel - Panel',
        'Front Panel objects'
      )
      inclusionCount = 5
      headingCount = 2
    }

    $reviewerResult = Test-PrePushKnownFlagReviewerAssertion `
      -Assertion ([pscustomobject]@{
        id = 'raw-boundary-explicit'
        surface = 'compare-report.html'
        requirement = 'front-panel-position-boundary-visible'
      }) `
      -RequestedFlags @('-nofppos') `
      -ObservedFlags @('-nofppos', '-Headless') `
      -SemanticEvidence $semanticEvidence

    $rawBoundaryResult = Test-PrePushKnownFlagRawModeBoundary `
      -Boundary ([pscustomobject]@{
        id = 'front-panel-position-raw-mode-boundary'
        mode = 'compare-report'
        surfaceRole = 'raw-mode-boundary'
        expectation = 'front-panel-position-size-suppressed'
      }) `
      -SemanticEvidence $semanticEvidence

    $reviewerResult.passed | Should -BeTrue
    $reviewerResult.details | Should -Match 'Front Panel Position/Size checked=False'
    $rawBoundaryResult.passed | Should -BeTrue
    $rawBoundaryResult.details | Should -Match 'Front Panel Position/Size checked=False'
  }

  It 'writes a deterministic report that mirrors the active scenario pack contract and declared semantic expectations' {
    $repoRoot = Join-Path $TestDrive 'non-git-repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'pre-push-ni-image'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $contract = [pscustomobject]@{
      path = $script:KnownFlagContractPath
      pack = $script:ActiveScenarioPack
      scenarios = @(
        [pscustomobject]@{
          id = 'baseline-review-surface'
          description = 'Full-surface baseline.'
          requestedFlags = @()
          requestedFlagsLabel = '(none)'
          planeApplicability = @('linux-proof')
          priorityClass = 'pre-push'
          intendedSuppressionSemantics = [pscustomobject]@{
            suppressedCategories = @()
            reviewerSurfaceIntent = 'full-review-surface'
            rawModeBoundaryIntent = 'primary-review-surface'
          }
          expectedReviewerAssertions = @(
            [pscustomobject]@{
              id = 'compare-report-rendered'
              surface = 'compare-report.html'
              requirement = 'rendered'
            }
          )
          expectedRawModeEvidenceBoundaries = @(
            [pscustomobject]@{
              id = 'baseline-raw-mode-boundary'
              mode = 'compare-report'
              surfaceRole = 'reviewer-primary'
              expectation = 'full-surface'
            }
          )
        }
      )
      reportPath = Join-Path $resultsRoot 'known-flag-scenario-report.json'
    }

    $scenarioResults = @(
      [pscustomobject]@{
        name = 'baseline-review-surface'
        description = 'Full-surface baseline.'
        requestedFlags = @()
        flags = @('-Headless')
        planeApplicability = @('linux-proof')
        priorityClass = 'pre-push'
        intendedSuppressionSemantics = [pscustomobject]@{
          suppressedCategories = @()
          reviewerSurfaceIntent = 'full-review-surface'
          rawModeBoundaryIntent = 'primary-review-surface'
        }
        expectedReviewerAssertions = @(
          [pscustomobject]@{
            id = 'compare-report-rendered'
            surface = 'compare-report.html'
            requirement = 'rendered'
          }
        )
        expectedRawModeEvidenceBoundaries = @(
          [pscustomobject]@{
            id = 'baseline-raw-mode-boundary'
            mode = 'compare-report'
            surfaceRole = 'reviewer-primary'
            expectation = 'full-surface'
          }
        )
        reviewerAssertionResults = @(
          [pscustomobject]@{
            id = 'compare-report-rendered'
            surface = 'compare-report.html'
            requirement = 'rendered'
            passed = $true
            details = 'inclusionCount=5; headingCount=3'
          }
        )
        rawModeBoundaryResults = @(
          [pscustomobject]@{
            id = 'baseline-raw-mode-boundary'
            mode = 'compare-report'
            surfaceRole = 'reviewer-primary'
            expectation = 'full-surface'
            passed = $true
            details = 'trackedCategories={...}'
          }
        )
        semanticEvidence = [pscustomobject]@{
          reportPath = 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/report.html'
          inclusionStates = [pscustomobject]@{
            'Front Panel' = $true
            'Front Panel Position/Size' = $true
            'Block Diagram Functional' = $true
            'Block Diagram Cosmetic' = $true
            'VI Attribute' = $true
          }
          trackedCategories = [pscustomobject]@{
            'Front Panel' = $true
            'Front Panel Position/Size' = $true
            'Block Diagram Functional' = $true
            'Block Diagram Cosmetic' = $true
            'VI Attribute' = $true
          }
          headingTexts = @('Block Diagram objects', 'Front Panel objects', 'VI Attribute - Miscellaneous')
          inclusionCount = 5
          headingCount = 3
        }
        semanticGateOutcome = 'pass'
        resultClass = 'pass'
        gateOutcome = 'pass'
        capturePath = 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/capture.json'
        reportPath = 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/report.html'
      }
    )

    $reportPath = Write-PrePushKnownFlagScenarioReport `
      -repoRoot $repoRoot `
      -contract $contract `
      -observedOutcome 'pass' `
      -scenarioResults $scenarioResults `
      -failureMessage '' `
      -activeScenarioName 'baseline-review-surface' `
      -activeCapturePath 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/capture.json' `
      -activeReportPath 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/report.html'

    $reportPath | Should -Be $contract.reportPath
    Test-Path -LiteralPath $reportPath | Should -BeTrue

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 24
    $report.schema | Should -Be 'pre-push-known-flag-scenario-pack-report@v1'
    $report.contractPath | Should -Be $script:KnownFlagContractPath
    $report.branch | Should -BeNullOrEmpty
    $report.headSha | Should -BeNullOrEmpty
    $report.scenarioPack.id | Should -Be $script:KnownFlagContract.activeScenarioPackId
    $report.scenarioPack.image | Should -Be $script:ActiveScenarioPack.image
    $report.scenarioPack.labviewPathEnv | Should -Be $script:ActiveScenarioPack.labviewPathEnv
    $report.scenarioPack.defaultLabviewPath | Should -Be $script:ActiveScenarioPack.defaultLabviewPath
    @($report.scenarioPack.planeApplicability) | Should -Be @('linux-proof')
    $report.scenarioPack.priorityClass | Should -Be 'pre-push'
    $report.scenarioPack.target.kind | Should -Be 'fixture-diff'
    $report.scenarioPack.target.baseVi | Should -Be 'VI1.vi'
    $report.scenarioPack.target.headVi | Should -Be 'VI2.vi'
    $report.observed.outcome | Should -Be 'pass'
    $report.observed.activeScenarioId | Should -Be 'baseline-review-surface'
    $report.observed.capturePath | Should -Be 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/capture.json'
    $report.observed.reportPath | Should -Be 'tests/results/_agent/pre-push-ni-image/baseline-review-surface/report.html'
    $report.results.Count | Should -Be 1
    $report.results[0].name | Should -Be 'baseline-review-surface'
    $report.results[0].description | Should -Be 'Full-surface baseline.'
    @($report.results[0].planeApplicability) | Should -Be @('linux-proof')
    $report.results[0].priorityClass | Should -Be 'pre-push'
    @($report.results[0].intendedSuppressionSemantics.suppressedCategories) | Should -Be @()
    $report.results[0].intendedSuppressionSemantics.reviewerSurfaceIntent | Should -Be 'full-review-surface'
    $report.results[0].expectedReviewerAssertions[0].id | Should -Be 'compare-report-rendered'
    $report.results[0].expectedRawModeEvidenceBoundaries[0].expectation | Should -Be 'full-surface'
    $report.results[0].reviewerAssertionResults[0].passed | Should -BeTrue
    $report.results[0].rawModeBoundaryResults[0].passed | Should -BeTrue
    $report.results[0].semanticEvidence.inclusionCount | Should -Be 5
    $report.results[0].semanticGateOutcome | Should -Be 'pass'
  }

  It 'writes failure outcome and active scenario id without depending on a git checkout' {
    $repoRoot = Join-Path $TestDrive 'non-git-failure-repo'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'pre-push-ni-image'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $contract = [pscustomobject]@{
      path = $script:KnownFlagContractPath
      pack = $script:ActiveScenarioPack
      scenarios = @()
      reportPath = Join-Path $resultsRoot 'known-flag-scenario-report.json'
    }

    $reportPath = Write-PrePushKnownFlagScenarioReport `
      -repoRoot $repoRoot `
      -contract $contract `
      -observedOutcome 'fail' `
      -scenarioResults @() `
      -failureMessage 'scenario pack failed' `
      -activeScenarioName 'attribute-suppression-boundary' `
      -activeCapturePath 'tests/results/_agent/pre-push-ni-image/attribute-suppression-boundary/capture.json' `
      -activeReportPath 'tests/results/_agent/pre-push-ni-image/attribute-suppression-boundary/report.html'

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 24
    $report.observed.outcome | Should -Be 'fail'
    $report.observed.failureMessage | Should -Be 'scenario pack failed'
    $report.observed.activeScenarioId | Should -Be 'attribute-suppression-boundary'
    $report.results.Count | Should -Be 0
  }

  It 'normalizes live scenario results into semantic report records' {
    $scenarioResults = [System.Collections.Generic.List[object]]::new()
    $scenarioResults.Add([pscustomobject]@{
      name = 'attribute-suppression-boundary'
      description = 'Attribute suppression boundary.'
      requestedFlags = @('-noattr')
      flags = @('-Headless', '-noattr')
      planeApplicability = @('linux-proof')
      priorityClass = 'pre-push'
      intendedSuppressionSemantics = [pscustomobject]@{
        suppressedCategories = @('vi-attributes')
        reviewerSurfaceIntent = 'attribute-boundary'
        rawModeBoundaryIntent = 'raw-report-suppresses-vi-attributes'
      }
      expectedReviewerAssertions = @(
        [pscustomobject]@{
          id = 'raw-boundary-explicit'
          surface = 'compare-report.html'
          requirement = 'attribute-suppression-boundary-visible'
        }
      )
      expectedRawModeEvidenceBoundaries = @(
        [pscustomobject]@{
          id = 'attribute-raw-mode-boundary'
          mode = 'compare-report'
          surfaceRole = 'raw-mode-boundary'
          expectation = 'vi-attributes-suppressed'
        }
      )
      reviewerAssertionResults = @(
        [pscustomobject]@{
          id = 'raw-boundary-explicit'
          surface = 'compare-report.html'
          requirement = 'attribute-suppression-boundary-visible'
          passed = $true
          details = 'VI Attribute checked=False'
        }
      )
      rawModeBoundaryResults = @(
        [pscustomobject]@{
          id = 'attribute-raw-mode-boundary'
          mode = 'compare-report'
          surfaceRole = 'raw-mode-boundary'
          expectation = 'vi-attributes-suppressed'
          passed = $true
          details = 'VI Attribute checked=False'
        }
      )
      semanticEvidence = [pscustomobject]@{
        reportPath = 'tests/results/_agent/pre-push-ni-image/attribute-suppression-boundary/compare-report.html'
        inclusionStates = [pscustomobject]@{
          'Front Panel' = $true
          'Front Panel Position/Size' = $true
          'Block Diagram Functional' = $true
          'Block Diagram Cosmetic' = $true
          'VI Attribute' = $false
        }
        trackedCategories = [pscustomobject]@{
          'Front Panel' = $true
          'Front Panel Position/Size' = $true
          'Block Diagram Functional' = $true
          'Block Diagram Cosmetic' = $true
          'VI Attribute' = $false
        }
        headingTexts = @('Front Panel - Panel', 'Front Panel objects')
        inclusionCount = 5
        headingCount = 2
      }
      semanticGateOutcome = 'pass'
      resultClass = 'diff'
      gateOutcome = 'pass'
      capturePath = 'tests/results/_agent/pre-push-ni-image/attribute-suppression-boundary/ni-linux-container-capture.json'
      reportPath = 'tests/results/_agent/pre-push-ni-image/attribute-suppression-boundary/compare-report.html'
    }) | Out-Null

    $normalized = ConvertTo-PrePushKnownFlagScenarioResultArray -scenarioResults $scenarioResults

    $normalized.Count | Should -Be 1
    $normalized[0].name | Should -Be 'attribute-suppression-boundary'
    $normalized[0].description | Should -Be 'Attribute suppression boundary.'
    @($normalized[0].requestedFlags) | Should -Be @('-noattr')
    @($normalized[0].flags) | Should -Be @('-Headless', '-noattr')
    @($normalized[0].planeApplicability) | Should -Be @('linux-proof')
    $normalized[0].priorityClass | Should -Be 'pre-push'
    @($normalized[0].intendedSuppressionSemantics.suppressedCategories) | Should -Be @('vi-attributes')
    $normalized[0].expectedReviewerAssertions[0].requirement | Should -Be 'attribute-suppression-boundary-visible'
    $normalized[0].expectedRawModeEvidenceBoundaries[0].expectation | Should -Be 'vi-attributes-suppressed'
    $normalized[0].reviewerAssertionResults[0].passed | Should -BeTrue
    $normalized[0].rawModeBoundaryResults[0].passed | Should -BeTrue
    $normalized[0].semanticEvidence.trackedCategories.'VI Attribute' | Should -BeFalse
    $normalized[0].semanticGateOutcome | Should -Be 'pass'
  }

  It 'writes deterministic support-lane reports for transport and vi-history smoke lanes' {
    $repoRoot = Join-Path $TestDrive 'non-git-support-lanes'
    $resultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'pre-push-ni-image'
    New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null

    $transportPath = Join-Path $resultsRoot 'transport-smoke-report.json'
    $transportResults = @(
      [pscustomobject]@{
        name = 'single-container-matrix'
        description = 'Transport smoke.'
        requestedFlags = @('all combinations')
        flags = @('-Headless')
        planeApplicability = @('linux-proof')
        priorityClass = 'certification'
        intendedSuppressionSemantics = [pscustomobject]@{
          suppressedCategories = @()
          reviewerSurfaceIntent = 'transport-smoke'
          rawModeBoundaryIntent = 'transport-only'
        }
        expectedReviewerAssertions = @()
        expectedRawModeEvidenceBoundaries = @()
        resultClass = 'diff'
        gateOutcome = 'pass'
        capturePath = 'tests/results/_agent/pre-push-ni-image/single-container-matrix/ni-linux-container-capture.json'
        reportPath = 'tests/results/_agent/pre-push-ni-image/single-container-matrix/compare-report.html'
      }
    )

    $reportPath = Write-PrePushSupportLaneReport `
      -repoRoot $repoRoot `
      -reportPath $transportPath `
      -schema 'pre-push-ni-transport-smoke-report@v1' `
      -laneName 'single-container-matrix' `
      -description 'Transport smoke.' `
      -observedOutcome 'pass' `
      -scenarioResults $transportResults `
      -failureMessage '' `
      -capturePath 'tests/results/_agent/pre-push-ni-image/single-container-matrix/ni-linux-container-capture.json' `
      -reportArtifactPath 'tests/results/_agent/pre-push-ni-image/single-container-matrix/compare-report.html'

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 16
    $report.schema | Should -Be 'pre-push-ni-transport-smoke-report@v1'
    $report.lane.name | Should -Be 'single-container-matrix'
    $report.observed.outcome | Should -Be 'pass'
    $report.results.Count | Should -Be 1
    $report.results[0].name | Should -Be 'single-container-matrix'
  }
}
