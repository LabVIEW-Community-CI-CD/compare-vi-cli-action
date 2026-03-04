Describe 'Get-BranchProtectionRequiredChecks' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Get-Location).Path
    Set-Variable -Name scriptPath -Scope Script -Value (Join-Path $repoRoot 'tools/Get-BranchProtectionRequiredChecks.ps1')
    Set-Variable -Name requiredVerificationCheck -Scope Script -Value 'Requirements Verification / requirements-verification'
  }

  It 'returns contexts when API succeeds' {
    Mock Invoke-RestMethod {
      [pscustomobject]@{
        required_status_checks = [pscustomobject]@{
          contexts = @()
          checks   = @(
            @{ context = 'Validate / session-index' },
            @{ context = 'Validate / lint' },
            @{ context = 'Requirements Verification / requirements-verification' },
            @{ context = 'Validate / fixtures' },
            @{ context = 'Validate / issue-snapshot' },
            @{ context = 'Validate / lint' },
            @{ context = 'Policy Guard (Upstream) / policy-guard' }
          )
        }
      }
    }

    $result = & $script:scriptPath -Owner 'octo' -Repository 'repo' -Branch 'develop' -Token 'token'
    $result.status | Should -Be 'available'
    $expected = @(
      'Policy Guard (Upstream) / policy-guard',
      'Requirements Verification / requirements-verification',
      'Validate / fixtures',
      'Validate / issue-snapshot',
      'Validate / lint',
      'Validate / session-index'
    )
    $result.contexts | Should -Be $expected
    $result.contexts | Should -Contain $script:requiredVerificationCheck
    @($result.notes).Length | Should -Be 0
  }

  It 'normalizes contexts payload ordering and duplicates' {
    Mock Invoke-RestMethod {
      [pscustomobject]@{
        required_status_checks = [pscustomobject]@{
          contexts = @(
            'Validate / session-index',
            'Validate / lint',
            'Requirements Verification / requirements-verification',
            'Validate / fixtures',
            'Validate / lint',
            'Validate / issue-snapshot',
            'Policy Guard (Upstream) / policy-guard'
          )
        }
      }
    }

    $result = & $script:scriptPath -Owner 'octo' -Repository 'repo' -Branch 'develop' -Token 'token'
    $result.status | Should -Be 'available'
    $expected = @(
      'Policy Guard (Upstream) / policy-guard',
      'Requirements Verification / requirements-verification',
      'Validate / fixtures',
      'Validate / issue-snapshot',
      'Validate / lint',
      'Validate / session-index'
    )
    $result.contexts | Should -Be $expected
    @($result.notes).Length | Should -Be 0
  }

  It 'returns unavailable when the API reports no branch protection' {
    Mock Invoke-RestMethod {
      $ex = [System.Management.Automation.RuntimeException]::new('Not Found')
      $resp = [pscustomobject]@{ StatusCode = 404 }
      $ex | Add-Member -MemberType NoteProperty -Name Response -Value $resp
      throw $ex
    }

    $result = & $script:scriptPath -Owner 'octo' -Repository 'repo' -Branch 'feature' -Token 'token'
    $result.status | Should -Be 'unavailable'
    @($result.contexts).Length | Should -Be 0
    $result.notes | Should -Contain 'Branch protection required status checks not configured for this branch.'
  }

  It 'returns error when API call fails unexpectedly' {
    Mock Invoke-RestMethod {
      throw [System.Management.Automation.RuntimeException]::new('Boom')
    }

    $result = & $script:scriptPath -Owner 'octo' -Repository 'repo' -Branch 'develop' -Token 'token'
    $result.status | Should -Be 'error'
    @($result.contexts).Length | Should -Be 0
    ($result.notes | Where-Object { $_ -like 'Branch protection query failed*' } | Measure-Object).Count | Should -BeGreaterThan 0
  }
}
