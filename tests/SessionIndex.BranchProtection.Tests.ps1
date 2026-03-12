Describe 'Update-SessionIndexBranchProtection' -Tag 'Unit' {
  BeforeAll {
    $repoRootLocal = (Get-Location).Path
    Set-Variable -Name repoRoot -Scope Script -Value $repoRootLocal

    $policyPathLocal = Join-Path $repoRootLocal 'tools/policy/branch-required-checks.json'
    Set-Variable -Name policyPath -Scope Script -Value $policyPathLocal

    $policyLocal = Get-Content -LiteralPath $policyPathLocal -Raw | ConvertFrom-Json
    Set-Variable -Name policy -Scope Script -Value $policyLocal

    Set-Variable -Name developBranchClassId -Scope Script -Value ([string]$policyLocal.branchClassBindings.develop)
    Set-Variable -Name releaseBranchClassId -Scope Script -Value ([string]$policyLocal.branchClassBindings.'release/*')
    Set-Variable -Name developExpected -Scope Script -Value @($policyLocal.branchClassRequiredChecks.($script:developBranchClassId))
    Set-Variable -Name releaseExpected -Scope Script -Value @($policyLocal.branchClassRequiredChecks.($script:releaseBranchClassId))
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

  It 'requires develop policy to include core required checks' {
    $script:developBranchClassId | Should -Be 'upstream-integration'
    $script:developExpected | Should -Contain 'lint'
    $script:developExpected | Should -Contain 'fixtures'
    $script:developExpected | Should -Contain 'session-index'
    $script:developExpected | Should -Contain 'issue-snapshot'
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
    $bp.branchClassId | Should -Be $script:developBranchClassId
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
    $resultsDir = & $script:newSessionIndexFixture 'results-prref'

    $baseRefPrevious = $env:GITHUB_BASE_REF
    try {
      $env:GITHUB_BASE_REF = 'develop'
      & $script:updateScript `
        -ResultsDir $resultsDir `
        -PolicyPath $script:policyPath `
        -Branch 'pull/123/merge' `
        -ProducedContexts $script:developExpected
    } finally {
      if ($null -eq $baseRefPrevious) {
        Remove-Item Env:GITHUB_BASE_REF -ErrorAction SilentlyContinue
      } else {
        $env:GITHUB_BASE_REF = $baseRefPrevious
      }
    }

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.branch | Should -Be 'develop'
    $bp.branchClassId | Should -Be $script:developBranchClassId
    ($bp.expected | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.PSObject.Properties.Name -contains 'notes') | Should -BeFalse
  }

  It 'warns when required contexts are missing' {
    $resultsDir = & $script:newSessionIndexFixture 'results-missing'
    $missingContext = ($script:developExpected | Where-Object { $_ -match 'fixtures' } | Select-Object -First 1)
    if (-not $missingContext) {
      $missingContext = $script:developExpected | Select-Object -First 1
    }
    $produced = $script:developExpected | Where-Object { $_ -ne $missingContext }

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
    $bp.notes | Should -Contain ("Missing contexts: {0}" -f $missingContext)
  }

  It 'treats prefixed produced contexts as equivalent to short expected contexts' {
    $resultsDir = & $script:newSessionIndexFixture 'results-prefixed-produced'
    $produced = @(
      $script:developExpected | ForEach-Object { "Validate / $_" }
    )

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $produced

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
  }

  It 'escalates to fail when Strict is set and contexts are missing' {
    $resultsDir = & $script:newSessionIndexFixture 'results-missing-strict'
    $missingContext = ($script:developExpected | Where-Object { $_ -match 'lint' } | Select-Object -First 1)
    if (-not $missingContext) {
      $missingContext = $script:developExpected | Select-Object -First 1
    }
    $produced = $script:developExpected | Where-Object { $_ -ne $missingContext }

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
    $bp.notes | Should -Contain ("Missing contexts: {0}" -f $missingContext)
  }

  It 'records unexpected contexts when extras are produced' {
    $resultsDir = & $script:newSessionIndexFixture 'results-extra'
    $extraContext = 'unexpected-check'
    $extraContexts = @($script:developExpected + $extraContext)

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $extraContexts

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'warn'
    $bp.result.reason | Should -Be 'extra_required'
    $bp.notes | Should -Contain ("Unexpected contexts: {0}" -f $extraContext)
  }

  It 'captures live branch protection data when provided' {
    $resultsDir = & $script:newSessionIndexFixture 'results-actual-contexts'
    $produced = $script:developExpected
    $actual = @($script:developExpected)

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

  It 'treats prefixed actual contexts as equivalent to short expected contexts' {
    $resultsDir = & $script:newSessionIndexFixture 'results-prefixed-actual'
    $produced = $script:developExpected
    $actual = @(
      $script:developExpected | ForEach-Object { "Validate / $_" }
    )

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $produced `
      -ActualContexts $actual

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
  }

  It 'embeds branch protection contract when release contexts align' {
    $resultsDir = & $script:newSessionIndexFixture 'results-release-align'

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'release/v0.6.0' `
      -ProducedContexts $script:releaseExpected

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.branch | Should -Be 'release/v0.6.0'
    $bp.branchClassId | Should -Be $script:releaseBranchClassId
    ($bp.expected | Sort-Object) | Should -Be ($script:releaseExpected | Sort-Object)
    ($bp.produced | Sort-Object) | Should -Be ($script:releaseExpected | Sort-Object)
    $bp.result.status | Should -Be 'ok'
    $bp.result.reason | Should -Be 'aligned'
    ($bp.expected -contains 'Requirements Verification / requirements-verification') | Should -BeFalse
  }

  It 'warns when required release contexts are missing' {
    $resultsDir = & $script:newSessionIndexFixture 'results-release-missing'
    $missingContext = ($script:releaseExpected | Where-Object { $_ -match 'publish' } | Select-Object -First 1)
    if (-not $missingContext) {
      $missingContext = $script:releaseExpected | Select-Object -First 1
    }
    $produced = $script:releaseExpected | Where-Object { $_ -ne $missingContext }

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'release/v0.6.0' `
      -ProducedContexts $produced

    $idx = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $bp = $idx.branchProtection
    $bp.result.status | Should -Be 'warn'
    $bp.result.reason | Should -Be 'missing_required'
    $bp.notes | Should -Contain ("Missing contexts: {0}" -f $missingContext)
  }

  It 'emits deterministic branch protection output for equivalent context sets' {
    $resultsDir = & $script:newSessionIndexFixture 'results-deterministic'
    $firstProduced = @($script:developExpected + $script:developExpected[0])
    $secondProduced = @($script:developExpected | Sort-Object -Descending)

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $firstProduced

    $firstIndex = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $firstBranchProtection = $firstIndex.branchProtection | ConvertTo-Json -Depth 10 -Compress

    & $script:updateScript `
      -ResultsDir $resultsDir `
      -PolicyPath $script:policyPath `
      -Branch 'develop' `
      -ProducedContexts $secondProduced

    $secondIndex = Get-Content -LiteralPath (Join-Path $resultsDir 'session-index.json') -Raw | ConvertFrom-Json
    $secondBranchProtection = $secondIndex.branchProtection | ConvertTo-Json -Depth 10 -Compress

    $secondIndex.branchProtection.result.status | Should -Be 'ok'
    $secondIndex.branchProtection.result.reason | Should -Be 'aligned'
    $secondBranchProtection | Should -Be $firstBranchProtection
    ($secondIndex.branchProtection.expected | Sort-Object) | Should -Be ($script:developExpected | Sort-Object)
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
}
