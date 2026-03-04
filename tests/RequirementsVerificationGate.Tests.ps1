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
    $summary.traceSource | Should -Be 'provided'
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
      allowlist = @{
        unknownRequirementIds = @('REQ_ONE')
        uncoveredRequirementIds = @()
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 1

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'fail'
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
      allowlist = @{
        unknownRequirementIds = @()
        uncoveredRequirementIds = @('REQ_EXISTING')
      }
    }

    $run = Invoke-GateScript -TracePath $tracePath -BaselinePath $baselinePath -OutDir $outDir -GhOut $ghOut -StepSummary $stepSummary
    $run.ExitCode | Should -Be 1

    $summary = Get-Content -LiteralPath (Join-Path $outDir 'verification-summary.json') -Raw | ConvertFrom-Json
    $summary.outcome.status | Should -Be 'fail'
    $summary.deltas.newUncoveredRequirementIds | Should -Contain 'REQ_UNCOVERED_NEW'
  }
}
