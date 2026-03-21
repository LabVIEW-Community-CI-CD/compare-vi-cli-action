#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'LabVIEW CLI custom operation proof contracts' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:ProofModule = Join-Path $script:RepoRoot 'tools' 'LabVIEWCLICustomOperationProof.psm1'
    $script:ProofScript = Join-Path $script:RepoRoot 'tools' 'Test-LabVIEWCLICustomOperationProof.ps1'
    if (-not (Test-Path -LiteralPath $script:ProofModule -PathType Leaf)) {
      throw "LabVIEWCLICustomOperationProof.psm1 not found at $script:ProofModule"
    }
    if (-not (Test-Path -LiteralPath $script:ProofScript -PathType Leaf)) {
      throw "Test-LabVIEWCLICustomOperationProof.ps1 not found at $script:ProofScript"
    }

    Import-Module $script:ProofModule -Force | Out-Null

    function script:New-SyntheticCustomOperationExample {
      param([Parameter(Mandatory)][string]$RootPath)

      New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
      foreach ($relativePath in @(
        'AddTwoNumbers.lvclass',
        'AddTwoNumbers.vi',
        'GetHelp.vi',
        'RunOperation.vi'
      )) {
        $filePath = Join-Path $RootPath $relativePath
        $parent = Split-Path -Parent $filePath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
          New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Set-Content -LiteralPath $filePath -Value 'placeholder' -Encoding utf8
      }

      return $RootPath
    }
  }

  It 'classifies default-path drift and custom-operation loading when both explicit scenarios time out' {
    $analysis = Resolve-LabVIEWCustomOperationProofAnalysis -ScenarioResults @(
      [pscustomobject]@{
        name = 'default-help'
        status = 'timed-out'
        timedOut = $true
        cleanup = [pscustomobject]@{ killedPids = @(); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2025\LabVIEW.exe' }
      },
      [pscustomobject]@{
        name = 'explicit-help'
        status = 'timed-out'
        timedOut = $true
        cleanup = [pscustomobject]@{ killedPids = @(4100); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' }
      },
      [pscustomobject]@{
        name = 'explicit-headless-run'
        status = 'timed-out'
        timedOut = $true
        cleanup = [pscustomobject]@{ killedPids = @(4200); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' }
      }
    ) -RequestedLabVIEWPath 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'

    $analysis.defaultPathDriftObserved | Should -BeTrue
    @($analysis.rootCauseCandidates) | Should -Contain 'default-path-drift'
    @($analysis.rootCauseCandidates) | Should -Contain 'custom-operation-loading'
    @($analysis.rootCauseCandidates) | Should -Contain 'host-plane-32bit-startup'
    $analysis.headlessInteractiveMismatchObserved | Should -BeFalse
    $analysis.cleanupRequired | Should -BeTrue
    $analysis.cleanupSucceeded | Should -BeTrue
  }

  It 'parses both direct and last-used LabVIEW log lines' {
    $insights = Get-LabVIEWCustomOperationLogInsights -Text @'
Using last used LabVIEW: "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe"
Using LabVIEW: "C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe"
'@

    @($insights.observedLabVIEWPaths).Count | Should -Be 1
    $insights.observedLabVIEWPath | Should -Be 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
  }

  It 'classifies headless mismatch when GetHelp succeeds but the headless run times out' {
    $analysis = Resolve-LabVIEWCustomOperationProofAnalysis -ScenarioResults @(
      [pscustomobject]@{
        name = 'default-help'
        status = 'succeeded'
        timedOut = $false
        cleanup = [pscustomobject]@{ killedPids = @(); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' }
      },
      [pscustomobject]@{
        name = 'explicit-help'
        status = 'succeeded'
        timedOut = $false
        cleanup = [pscustomobject]@{ killedPids = @(); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' }
      },
      [pscustomobject]@{
        name = 'explicit-headless-run'
        status = 'timed-out'
        timedOut = $true
        cleanup = [pscustomobject]@{ killedPids = @(); errors = @() }
        lingeringProcesses = @()
        logInsights = [pscustomobject]@{ observedLabVIEWPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe' }
      }
    ) -RequestedLabVIEWPath 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'

    $analysis.defaultPathDriftObserved | Should -BeFalse
    $analysis.headlessInteractiveMismatchObserved | Should -BeTrue
    @($analysis.rootCauseCandidates) | Should -Contain 'headless-interactive-mismatch'
    @($analysis.rootCauseCandidates) | Should -Not -Contain 'custom-operation-loading'
  }

  It 'writes a planned proof receipt and summary from a synthetic AddTwoNumbers example' {
    $sourcePath = New-SyntheticCustomOperationExample -RootPath (Join-Path $TestDrive 'source-example')
    $resultsRoot = Join-Path $TestDrive 'results-root'
    $labviewPath = 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -SourceExamplePath $sourcePath `
      -ResultsRoot $resultsRoot `
      -LabVIEWPath $labviewPath `
      -DryRun `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'labview-cli-custom-operation-proof.json'
    $summaryPath = Join-Path $resultsRoot 'labview-cli-custom-operation-proof.md'
    $scaffoldReceiptPath = Join-Path $resultsRoot 'custom-operation-scaffold.json'

    $reportPath | Should -Exist
    $summaryPath | Should -Exist
    $scaffoldReceiptPath | Should -Exist

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 12
    $report.schema | Should -Be 'labview-cli-custom-operation-proof@v1'
    $report.status | Should -Be 'planned'
    $report.executionPlane | Should -Be 'host'
    $report.operationName | Should -Be 'AddTwoNumbers'
    $report.explicitLabVIEWPath | Should -Be $labviewPath
    @($report.scenarios).Count | Should -Be 3
    (@($report.scenarios | ForEach-Object { $_.status } | Select-Object -Unique)) | Should -Be @('planned')

    $summary = Get-Content -LiteralPath $summaryPath -Raw
    $summary | Should -Match '# LabVIEW CLI Custom Operation Proof'
    $summary | Should -Match '- Final status: `planned`'
    $summary | Should -Match '`default-help`'
    $summary | Should -Match '`explicit-headless-run`'
  }

  It 'writes a planned windows-container proof that keeps help scenarios headless' {
    $sourcePath = New-SyntheticCustomOperationExample -RootPath (Join-Path $TestDrive 'source-example-container')
    $resultsRoot = Join-Path $TestDrive 'results-root-container'
    $containerLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ExecutionPlane windows-container `
      -SourceExamplePath $sourcePath `
      -ResultsRoot $resultsRoot `
      -WindowsContainerLabVIEWPath $containerLabVIEWPath `
      -DryRun `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'labview-cli-custom-operation-proof.json'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 12

    $report.executionPlane | Should -Be 'windows-container'
    $report.containerImage | Should -Be 'nationalinstruments/labview:2026q1-windows'
    $report.explicitLabVIEWPath | Should -Be $containerLabVIEWPath
    @($report.scenarios).Count | Should -Be 3
    ($report.scenarios | Where-Object { $_.name -eq 'default-help' } | Select-Object -First 1).preview.args | Should -Contain '-Headless'
    ($report.scenarios | Where-Object { $_.name -eq 'explicit-help' } | Select-Object -First 1).preview.args | Should -Contain '-Headless'
    ($report.scenarios | Where-Object { $_.name -eq 'explicit-help' } | Select-Object -First 1).preview.args | Should -Contain $containerLabVIEWPath
  }

  It 'deduplicates copied log inventory in windows-container proof receipts' {
    $sourcePath = New-SyntheticCustomOperationExample -RootPath (Join-Path $TestDrive 'source-example-container-dedup')
    $resultsRoot = Join-Path $TestDrive 'results-root-container-dedup'
    $runnerStubPath = Join-Path $TestDrive 'Stub-WindowsContainerRunner.ps1'
    Set-Content -LiteralPath $runnerStubPath -Encoding utf8 -Value @'
param(
  [string]$OperationName,
  [string]$ResultsRoot,
  [string]$Image,
  [int]$TimeoutSeconds,
  [string]$LabVIEWPath = '',
  [string]$ArgumentsJson = '',
  [switch]$Help,
  [switch]$Headless,
  [switch]$LogToConsole
)
$resolvedResultsRoot = [System.IO.Path]::GetFullPath($ResultsRoot)
if (-not (Test-Path -LiteralPath $resolvedResultsRoot -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
}
$logsRoot = Join-Path $resolvedResultsRoot 'logs'
New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
$logA = Join-Path $logsRoot 'lvtemporary_a.log'
$logB = Join-Path $logsRoot 'LabVIEWCLI-b.txt'
Set-Content -LiteralPath $logA -Value 'Using LabVIEW: "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe"' -Encoding utf8
Set-Content -LiteralPath $logB -Value 'LabVIEW launched successfully' -Encoding utf8
$capturePath = Join-Path $resolvedResultsRoot 'ni-windows-custom-operation-capture.json'
$scenarioResult = [ordered]@{
  status = 'succeeded'
  timedOut = $false
  cliPath = 'in-container'
  requestedLabVIEWPath = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) { $null } else { $LabVIEWPath }
  logFiles = @(
    [ordered]@{
      name = 'lvtemporary_a.log'
      sourcePath = 'C:\Users\ContainerAdministrator\AppData\Local\Temp\lvtemporary_a.log'
      destinationPath = $logA
      lastWriteTimeUtc = '2026-03-20T00:00:00Z'
      length = 10
    },
    [ordered]@{
      name = 'lvtemporary_a.log'
      sourcePath = 'C:\Users\ContainerAdministrator\AppData\Local\Temp\lvtemporary_a.log'
      destinationPath = $logA
      lastWriteTimeUtc = '2026-03-20T00:00:00Z'
      length = 10
    },
    [ordered]@{
      name = 'LabVIEWCLI-b.txt'
      sourcePath = 'C:\Users\ContainerAdministrator\AppData\Local\Temp\LabVIEWCLI-b.txt'
      destinationPath = $logB
      lastWriteTimeUtc = '2026-03-20T00:00:01Z'
      length = 20
    },
    [ordered]@{
      name = 'LabVIEWCLI-b.txt'
      sourcePath = 'C:\Users\ContainerAdministrator\AppData\Local\Temp\LabVIEWCLI-b.txt'
      destinationPath = $logB
      lastWriteTimeUtc = '2026-03-20T00:00:01Z'
      length = 20
    }
  )
}
[ordered]@{
  schema = 'ni-windows-container-custom-operation/v1'
  status = 'ok'
  classification = 'ok'
  image = $Image
  message = ''
  scenarioResult = $scenarioResult
  preflightPath = (Join-Path $resolvedResultsRoot 'preflight/windows-ni-2026q1-host-preflight.json')
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $capturePath -Encoding utf8
exit 0
'@

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -ExecutionPlane windows-container `
      -SourceExamplePath $sourcePath `
      -ResultsRoot $resultsRoot `
      -WindowsContainerLabVIEWPath 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe' `
      -WindowsContainerRunnerScriptPath $runnerStubPath `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")

    $reportPath = Join-Path $resultsRoot 'labview-cli-custom-operation-proof.json'
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 12
    foreach ($scenario in @($report.scenarios)) {
      @($scenario.logCapture.files).Count | Should -Be 2
      @($scenario.logCapture.files | ForEach-Object { [string]$_.destinationPath } | Select-Object -Unique).Count | Should -Be 2
    }
  }

  It 'fails closed when the installed example source is missing' {
    $missingSource = Join-Path $TestDrive 'missing-example'
    $resultsRoot = Join-Path $TestDrive 'results-root'

    $output = & pwsh -NoLogo -NoProfile -File $script:ProofScript `
      -SourceExamplePath $missingSource `
      -ResultsRoot $resultsRoot `
      -DryRun `
      -SkipSchemaValidation *>&1
    $LASTEXITCODE | Should -Not -Be 0
    (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'example source was not found'
  }
}
