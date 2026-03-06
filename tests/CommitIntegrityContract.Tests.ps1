Describe 'Commit integrity contract' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Assert-CommitIntegrityContract.ps1'

    function Invoke-ContractScript {
      param(
        [Parameter(Mandatory)][string]$WorkflowPath,
        [Parameter(Mandatory)][string]$BranchPolicyPath,
        [Parameter(Mandatory)][string]$PriorityPolicyPath,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$RuntimeScriptPath
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File "{0}" -WorkflowPath "{1}" -BranchRequiredChecksPath "{2}" -PriorityPolicyPath "{3}" -PolicyPath "{4}" -SchemaPath "{5}" -RuntimeScriptPath "{6}"' -f $scriptPath, $WorkflowPath, $BranchPolicyPath, $PriorityPolicyPath, $PolicyPath, $SchemaPath, $RuntimeScriptPath)
      $psi.WorkingDirectory = $repoRoot
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true

      $proc = [System.Diagnostics.Process]::Start($psi)
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      $proc.WaitForExit()

      return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
      }
    }

    function Write-JsonFile {
      param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Data
      )
      $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
    }
  }

  It 'passes against repository contract files' {
    $workflowPath = Join-Path $repoRoot '.github/workflows/commit-integrity.yml'
    $branchPolicyPath = Join-Path $repoRoot 'tools/policy/branch-required-checks.json'
    $priorityPolicyPath = Join-Path $repoRoot 'tools/priority/policy.json'
    $policyPath = Join-Path $repoRoot 'tools/policy/commit-integrity-policy.json'
    $schemaPath = Join-Path $repoRoot 'docs/schemas/commit-integrity-report-v1.schema.json'
    $runtimeScriptPath = Join-Path $repoRoot 'tools/priority/commit-integrity.mjs'

    $run = Invoke-ContractScript -WorkflowPath $workflowPath -BranchPolicyPath $branchPolicyPath -PriorityPolicyPath $priorityPolicyPath -PolicyPath $policyPath -SchemaPath $schemaPath -RuntimeScriptPath $runtimeScriptPath
    $run.ExitCode | Should -Be 0
    ($run.StdOut + $run.StdErr) | Should -Match 'commit-integrity-contract'
  }

  It 'fails when observed check contract drifts' {
    $tmpWorkflow = Join-Path $TestDrive 'commit-integrity.yml'
    $tmpBranchPolicy = Join-Path $TestDrive 'branch-required-checks.json'
    $tmpPriorityPolicy = Join-Path $TestDrive 'policy.json'
    $tmpPolicy = Join-Path $TestDrive 'commit-integrity-policy.json'
    $tmpSchema = Join-Path $TestDrive 'commit-integrity-report-v1.schema.json'
    $tmpRuntime = Join-Path $TestDrive 'commit-integrity.mjs'

    @'
name: commit-integrity
on:
  workflow_dispatch:
jobs:
  commit-integrity:
    name: commit-integrity
    runs-on: ubuntu-latest
    steps:
      - run: echo noop
'@ | Set-Content -LiteralPath $tmpWorkflow -Encoding utf8

    Write-JsonFile -Path $tmpBranchPolicy -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('lint')
        main = @('lint')
      }
      observed = @{
        develop = @('wrong-check')
        main = @('wrong-check')
      }
    }

    Write-JsonFile -Path $tmpPriorityPolicy -Data @{
      branches = @{
        develop = @{ observed_status_checks = @('wrong-check') }
        main = @{ observed_status_checks = @('wrong-check') }
      }
      rulesets = @{
        '8811898' = @{ observed_status_checks = @('wrong-check') }
        '8614140' = @{ observed_status_checks = @('wrong-check') }
      }
    }

    Write-JsonFile -Path $tmpPolicy -Data @{
      schema = 'commit-integrity-policy/v1'
      source_resolution = @{ bot_login_patterns = @('\[bot\]$') }
      verification = @{ fail_on_unverified = $true }
      checks = @{
        require_author_attribution = $true
        require_committer_attribution = $true
        require_non_unknown_reason_for_unverified = $true
      }
    }
    '{}' | Set-Content -LiteralPath $tmpSchema -Encoding utf8
    'export {}' | Set-Content -LiteralPath $tmpRuntime -Encoding utf8

    $run = Invoke-ContractScript -WorkflowPath $tmpWorkflow -BranchPolicyPath $tmpBranchPolicy -PriorityPolicyPath $tmpPriorityPolicy -PolicyPath $tmpPolicy -SchemaPath $tmpSchema -RuntimeScriptPath $tmpRuntime
    $run.ExitCode | Should -Be 1
    ($run.StdOut + $run.StdErr) | Should -Match 'expected report path|Observed branch checks'
  }
}
