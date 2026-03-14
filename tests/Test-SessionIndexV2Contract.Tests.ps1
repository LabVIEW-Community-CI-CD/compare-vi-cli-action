Describe 'Test-SessionIndexV2Contract' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Test-SessionIndexV2Contract.ps1'

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
        [switch]$Enforce
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
      $psi.WorkingDirectory = $repoRoot
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true

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
  }
}
