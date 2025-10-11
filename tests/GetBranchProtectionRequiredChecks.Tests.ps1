Describe 'Get-BranchProtectionRequiredChecks' -Tag 'Unit' {
  BeforeAll {
    $repoRoot = (Get-Location).Path
    Set-Variable -Name scriptPath -Scope Script -Value (Join-Path $repoRoot 'tools/Get-BranchProtectionRequiredChecks.ps1')
  }

  It 'returns contexts when API succeeds' {
    Mock Invoke-RestMethod {
      [pscustomobject]@{
        required_status_checks = [pscustomobject]@{
          contexts = @('Validate / lint','Validate / fixtures')
          checks   = @()
        }
      }
    }

    $result = & $script:scriptPath -Owner 'octo' -Repository 'repo' -Branch 'develop' -Token 'token'
    $result.status | Should -Be 'available'
    ($result.contexts | Sort-Object) | Should -Be @('Validate / fixtures','Validate / lint')
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
