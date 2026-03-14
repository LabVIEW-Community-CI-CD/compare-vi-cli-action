Describe 'Promotion contract alignment' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Assert-PromotionContractAlignment.ps1'

    function Invoke-AlignmentScript {
      param(
        [Parameter(Mandatory)][string]$ContractPath,
        [Parameter(Mandatory)][string]$BranchPolicyPath,
        [Parameter(Mandatory)][string]$PriorityPolicyPath
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File "{0}" -ContractPath "{1}" -BranchRequiredChecksPath "{2}" -PriorityPolicyPath "{3}"' -f $scriptPath, $ContractPath, $BranchPolicyPath, $PriorityPolicyPath)
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
    $contractPath = Join-Path $repoRoot 'tools/policy/promotion-contract.json'
    $branchPolicyPath = Join-Path $repoRoot 'tools/policy/branch-required-checks.json'
    $priorityPolicyPath = Join-Path $repoRoot 'tools/priority/policy.json'

    $run = Invoke-AlignmentScript -ContractPath $contractPath -BranchPolicyPath $branchPolicyPath -PriorityPolicyPath $priorityPolicyPath
    $run.ExitCode | Should -Be 0
    ($run.StdOut + $run.StdErr) | Should -Match 'promotion-contract'
  }

  It 'fails closed when projected priority policy checks drift from the branch-class source' {
    $tmpContract = Join-Path $TestDrive 'promotion-contract.json'
    $tmpBranchPolicy = Join-Path $TestDrive 'branch-required-checks.json'
    $tmpPriorityPolicy = Join-Path $TestDrive 'policy.json'

    Write-JsonFile -Path $tmpContract -Data @{
      schema = 'promotion-contract/v1'
      schemaVersion = '1.0.0'
      check_context = 'Promotion Contract / promotion-contract'
      require_check_context_in_branch_protection = $false
      required_status_checks_ref = @{
        develop = @{
          branchName = 'develop'
          branchClassId = 'upstream-integration'
        }
        'release/*' = @{
          branchName = 'release/*'
          branchClassId = 'upstream-release-prep'
        }
      }
      artifacts = @{
        ledger_schema = 'docs/schemas/promotion-evidence-ledger-v1.schema.json'
        default_output_dir = 'tests/results/promotion-contract'
      }
    }

    Write-JsonFile -Path $tmpBranchPolicy -Data @{
      schema = 'branch-required-checks/v1'
      schemaVersion = '1.0.0'
      branchClassBindings = @{
        develop = 'upstream-integration'
        'release/*' = 'upstream-release-prep'
      }
      branchClassRequiredChecks = @{
        'upstream-integration' = @('lint', 'Promotion Contract / promotion-contract')
        'upstream-release-prep' = @('publish', 'Promotion Contract / promotion-contract')
      }
      branches = @{
        develop = @('lint', 'Promotion Contract / promotion-contract')
        'release/*' = @('publish', 'Promotion Contract / promotion-contract')
      }
    }

    Write-JsonFile -Path $tmpPriorityPolicy -Data @{
      branches = @{
        develop = @{
          branch_class_id = 'wrong-class'
          required_status_checks_strict = $true
        }
        'release/*' = @{
          branch_class_id = 'upstream-release-prep'
        }
      }
      rulesets = @{
        develop = @{
          branch_class_id = 'upstream-integration'
          includes = @('refs/heads/develop')
        }
        '8614172' = @{
          branch_class_id = 'upstream-release-prep'
          includes = @('refs/heads/release/*')
        }
      }
    }

    $run = Invoke-AlignmentScript -ContractPath $tmpContract -BranchPolicyPath $tmpBranchPolicy -PriorityPolicyPath $tmpPriorityPolicy
    $run.ExitCode | Should -Be 1
    ($run.StdOut + $run.StdErr) | Should -Match 'branch_class_id'
  }
}
