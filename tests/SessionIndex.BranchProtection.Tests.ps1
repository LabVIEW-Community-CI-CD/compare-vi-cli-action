Describe 'Update-SessionIndexBranchProtection' -Tag 'Unit' {
  BeforeAll {
    $repoRootLocal = (Get-Location).Path
    Set-Variable -Name repoRoot -Scope Script -Value $repoRootLocal

    $policyPathLocal = Join-Path $repoRootLocal 'tools/policy/branch-required-checks.json'
    Set-Variable -Name policyPath -Scope Script -Value $policyPathLocal

    $policyLocal = Get-Content -LiteralPath $policyPathLocal -Raw | ConvertFrom-Json
    Set-Variable -Name policy -Scope Script -Value $policyLocal

    Set-Variable -Name developExpected -Scope Script -Value @($policyLocal.branches.develop)
    Set-Variable -Name updateScript -Scope Script -Value (Join-Path $repoRootLocal 'tools/Update-SessionIndexBranchProtection.ps1')
    $newFixture = {
      param([string]$Name)

      $resultsDir = Join-Path $TestDrive $Name
      New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

      $summary = @{
        total = 1
        passed = 1
        failed = 0
        errors = 0
        skipped = 0
        duration_s = 0.1
        schemaVersion = '1.0.0'
      } | ConvertTo-Json
      Set-Content -LiteralPath (Join-Path $resultsDir 'pester-summary.json') -Value $summary -Encoding UTF8

      & (Join-Path $script:repoRoot 'tools/Ensure-SessionIndex.ps1') -ResultsDir $resultsDir -SummaryJson 'pester-summary.json'
      return $resultsDir
    }
    Set-Variable -Name newSessionIndexFixture -Scope Script -Value $newFixture
  }

  It 'embeds branch protection contract when contexts align' {
    $resultsDir = & $script:newSessionIndexFixture 'results-align'

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $script:developExpected

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp | Should -Not -BeNullOrEmpty
    $bp.branch | Should -Be 'develop'
    ($bp.expected | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
    $bp.contract.id | Should -Be 'bp-verify'
    $bp.contract.issue | Should -Be 118
    $bp.contract.version | Should -Be '1'
    $bp.tags | Should -Contain 'bp-verify'

    $digestScript = Join-Path $script:repoRoot 'tools/Get-FileSha256.ps1'
    $digest = & $digestScript -Path $script:policyPath
    $bp.contract.mappingDigest | Should -Be $digest
  }

  It 'resolves pull request refs to the base branch when available' {
<<<<<<< HEAD
    $resultsDir = & $script:newSessionIndexFixture 'results-prref'
=======
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
>>>>>>> 8bc198f (Align branch-protection lookup with PR base refs (#118))

    $baseRefPrevious = $env:GITHUB_BASE_REF
    try {
      $env:GITHUB_BASE_REF = 'develop'
<<<<<<< HEAD
      & $script:updateScript `
        -ResultsDir $resultsDir `
        -PolicyPath $script:policyPath `
        -Branch 'pull/123/merge' `
        -ProducedContexts $script:developExpected
=======
      & (Join-Path $root 'tools/Update-SessionIndexBranchProtection.ps1') `
        -ResultsDir $td `
        -PolicyPath $policyPath `
        -Branch 'pull/123/merge' `
        -ProducedContexts $expected
>>>>>>> 8bc198f (Align branch-protection lookup with PR base refs (#118))
    } finally {
      if ($null -eq $baseRefPrevious) {
        Remove-Item Env:GITHUB_BASE_REF -ErrorAction SilentlyContinue
      } else {
        $env:GITHUB_BASE_REF = $baseRefPrevious
      }
    }

<<<<<<< HEAD
    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.branch | Should -Be 'develop'
    ($bp.expected | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
=======
    $idx = Get-Content -LiteralPath (Join-Path $td 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.branch | Should -Be 'develop'
    ($bp.expected | Sort-Object) | Should -Be ($expected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($expected | Sort-Object)
>>>>>>> 8bc198f (Align branch-protection lookup with PR base refs (#118))
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
  }
<<<<<<< HEAD

  It 'warns when required contexts are missing' {
    $resultsDir = & $script:newSessionIndexFixture 'results-missing'
    $produced = $script:developExpected | Where-Object { $_ -ne 'Validate / fixtures' }

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $produced

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    ($bp.expected | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($produced | Sort-Object)
    $bp.result.status | Should -Be 'warn'
    $bp.result.reason | Should -Be 'missing_required'
    $bp.notes | Should -Contain 'Missing contexts: Validate / fixtures'
  }

  It 'escalates to fail when Strict is set and contexts are missing' {
    $resultsDir = & $script:newSessionIndexFixture 'results-missing-strict'
    $produced = $script:developExpected | Where-Object { $_ -ne 'Validate / lint' }

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $produced `
      -Strict

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'fail'
    $bp.result.reason | Should -Be 'missing_required'
    $bp.notes | Should -Contain 'Missing contexts: Validate / lint'
  }

  It 'records unexpected contexts when extras are produced' {
    $resultsDir = & $script:newSessionIndexFixture 'results-extra'
    $extraContexts = @('Validate / fixtures', 'Validate / lint', 'Validate / session-index', 'Validate / docs')

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $extraContexts

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'warn'
    $bp.result.reason | Should -Be 'extra_required'
    $bp.notes | Should -Contain 'Unexpected contexts: Validate / docs'
  }

  It 'captures live branch protection data when provided' {
    $resultsDir = & $script:newSessionIndexFixture 'results-actual-contexts'
    $produced = $script:developExpected
    $actual = @('Validate / fixtures', 'Validate / lint', 'Validate / session-index')

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $produced `
      -ActualContexts $actual

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.actual.status | Should -Be 'available'
    ($bp.actual.contexts | Sort-Object) | Should -Be ($actual | Sort-Object)
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
  }

  It 'flags API errors when live context retrieval fails' {
    $resultsDir = & $script:newSessionIndexFixture 'results-actual-error'

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $script:developExpected `
      -ActualStatus 'error'

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.actual.status | Should -Be 'error'
    $bp.notes | Should -Contain 'Live branch protection context query failed.'
  }

  It 'merges additional notes when provided' {
    $resultsDir = & $script:newSessionIndexFixture 'results-notes'

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $script:developExpected `
      -AdditionalNotes @('API 404: branch protection contexts not accessible')

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.notes | Should -Contain 'API 404: branch protection contexts not accessible'
  }
=======
>>>>>>> 8bc198f (Align branch-protection lookup with PR base refs (#118))
}
