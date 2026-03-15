Describe 'Test-SessionIndexV2Contract' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Test-SessionIndexV2Contract.ps1'

    function Get-ScriptFunctionDefinition {
      param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$FunctionName
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

    Invoke-Expression (Get-ScriptFunctionDefinition -ScriptPath $scriptPath -FunctionName 'Get-BurnInDisposition')

    function Write-JsonFile {
      param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
      )

      $Data | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function New-SessionIndexFixture {
      param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedContexts,
        [string[]]$ActualContexts = $ExpectedContexts
      )

      $resultsDir = Join-Path $TestDrive $Name
      New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

      Write-JsonFile -Path (Join-Path $resultsDir 'session-index.json') -Data @{
        schema = 'session-index/v1'
      }

      Write-JsonFile -Path (Join-Path $resultsDir 'session-index-v2.json') -Data @{
        schema = 'session-index/v2'
        schemaVersion = '1.0.0'
        generatedAtUtc = '2026-03-14T00:00:00.000Z'
        run = @{
          workflow = 'Validate'
        }
        branchProtection = @{
          status = 'ok'
          reason = 'aligned'
          expected = @($ExpectedContexts)
          actual = @($ActualContexts)
        }
        artifacts = @(
          @{
            name = 'session-index-v2'
            path = 'session-index-v2.json'
          }
        )
      }

      return $resultsDir
    }

    function Invoke-ContractTool {
      param(
        [Parameter(Mandatory)][string]$ResultsDir,
        [Parameter(Mandatory)][string]$PolicyPath,
        [string]$Branch = 'develop',
        [switch]$Enforce,
        [string]$GitHubOutputPath,
        [string]$GitHubStepSummaryPath,
        [string]$WorkingDirectory = $repoRoot
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $args = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-File', $scriptPath,
        '-ResultsDir', $ResultsDir,
        '-PolicyPath', $PolicyPath,
        '-Branch', $Branch,
        '-Owner', 'example-owner',
        '-Repository', 'example-repo'
      )
      if ($Enforce) {
        $args += '-Enforce'
      }
      foreach ($arg in $args) {
        $psi.ArgumentList.Add([string]$arg) | Out-Null
      }
      $psi.WorkingDirectory = $WorkingDirectory
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

      $ghTokenPrevious = $env:GH_TOKEN
      $githubTokenPrevious = $env:GITHUB_TOKEN
      try {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
      } finally {
        if ($null -eq $ghTokenPrevious) {
          Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        } else {
          $env:GH_TOKEN = $ghTokenPrevious
        }
        if ($null -eq $githubTokenPrevious) {
          Remove-Item Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
        } else {
          $env:GITHUB_TOKEN = $githubTokenPrevious
        }
      }

      return @{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        Report = (Get-Content -LiteralPath (Join-Path $ResultsDir 'session-index-v2-contract.json') -Raw | ConvertFrom-Json -Depth 50)
        Summary = (Get-Content -LiteralPath (Join-Path $ResultsDir 'session-index-v2-disposition.json') -Raw | ConvertFrom-Json -Depth 50)
        Cutover = if (Test-Path -LiteralPath (Join-Path $ResultsDir 'session-index-v2-cutover-readiness.json') -PathType Leaf) {
          Get-Content -LiteralPath (Join-Path $ResultsDir 'session-index-v2-cutover-readiness.json') -Raw | ConvertFrom-Json -Depth 50
        } else {
          $null
        }
        GitHubOutput = if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath) -and (Test-Path -LiteralPath $GitHubOutputPath -PathType Leaf)) {
          Get-Content -LiteralPath $GitHubOutputPath -Raw
        } else {
          ''
        }
        GitHubStepSummary = if (-not [string]::IsNullOrWhiteSpace($GitHubStepSummaryPath) -and (Test-Path -LiteralPath $GitHubStepSummaryPath -PathType Leaf)) {
          Get-Content -LiteralPath $GitHubStepSummaryPath -Raw
        } else {
          ''
        }
      }
    }
  }

  It 'projects required contexts from branch classes when explicit branch lists are absent' {
    $resultsDir = New-SessionIndexFixture -Name 'projected' -ExpectedContexts @('lint', 'session-index')
    $policyPath = Join-Path $TestDrive 'branch-policy.projected.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        develop = 'upstream-integration'
      }
      branchClassRequiredChecks = @{
        'upstream-integration' = @('lint', 'session-index')
      }
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'pass'
    ($run.Report.branchProtection.requiredContexts | Sort-Object) | Should -Be @('lint', 'session-index')
    $run.Report.branchProtection.missingContexts | Should -BeNullOrEmpty
    $run.Report.burnInReceipt.schema | Should -Be 'session-index-v2-burn-in-receipt@v1'
    $run.Report.burnInReceipt.mode | Should -Be 'burn-in'
    $run.Report.burnInReceipt.status | Should -Be 'clean'
    $run.Report.burnInReceipt.mismatchClass | Should -Be 'none'
    $run.Report.burnInReceipt.recurrence.classification | Should -Be 'clean'
    $run.Report.burnInReceipt.evidence.reportPath | Should -Match 'session-index-v2-contract\.json$'
    $run.Report.burnInReceipt.evidence.policyPath | Should -Be $policyPath
    $run.Summary.schema | Should -Be 'session-index-v2-disposition-summary@v1'
    $run.Summary.mode | Should -Be 'burn-in'
    $run.Summary.disposition | Should -Be 'clean-burn-in'
    $run.Summary.promotionReady | Should -BeFalse
    $run.Summary.evidence.contractReportPath | Should -Match 'session-index-v2-contract\.json$'
    $run.Cutover.schema | Should -Be 'session-index-v2-cutover-readiness@v1'
    $run.Cutover.evidence.contractReportPath | Should -Match 'session-index-v2-contract\.json$'
    $run.Cutover.evidence.dispositionReportPath | Should -Match 'session-index-v2-disposition\.json$'
  }

  It 'falls back to explicit branch lists when no branch-class binding exists' {
    $resultsDir = New-SessionIndexFixture -Name 'fallback' -ExpectedContexts @('lint', 'session-index')
    $policyPath = Join-Path $TestDrive 'branch-policy.fallback.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('lint', 'session-index')
      }
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'pass'
    ($run.Report.branchProtection.requiredContexts | Sort-Object) | Should -Be @('lint', 'session-index')
    $run.Report.branchProtection.missingContexts | Should -BeNullOrEmpty
  }

  It 'fails closed in enforce mode when neither branch-class projection nor fallback data exist' {
    $resultsDir = New-SessionIndexFixture -Name 'missing' -ExpectedContexts @('lint')
    $policyPath = Join-Path $TestDrive 'branch-policy.missing.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        main = 'upstream-release'
      }
      branchClassRequiredChecks = @{
        'upstream-release' = @('commit-integrity')
      }
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath -Enforce

    $run.ExitCode | Should -Be 1
    $run.Report.status | Should -Be 'fail'
    $run.Report.failures | Should -Contain "Unable to resolve required contexts from branch policy for branch 'develop'."
    $run.Report.burnInReceipt.mode | Should -Be 'enforce'
    $run.Report.burnInReceipt.status | Should -Be 'mismatch'
    $run.Report.burnInReceipt.mismatchClass | Should -Be 'branch-policy-projection'
    $run.Report.burnInReceipt.recurrence.classification | Should -Be 'unknown'
    $run.Report.burnInReceipt.mismatchFingerprint.Length | Should -Be 64
    $run.Report.burnInReceipt.evidence.sessionIndexV2Path | Should -Match 'session-index-v2\.json$'
    $run.Summary.mode | Should -Be 'enforce'
    $run.Summary.disposition | Should -Be 'promotion-blocking'
    $run.Summary.mismatchClass | Should -Be 'branch-policy-projection'
    $run.Summary.recurrenceClassification | Should -Be 'unknown'
  }

  It 'classifies recurring burn-in mismatches separately from clean and blocking states' {
    (Get-BurnInDisposition -Failures @('mismatch') -Enforce:$false -PromotionReady:$false -RecurrenceClassification 'recurring-or-persistent') | Should -Be 'recurring-burn-in-mismatch'
    (Get-BurnInDisposition -Failures @('mismatch') -Enforce:$false -PromotionReady:$false -RecurrenceClassification 'new-after-success-streak') | Should -Be 'burn-in-mismatch'
    (Get-BurnInDisposition -Failures @() -Enforce:$false -PromotionReady:$true -RecurrenceClassification 'clean') | Should -Be 'promotion-ready'
  }

  It 'classifies missing artifact failures deterministically in the machine-readable report' {
    $resultsDir = New-SessionIndexFixture -Name 'missing-artifact' -ExpectedContexts @('lint', 'session-index')
    Remove-Item -LiteralPath (Join-Path $resultsDir 'session-index-v2.json') -Force
    $policyPath = Join-Path $TestDrive 'branch-policy.missing-artifact.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('lint', 'session-index')
      }
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'fail'
    ($run.Report.failures -join "`n") | Should -Match '^Missing v2 artifact:'
    $run.Report.burnInReceipt.status | Should -Be 'mismatch'
    $run.Report.burnInReceipt.mismatchClass | Should -Be 'missing-artifact'
    $run.Report.burnInReceipt.mismatchFingerprint.Length | Should -Be 64
    $run.Report.burnInReceipt.evidence.sessionIndexV1Path | Should -Match 'session-index\.json$'
    $run.Report.burnInReceipt.evidence.sessionIndexV2Path | Should -Match 'session-index-v2\.json$'
    $run.Summary.disposition | Should -Be 'burn-in-mismatch'
    $run.Summary.mismatchClass | Should -Be 'missing-artifact'
  }

  It 'classifies branch-protection parity mismatches when required contexts are missing from expected contexts' {
    $resultsDir = New-SessionIndexFixture -Name 'missing-required-contexts' -ExpectedContexts @('lint') -ActualContexts @('lint')
    $policyPath = Join-Path $TestDrive 'branch-policy.missing-required-contexts.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('lint', 'session-index')
      }
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'fail'
    $run.Report.failures | Should -Contain 'branchProtection.expected missing required contexts: session-index'
    $run.Report.branchProtection.requiredContexts | Should -Be @('lint', 'session-index')
    $run.Report.branchProtection.missingContexts | Should -Be @('session-index')
    $run.Report.burnInReceipt.status | Should -Be 'mismatch'
    $run.Report.burnInReceipt.mismatchClass | Should -Be 'missing-required-contexts'
    $run.Report.burnInReceipt.mismatchSummary | Should -Contain 'branchProtection.expected missing required contexts: session-index'
    $run.Summary.disposition | Should -Be 'burn-in-mismatch'
    $run.Summary.mismatchClass | Should -Be 'missing-required-contexts'
  }

  It 'writes machine-readable GitHub outputs and summary evidence for non-blocking burn-in mismatches' {
    $resultsDir = New-SessionIndexFixture -Name 'telemetry' -ExpectedContexts @('lint')
    $policyPath = Join-Path $TestDrive 'branch-policy.telemetry.json'
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        main = 'upstream-release'
      }
      branchClassRequiredChecks = @{
        'upstream-release' = @('commit-integrity')
      }
    }
    $githubOutputPath = Join-Path $TestDrive 'session-index-v2-output.txt'
    $githubStepSummaryPath = Join-Path $TestDrive 'session-index-v2-step-summary.md'

    $run = Invoke-ContractTool `
      -ResultsDir $resultsDir `
      -PolicyPath $policyPath `
      -GitHubOutputPath $githubOutputPath `
      -GitHubStepSummaryPath $githubStepSummaryPath

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'fail'
    $run.Summary.disposition | Should -Be 'burn-in-mismatch'
    $run.GitHubOutput | Should -Match 'session-index-v2-status=fail'
    $run.GitHubOutput | Should -Match 'session-index-v2-burn-in-status=mismatch'
    $run.GitHubOutput | Should -Match 'session-index-v2-burn-in-query-status=unavailable'
    $run.GitHubOutput | Should -Match 'session-index-v2-disposition=burn-in-mismatch'
    $run.GitHubOutput | Should -Match 'session-index-v2-mismatch-class=branch-policy-projection'
    $run.GitHubOutput | Should -Match 'session-index-v2-mismatch-fingerprint=[0-9a-f]{64}'
    $run.GitHubOutput | Should -Match 'session-index-v2-recurrence-classification=unknown'
    $run.GitHubOutput | Should -Match 'session-index-v2-promotion-ready=false'
    $run.GitHubOutput | Should -Match 'session-index-v2-contract-report-path=.*session-index-v2-contract\.json'
    $run.GitHubOutput | Should -Match 'session-index-v2-disposition-path=.*session-index-v2-disposition\.json'
    $run.GitHubOutput | Should -Match 'session-index-v2-cutover-status=not-ready'
    $run.GitHubOutput | Should -Match 'session-index-v2-cutover-ready=false'
    $run.GitHubOutput | Should -Match 'session-index-v2-cutover-report-path=.*session-index-v2-cutover-readiness\.json'
    $run.GitHubStepSummary | Should -Match 'Burn-in receipt status: `mismatch`'
    $run.GitHubStepSummary | Should -Match 'Burn-in query status: `unavailable`'
    $run.GitHubStepSummary | Should -Match 'Mismatch class: `branch-policy-projection`'
    $run.GitHubStepSummary | Should -Match 'Mismatch fingerprint: `[0-9a-f]{64}`'
    $run.GitHubStepSummary | Should -Match 'Contract report: `.*session-index-v2-contract\.json`'
    $run.GitHubStepSummary | Should -Match 'Disposition report: `.*session-index-v2-disposition\.json`'
    $run.GitHubStepSummary | Should -Match 'Cutover readiness report: `.*session-index-v2-cutover-readiness\.json`'
    $run.Cutover.schema | Should -Be 'session-index-v2-cutover-readiness@v1'
    $run.Cutover.status | Should -Be 'not-ready'
  }

  It 'regenerates cutover readiness artifacts successfully even when invoked from outside the repo root' {
    $resultsDir = New-SessionIndexFixture -Name 'stale-cutover' -ExpectedContexts @('lint', 'session-index')
    $policyPath = Join-Path $TestDrive 'branch-policy.stale-cutover.json'
    $outsideDir = Join-Path $TestDrive 'outside-workdir'
    New-Item -ItemType Directory -Path $outsideDir -Force | Out-Null
    Write-JsonFile -Path $policyPath -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('lint', 'session-index')
      }
    }

    $staleCutoverPath = Join-Path $resultsDir 'session-index-v2-cutover-readiness.json'
    Write-JsonFile -Path $staleCutoverPath -Data @{
      schema = 'session-index-v2-cutover-readiness@v1'
      generatedAtUtc = '2026-03-15T00:00:00.000Z'
      status = 'ready'
      cutoverReady = $true
    }

    $run = Invoke-ContractTool -ResultsDir $resultsDir -PolicyPath $policyPath -WorkingDirectory $outsideDir

    $run.ExitCode | Should -Be 0
    $run.Report.status | Should -Be 'pass'
    $run.Report.failures | Should -BeNullOrEmpty
    Test-Path -LiteralPath $staleCutoverPath -PathType Leaf | Should -BeTrue
    $run.Cutover.schema | Should -Be 'session-index-v2-cutover-readiness@v1'
    $run.Cutover.status | Should -Be 'not-ready'
    $run.Cutover.cutoverReady | Should -BeFalse
  }
}
