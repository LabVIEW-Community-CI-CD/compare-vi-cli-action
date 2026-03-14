Describe 'Requirements verification check naming contract' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Assert-RequirementsVerificationCheckContract.ps1'

    function Invoke-ContractScript {
      param(
        [Parameter(Mandatory)][string]$WorkflowPath,
        [Parameter(Mandatory)][string]$BranchPolicyPath,
        [Parameter(Mandatory)][string]$PriorityPolicyPath
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File "{0}" -WorkflowPath "{1}" -BranchRequiredChecksPath "{2}" -PriorityPolicyPath "{3}"' -f $scriptPath, $WorkflowPath, $BranchPolicyPath, $PriorityPolicyPath)
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
      $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
    }
  }

  It 'passes against repository contract files' {
    $workflowPath = Join-Path $repoRoot '.github/workflows/verification.yml'
    $branchPolicyPath = Join-Path $repoRoot 'tools/policy/branch-required-checks.json'
    $priorityPolicyPath = Join-Path $repoRoot 'tools/priority/policy.json'

    $run = Invoke-ContractScript -WorkflowPath $workflowPath -BranchPolicyPath $branchPolicyPath -PriorityPolicyPath $priorityPolicyPath
    $run.ExitCode | Should -Be 0
    ($run.StdOut + $run.StdErr) | Should -Match 'verification-check-contract'
  }

  It 'fails when workflow job name drifts from required check context' {
    $tmpWorkflow = Join-Path $TestDrive 'verification.yml'
    $tmpBranchPolicy = Join-Path $TestDrive 'branch-required-checks.json'
    $tmpPriorityPolicy = Join-Path $TestDrive 'policy.json'

    @'
name: Requirements Verification
on:
  workflow_dispatch:
jobs:
  verification:
    name: verification-renamed
    runs-on: ubuntu-latest
'@ | Set-Content -LiteralPath $tmpWorkflow -Encoding utf8

    Write-JsonFile -Path $tmpBranchPolicy -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branches = @{
        develop = @('Requirements Verification / requirements-verification')
      }
    }

    Write-JsonFile -Path $tmpPriorityPolicy -Data @{
      branches = @{
        develop = @{
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
      rulesets = @{
        develop = @{
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
    }

    $run = Invoke-ContractScript -WorkflowPath $tmpWorkflow -BranchPolicyPath $tmpBranchPolicy -PriorityPolicyPath $tmpPriorityPolicy
    $run.ExitCode | Should -Be 1
    ($run.StdOut + $run.StdErr) | Should -Match 'Workflow job name mismatch'
  }

  It 'passes when branch-class-only policy data resolves the expected check' {
    $tmpWorkflow = Join-Path $TestDrive 'verification.branch-class.yml'
    $tmpBranchPolicy = Join-Path $TestDrive 'branch-required-checks.branch-class.json'
    $tmpPriorityPolicy = Join-Path $TestDrive 'policy.branch-class.json'

    @'
name: Requirements Verification
on:
  workflow_dispatch:
jobs:
  verification:
    name: requirements-verification
    runs-on: ubuntu-latest
'@ | Set-Content -LiteralPath $tmpWorkflow -Encoding utf8

    Write-JsonFile -Path $tmpBranchPolicy -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        develop = 'upstream-integration'
      }
      branchClassRequiredChecks = @{
        'upstream-integration' = @('Requirements Verification / requirements-verification')
      }
    }

    Write-JsonFile -Path $tmpPriorityPolicy -Data @{
      branches = @{
        develop = @{
          branch_class_id = 'upstream-integration'
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
      rulesets = @{
        develop = @{
          branch_class_id = 'upstream-integration'
          includes = @('refs/heads/develop')
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
    }

    $run = Invoke-ContractScript -WorkflowPath $tmpWorkflow -BranchPolicyPath $tmpBranchPolicy -PriorityPolicyPath $tmpPriorityPolicy
    $run.ExitCode | Should -Be 0
    ($run.StdOut + $run.StdErr) | Should -Match 'verification-check-contract'
  }

  It 'fails closed when neither branch-class projection nor fallback branch checks resolve the expected check' {
    $tmpWorkflow = Join-Path $TestDrive 'verification.missing.yml'
    $tmpBranchPolicy = Join-Path $TestDrive 'branch-required-checks.missing.json'
    $tmpPriorityPolicy = Join-Path $TestDrive 'policy.missing.json'

    @'
name: Requirements Verification
on:
  workflow_dispatch:
jobs:
  verification:
    name: requirements-verification
    runs-on: ubuntu-latest
'@ | Set-Content -LiteralPath $tmpWorkflow -Encoding utf8

    Write-JsonFile -Path $tmpBranchPolicy -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        main = 'upstream-release'
      }
      branchClassRequiredChecks = @{
        'upstream-release' = @('commit-integrity')
      }
    }

    Write-JsonFile -Path $tmpPriorityPolicy -Data @{
      branches = @{
        develop = @{
          branch_class_id = 'upstream-integration'
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
      rulesets = @{
        develop = @{
          branch_class_id = 'upstream-integration'
          includes = @('refs/heads/develop')
          required_status_checks = @('Requirements Verification / requirements-verification')
        }
      }
    }

    $run = Invoke-ContractScript -WorkflowPath $tmpWorkflow -BranchPolicyPath $tmpBranchPolicy -PriorityPolicyPath $tmpPriorityPolicy
    $run.ExitCode | Should -Be 1
    ($run.StdOut + $run.StdErr) | Should -Match "Missing required checks for branch 'develop'"
  }
}
