Describe 'Write-SessionIndexV2CutoverReadiness' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Write-SessionIndexV2CutoverReadiness.ps1'

    function Write-JsonFile {
      param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
      )

      $Data | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function Write-TextFile {
      param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
      )

      Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
    }

    function New-CutoverFixture {
      param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$PromotionReady,
        [Parameter(Mandatory)][int]$ConsecutiveSuccess,
        [Parameter(Mandatory)][string]$ContractStatus,
        [Parameter(Mandatory)][string]$Disposition,
        [string[]]$RemainingChecklistItems = @('Remove v1 generation from producer paths/workflows.'),
        [object[]]$ConsumerRows = @(
          @{
            Consumer = '.github/actions/session-index-post/action.yml'
            Area = 'CI post-processing summary'
            V2FirstStatus = '`v2-first-ready`'
            V1Fallback = '✅'
            Notes = 'Reads session-index-v2.json first.'
          },
          @{
            Consumer = 'tools/Write-SessionIndexSummary.ps1'
            Area = 'Step summary reporting'
            V2FirstStatus = '`v2-first-ready`'
            V1Fallback = '✅'
            Notes = 'Uses shared reader module.'
          }
        )
      )

      $root = Join-Path $TestDrive $Name
      New-Item -ItemType Directory -Path $root -Force | Out-Null

      $contractPath = Join-Path $root 'session-index-v2-contract.json'
      $dispositionPath = Join-Path $root 'session-index-v2-disposition.json'
      $consumerMatrixPath = Join-Path $root 'SESSION_INDEX_V2_CONSUMER_MATRIX.md'
      $deprecationPath = Join-Path $root 'SESSION_INDEX_V1_DEPRECATION.md'
      $outputPath = Join-Path $root 'session-index-v2-cutover-readiness.json'

      Write-JsonFile -Path $contractPath -Data @{
        schema = 'session-index-v2-contract/v1'
        generatedAtUtc = '2026-03-15T00:00:00.000Z'
        branch = 'develop'
        status = $ContractStatus
        enforce = $false
        failures = if ($ContractStatus -eq 'pass') { @() } else { @('contract mismatch') }
        notes = @()
        branchProtection = @{
          policyPath = 'tools/policy/branch-required-checks.json'
          requiredContexts = @('lint', 'session-index')
          missingContexts = @()
        }
        burnIn = @{
          threshold = 10
          status = 'ok'
          reason = 'aligned'
          consecutiveSuccess = $ConsecutiveSuccess
          inspectedRuns = $ConsecutiveSuccess
          promotionReady = $PromotionReady
        }
        burnInReceipt = @{
          schema = 'session-index-v2-burn-in-receipt@v1'
          mode = 'burn-in'
          status = if ($ContractStatus -eq 'pass') { 'clean' } else { 'mismatch' }
          mismatchClass = if ($ContractStatus -eq 'pass') { 'none' } else { 'missing-required-contexts' }
          mismatchFingerprint = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
          mismatchSummary = if ($ContractStatus -eq 'pass') { @() } else { @('contract mismatch') }
          recurrence = @{
            classification = if ($ContractStatus -eq 'pass') { 'clean' } else { 'unknown' }
            burnInStatus = 'ok'
            consecutiveSuccess = $ConsecutiveSuccess
          }
          evidence = @{
            reportPath = $contractPath
            resultsDir = $root
            sessionIndexV1Path = (Join-Path $root 'session-index.json')
            sessionIndexV2Path = (Join-Path $root 'session-index-v2.json')
            policyPath = 'tools/policy/branch-required-checks.json'
          }
        }
      }

      Write-JsonFile -Path $dispositionPath -Data @{
        schema = 'session-index-v2-disposition-summary@v1'
        generatedAtUtc = '2026-03-15T00:00:00.000Z'
        branch = 'develop'
        mode = 'burn-in'
        disposition = $Disposition
        status = $ContractStatus
        promotionReady = $PromotionReady
        mismatchClass = if ($ContractStatus -eq 'pass') { 'none' } else { 'missing-required-contexts' }
        recurrenceClassification = if ($ContractStatus -eq 'pass') { 'clean' } else { 'unknown' }
        consecutiveSuccess = $ConsecutiveSuccess
        threshold = 10
        evidence = @{
          contractReportPath = $contractPath
          sessionIndexV1Path = (Join-Path $root 'session-index.json')
          sessionIndexV2Path = (Join-Path $root 'session-index-v2.json')
          policyPath = 'tools/policy/branch-required-checks.json'
        }
      }

      $consumerMatrixLines = foreach ($row in $ConsumerRows) {
        "| $($row.Consumer) | $($row.Area) | $($row.V2FirstStatus) | $($row.V1Fallback) | $($row.Notes) |"
      }

      Write-TextFile -Path $consumerMatrixPath -Content @"
# Session Index v2 Consumer Migration Matrix

## Matrix

| Consumer | Area | v2-first status | v1 fallback | Notes |
| --- | --- | --- | --- | --- |
$($consumerMatrixLines -join "`n")

## Burn-in tracking
"@

      $checklistLines = foreach ($item in $RemainingChecklistItems) {
        "- [ ] $item"
      }
      if ($checklistLines.Count -eq 0) {
        $checklistLines = '- [x] Remove v1 generation from producer paths/workflows.'
      }

      Write-TextFile -Path $deprecationPath -Content (@"
# Session Index v1 Deprecation Policy

## Removal checklist
$($checklistLines -join "`n")

## Evidence package required for cutover
"@)

      return @{
        Root = $root
        ContractPath = $contractPath
        DispositionPath = $dispositionPath
        ConsumerMatrixPath = $consumerMatrixPath
        DeprecationPath = $deprecationPath
        OutputPath = $outputPath
      }
    }

    function Invoke-CutoverTool {
      param(
        [Parameter(Mandatory)][hashtable]$Fixture,
        [string]$GitHubOutputPath,
        [string]$GitHubStepSummaryPath
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $args = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File', $scriptPath,
        '-ContractReportPath', $Fixture.ContractPath,
        '-DispositionReportPath', $Fixture.DispositionPath,
        '-ConsumerMatrixPath', $Fixture.ConsumerMatrixPath,
        '-DeprecationPolicyPath', $Fixture.DeprecationPath,
        '-OutputPath', $Fixture.OutputPath
      )
      foreach ($arg in $args) {
        [void]$psi.ArgumentList.Add([string]$arg)
      }
      $psi.WorkingDirectory = $repoRoot
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      [void]$psi.Environment.Remove('GITHUB_OUTPUT')
      [void]$psi.Environment.Remove('GITHUB_STEP_SUMMARY')
      if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
        $psi.Environment['GITHUB_OUTPUT'] = $GitHubOutputPath
      }
      if (-not [string]::IsNullOrWhiteSpace($GitHubStepSummaryPath)) {
        $psi.Environment['GITHUB_STEP_SUMMARY'] = $GitHubStepSummaryPath
      }

      $proc = [System.Diagnostics.Process]::Start($psi)
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()

      return @{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        Report = (Get-Content -LiteralPath $Fixture.OutputPath -Raw | ConvertFrom-Json -Depth 20)
        GitHubOutput = if ($GitHubOutputPath -and (Test-Path -LiteralPath $GitHubOutputPath -PathType Leaf)) {
          Get-Content -LiteralPath $GitHubOutputPath -Raw
        } else {
          ''
        }
        GitHubStepSummary = if ($GitHubStepSummaryPath -and (Test-Path -LiteralPath $GitHubStepSummaryPath -PathType Leaf)) {
          Get-Content -LiteralPath $GitHubStepSummaryPath -Raw
        } else {
          ''
        }
      }
    }
  }

  It 'reports not-ready when promotion or checklist evidence is incomplete' {
    $fixture = New-CutoverFixture -Name 'pending' -PromotionReady:$false -ConsecutiveSuccess 4 -ContractStatus 'pass' -Disposition 'clean-burn-in'
    $outputPath = Join-Path $fixture.Root 'github-output.txt'
    $summaryPath = Join-Path $fixture.Root 'step-summary.md'

    $run = Invoke-CutoverTool -Fixture $fixture -GitHubOutputPath $outputPath -GitHubStepSummaryPath $summaryPath

    $run.ExitCode | Should -Be 0
    $run.Report.schema | Should -Be 'session-index-v2-cutover-readiness@v1'
    $run.Report.status | Should -Be 'not-ready'
    $run.Report.cutoverReady | Should -BeFalse
    $run.Report.consumerRegressionGuard.status | Should -Be 'pending'
    $run.Report.deprecationChecklist.remainingCount | Should -Be 1
    $run.Report.reasons.Count | Should -BeGreaterThan 0
    $run.GitHubOutput | Should -Match 'session-index-v2-cutover-status=not-ready'
    $run.GitHubOutput | Should -Match 'session-index-v2-cutover-ready=false'
    $run.GitHubStepSummary | Should -Match 'Session Index v2 Cutover Readiness'
  }

  It 'reports ready when promotion, regression guard, and checklist are all satisfied' {
    $fixture = New-CutoverFixture -Name 'ready' -PromotionReady:$true -ConsecutiveSuccess 10 -ContractStatus 'pass' -Disposition 'promotion-ready' -RemainingChecklistItems @()

    $run = Invoke-CutoverTool -Fixture $fixture

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'ready'
    $run.Report.cutoverReady | Should -BeTrue
    $run.Report.consumerRegressionGuard.status | Should -Be 'satisfied'
    $run.Report.deprecationChecklist.remainingCount | Should -Be 0
    $run.Report.consumerMatrix.criticalConsumerCount | Should -Be 2
    $run.Report.consumerMatrix.readyConsumerCount | Should -Be 2
    $run.Report.consumerMatrix.allV2FirstReady | Should -BeTrue
    $run.Report.consumerMatrix.notReadyConsumers | Should -BeNullOrEmpty
    $run.Report.reasons | Should -BeNullOrEmpty
  }

  It 'blocks the regression guard when the current contract report is failing' {
    $fixture = New-CutoverFixture -Name 'blocked' -PromotionReady:$false -ConsecutiveSuccess 3 -ContractStatus 'fail' -Disposition 'burn-in-mismatch'

    $run = Invoke-CutoverTool -Fixture $fixture

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'not-ready'
    $run.Report.consumerRegressionGuard.status | Should -Be 'blocked'
    $run.Report.consumerRegressionGuard.reason | Should -Match 'blocked'
  }

  It 'reports not-ready when a consumer uses a near-match instead of the explicit v2-first-ready marker' {
    $fixture = New-CutoverFixture -Name 'consumer-not-ready' -PromotionReady:$true -ConsecutiveSuccess 10 -ContractStatus 'pass' -Disposition 'promotion-ready' -RemainingChecklistItems @() -ConsumerRows @(
      @{
        Consumer = '.github/actions/session-index-post/action.yml'
        Area = 'CI post-processing summary'
        V2FirstStatus = '`v2-first-ready`'
        V1Fallback = '✅'
        Notes = 'Reads session-index-v2.json first.'
      },
      @{
        Consumer = 'tools/Write-SessionIndexSummary.ps1'
        Area = 'Step summary reporting'
        V2FirstStatus = 'v2-first ready'
        V1Fallback = '✅'
        Notes = 'Near-match token is not enough for cutover.'
      }
    )

    $run = Invoke-CutoverTool -Fixture $fixture

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'not-ready'
    $run.Report.cutoverReady | Should -BeFalse
    $run.Report.consumerMatrix.criticalConsumerCount | Should -Be 2
    $run.Report.consumerMatrix.readyConsumerCount | Should -Be 1
    $run.Report.consumerMatrix.allV2FirstReady | Should -BeFalse
    $run.Report.consumerMatrix.notReadyConsumers | Should -Contain 'tools/Write-SessionIndexSummary.ps1'
    ($run.Report.reasons -join "`n") | Should -Match 'not marked v2-first'
  }

  It 'reports not-ready when a consumer uses a case-variant instead of the exact v2-first-ready token' {
    $fixture = New-CutoverFixture -Name 'consumer-case-variant' -PromotionReady:$true -ConsecutiveSuccess 10 -ContractStatus 'pass' -Disposition 'promotion-ready' -RemainingChecklistItems @() -ConsumerRows @(
      @{
        Consumer = '.github/actions/session-index-post/action.yml'
        Area = 'CI post-processing summary'
        V2FirstStatus = '`v2-first-ready`'
        V1Fallback = '✅'
        Notes = 'Reads session-index-v2.json first.'
      },
      @{
        Consumer = 'tools/Write-SessionIndexSummary.ps1'
        Area = 'Step summary reporting'
        V2FirstStatus = '`V2-FIRST-READY`'
        V1Fallback = '✅'
        Notes = 'Case-variant token is not enough for cutover.'
      }
    )

    $run = Invoke-CutoverTool -Fixture $fixture

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'not-ready'
    $run.Report.cutoverReady | Should -BeFalse
    $run.Report.consumerMatrix.readyConsumerCount | Should -Be 1
    $run.Report.consumerMatrix.notReadyConsumers | Should -Contain 'tools/Write-SessionIndexSummary.ps1'
  }
}
