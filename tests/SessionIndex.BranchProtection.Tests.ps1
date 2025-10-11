Describe 'Update-SessionIndexBranchProtection' -Tag 'Unit' {
  It 'embeds branch protection contract when contexts align' {
    $td = Join-Path $TestDrive 'results'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $summary = @{
      total = 1
      passed = 1
      failed = 0
      errors = 0
      skipped = 0
      duration_s = 0.1
      schemaVersion = '1.0.0'
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $td 'pester-summary.json') -Value $summary -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -SummaryJson 'pester-summary.json'

    $policyPath = Join-Path $root 'tools/policy/branch-required-checks.json'
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    $expected = @($policy.branches.develop)

    & (Join-Path $root 'tools/Update-SessionIndexBranchProtection.ps1') `
      -ResultsDir $td `
      -PolicyPath $policyPath `
      -Branch 'develop' `
      -ProducedContexts $expected

    $idx = Get-Content -LiteralPath (Join-Path $td 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp | Should -Not -BeNullOrEmpty
    $bp.branch | Should -Be 'develop'
    ($bp.expected | Sort-Object) | Should -Be ($expected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($expected | Sort-Object)
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
    $bp.contract.id | Should -Be 'bp-verify'
    $bp.contract.issue | Should -Be 118
    $bp.contract.version | Should -Be '1'
    $bp.tags | Should -Contain 'bp-verify'

    $digestScript = Join-Path $root 'tools/Get-FileSha256.ps1'
    $digest = & $digestScript -Path $policyPath
    $bp.contract.mappingDigest | Should -Be $digest
  }

  It 'resolves pull request refs to the base branch when available' {
    $td = Join-Path $TestDrive 'results-prref'
    New-Item -ItemType Directory -Force -Path $td | Out-Null

    $summary = @{
      total = 1
      passed = 1
      failed = 0
      errors = 0
      skipped = 0
      duration_s = 0.1
      schemaVersion = '1.0.0'
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $td 'pester-summary.json') -Value $summary -Encoding UTF8

    $root = (Get-Location).Path
    & (Join-Path $root 'tools/Ensure-SessionIndex.ps1') -ResultsDir $td -SummaryJson 'pester-summary.json'

    $policyPath = Join-Path $root 'tools/policy/branch-required-checks.json'
    $policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
    $expected = @($policy.branches.develop)

    $baseRefPrevious = $env:GITHUB_BASE_REF
    try {
      $env:GITHUB_BASE_REF = 'develop'
      & (Join-Path $root 'tools/Update-SessionIndexBranchProtection.ps1') `
        -ResultsDir $td `
        -PolicyPath $policyPath `
        -Branch 'pull/123/merge' `
        -ProducedContexts $expected
    } finally {
      if ($null -eq $baseRefPrevious) {
        Remove-Item Env:GITHUB_BASE_REF -ErrorAction SilentlyContinue
      } else {
        $env:GITHUB_BASE_REF = $baseRefPrevious
      }
    }

    $idx = Get-Content -LiteralPath (Join-Path $td 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.branch | Should -Be 'develop'
    ($bp.expected | Sort-Object) | Should -Be ($expected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($expected | Sort-Object)
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
  }
}
