Describe 'Requirements verification gate' {
  BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $scriptPath = Join-Path $repoRoot 'tools/Verify-RequirementsGate.ps1'
    $schemaLitePath = Join-Path $repoRoot 'tools/Invoke-JsonSchemaLite.ps1'
    $summarySchemaPath = Join-Path $repoRoot 'docs/schemas/requirements-verification-v1.schema.json'

    function Invoke-GateScript {
      param(
        [Parameter(Mandatory)] [string]$TracePath,
        [Parameter(Mandatory)] [string]$BaselinePath,
        [Parameter(Mandatory)] [string]$OutDir,
        [Parameter(Mandatory)] [string]$GhOut,
        [Parameter(Mandatory)] [string]$StepSummary
      )

      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = 'pwsh'
      $psi.Arguments = ('-NoLogo -NoProfile -NonInteractive -File "{0}" -TraceMatrixPath "{1}" -BaselinePolicyPath "{2}" -OutDir "{3}" -GitHubOutputPath "{4}" -StepSummaryPath "{5}"' -f $scriptPath, $TracePath, $BaselinePath, $OutDir, $GhOut, $StepSummary)
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
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [object]$Data
      )
      $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
    }
  }

  It 'passes when trace matrix matches allowlist baseline' {
    $outDir = Join-Path $TestDrive 'out-pass'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $tracePath = Join-Path $TestDrive 'trace-pass.json'
    $baselinePath = Join-Path $TestDrive 'baseline-pass.json'
    $ghOut = Join-Path $TestDrive 'gh-output-pass.txt'
    $stepSummary = Join-Path $TestDrive 'summary-pass.md'

    Write-JsonFile -Path $tracePath -Data @{
      summary = @{ requirements = @{ total = 3; covered = 2; uncovered = 1 } }
      gaps = @{
        unknownRequirementIds = @('REQ_ONE')
        requirementsWithoutTests = @('DOTNET_CLI_RELEASE_ASSET')
      }
    }

    Write-JsonFile -Path $baselinePath -Data @{
      schema = 'requirements-verification-baseline/v1'
      schemaVersion = '1.0.0'
      policy = @{ minimumRequirementsCoveragePercent = 40 }
      allowlist = @{
        unknownRequirementIds = @('REQ_ONE')
        uncoveredRequirementIds = @('DOTNET_CLI_RELEASE_ASSET')
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 0

    $summaryPath = Join-Path $outDir 'verification-summary.json'
    Test-Path -LiteralPath $summaryPath | Should -BeTrue
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'pass'
    $summary.outcome.kind | Should -Be 'requirements_coverage_ok'
    $summary.traceSource | Should -Be 'provided'
    $summary.metrics.requirementCoveragePercent | Should -Be 66.67
    $summary.metrics.requirementCoverageTargetPercent | Should -Be 40
    $summary.deltas.newUnknownRequirementIds.Count | Should -Be 0
    $summary.deltas.newUncoveredRequirementIds.Count | Should -Be 0

    (Get-Content -LiteralPath $ghOut -Raw) | Should -Match 'verification-status=pass'

    $schemaValidation = & pwsh -NoLogo -NonInteractive -NoProfile -File $schemaLitePath -JsonPath $summaryPath -SchemaPath $summarySchemaPath
    $LASTEXITCODE | Should -Be 0
    ($schemaValidation -join "`n") | Should -Match 'Schema-lite validation passed.'
  }

  It 'fails when new unknown requirement IDs are introduced' {
    $outDir = Join-Path $TestDrive 'out-new-unknown'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $tracePath = Join-Path $TestDrive 'trace-new-unknown.json'
    $baselinePath = Join-Path $TestDrive 'baseline-new-unknown.json'
    $ghOut = Join-Path $TestDrive 'gh-output-new-unknown.txt'
    $stepSummary = Join-Path $TestDrive 'summary-new-unknown.md'

    Write-JsonFile -Path $tracePath -Data @{
      summary = @{ requirements = @{ total = 2; covered = 2; uncovered = 0 } }
      gaps = @{
        unknownRequirementIds = @('REQ_NEW')
        requirementsWithoutTests = @()
      }
    }

    Write-JsonFile -Path $baselinePath -Data @{
      schema = 'requirements-verification-baseline/v1'
      schemaVersion = '1.0.0'
      policy = @{ minimumRequirementsCoveragePercent = 40 }
      allowlist = @{
        unknownRequirementIds = @('REQ_ONE')
        uncoveredRequirementIds = @()
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 1

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'fail'
    $summary.outcome.kind | Should -Be 'requirements_coverage_regression'
    $summary.deltas.newUnknownRequirementIds | Should -Contain 'REQ_NEW'
  }

  It 'fails when new uncovered requirement IDs are introduced' {
    $outDir = Join-Path $TestDrive 'out-new-uncovered'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $tracePath = Join-Path $TestDrive 'trace-new-uncovered.json'
    $baselinePath = Join-Path $TestDrive 'baseline-new-uncovered.json'
    $ghOut = Join-Path $TestDrive 'gh-output-new-uncovered.txt'
    $stepSummary = Join-Path $TestDrive 'summary-new-uncovered.md'

    Write-JsonFile -Path $tracePath -Data @{
      summary = @{ requirements = @{ total = 4; covered = 3; uncovered = 1 } }
      gaps = @{
        unknownRequirementIds = @()
        requirementsWithoutTests = @('REQ_UNCOVERED_NEW')
      }
    }

    Write-JsonFile -Path $baselinePath -Data @{
      schema = 'requirements-verification-baseline/v1'
      schemaVersion = '1.0.0'
      policy = @{ minimumRequirementsCoveragePercent = 40 }
      allowlist = @{
        unknownRequirementIds = @()
        uncoveredRequirementIds = @('REQ_EXISTING')
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 1

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'fail'
    $summary.outcome.kind | Should -Be 'requirements_coverage_regression'
    $summary.deltas.newUncoveredRequirementIds | Should -Contain 'REQ_UNCOVERED_NEW'
  }

  It 'fails when requirement coverage percent is below configured target' {
    $outDir = Join-Path $TestDrive 'out-below-target'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $tracePath = Join-Path $TestDrive 'trace-below-target.json'
    $baselinePath = Join-Path $TestDrive 'baseline-below-target.json'
    $ghOut = Join-Path $TestDrive 'gh-output-below-target.txt'
    $stepSummary = Join-Path $TestDrive 'summary-below-target.md'

    Write-JsonFile -Path $tracePath -Data @{
      summary = @{ requirements = @{ total = 10; covered = 3; uncovered = 7 } }
      gaps = @{
        unknownRequirementIds = @('REQ_ONE')
        requirementsWithoutTests = @('DOTNET_CLI_RELEASE_ASSET')
      }
    }

    Write-JsonFile -Path $baselinePath -Data @{
      schema = 'requirements-verification-baseline/v1'
      schemaVersion = '1.0.0'
      policy = @{ minimumRequirementsCoveragePercent = 40 }
      allowlist = @{
        unknownRequirementIds = @('REQ_ONE')
        uncoveredRequirementIds = @('DOTNET_CLI_RELEASE_ASSET')
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 1

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'fail'
    $summary.outcome.kind | Should -Be 'requirements_coverage_below_target'
    $summary.metrics.requirementCoveragePercent | Should -Be 30
    $summary.metrics.requirementCoverageTargetPercent | Should -Be 40
    $summary.deltas.newUnknownRequirementIds.Count | Should -Be 0
    $summary.deltas.newUncoveredRequirementIds.Count | Should -Be 0
  }

  It 'uses policy requirement catalog IDs as the coverage denominator' {
    $outDir = Join-Path $TestDrive 'out-policy-catalog'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $tracePath = Join-Path $TestDrive 'trace-policy-catalog.json'
    $baselinePath = Join-Path $TestDrive 'baseline-policy-catalog.json'
    $ghOut = Join-Path $TestDrive 'gh-output-policy-catalog.txt'
    $stepSummary = Join-Path $TestDrive 'summary-policy-catalog.md'

    Write-JsonFile -Path $tracePath -Data @{
      summary = @{ requirements = @{ total = 999; covered = 999; uncovered = 0 } }
      tests = @(
        @{ reqIds = @('CLI-FR-001', 'CLI-FR-020') }
      )
      gaps = @{
        unknownRequirementIds = @()
        requirementsWithoutTests = @()
      }
    }

    Write-JsonFile -Path $baselinePath -Data @{
      schema = 'requirements-verification-baseline/v1'
      schemaVersion = '1.0.0'
      policy = @{
        minimumRequirementsCoveragePercent = 40
        requirementCatalogIds = @('CLI-FR-001', 'CLI-FR-002', 'CLI-FR-020', 'CLI-REL-001', 'AC-001')
      }
      allowlist = @{
        unknownRequirementIds = @()
        uncoveredRequirementIds = @('CLI-FR-002', 'CLI-REL-001', 'AC-001')
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 0

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'pass'
    $summary.metrics.requirementTotal | Should -Be 5
    $summary.metrics.requirementCovered | Should -Be 2
    $summary.metrics.requirementUncovered | Should -Be 3
    $summary.metrics.requirementCoveragePercent | Should -Be 40
    $summary.metrics.requirementCoverageTargetPercent | Should -Be 40
  }
}
