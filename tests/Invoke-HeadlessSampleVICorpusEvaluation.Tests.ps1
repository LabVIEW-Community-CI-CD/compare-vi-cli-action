Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-HeadlessSampleVICorpusEvaluation.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:EvaluateScript = Join-Path $script:RepoRoot 'tools' 'Invoke-HeadlessSampleVICorpusEvaluation.ps1'
    if (-not (Test-Path -LiteralPath $script:EvaluateScript -PathType Leaf)) {
      throw "Invoke-HeadlessSampleVICorpusEvaluation.ps1 not found at $script:EvaluateScript"
    }

    $script:CatalogPath = Join-Path $script:RepoRoot 'fixtures' 'headless-corpus' 'sample-vi-corpus.targets.json'
  }

  It 'passes on the checked-in headless sample corpus and records admission-state coverage' {
    $resultsRoot = Join-Path $TestDrive 'sample-corpus-eval'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:EvaluateScript -ResultsRoot $resultsRoot 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $reportPath = Join-Path $resultsRoot 'headless-sample-vi-corpus-evaluation.json'
    $markdownPath = Join-Path $resultsRoot 'headless-sample-vi-corpus-evaluation.md'
    $reportPath | Should -Exist
    $markdownPath | Should -Exist

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.schema | Should -Be 'vi-headless/sample-corpus-evaluation@v1'
    $report.overallStatus | Should -Be 'ok'
    $report.summary.acceptedCount | Should -Be 2
    $report.summary.provisionalCount | Should -Be 2
    $report.summary.driftCount | Should -Be 0

    $accepted = @($report.targets | Where-Object { [string]$_.id -eq 'icon-editor-demo-vip-preinstall-history' } | Select-Object -First 1)
    $accepted | Should -Not -BeNullOrEmpty
    $accepted.status | Should -Be 'ok'
    $accepted.checks.licenseDeclared | Should -BeTrue
    $accepted.checks.successfulWorkflowEvidence | Should -BeTrue
    $accepted.operationPayloadMode | Should -Be 'not-applicable'
    $accepted.checks.operationPayloadPromotable | Should -BeTrue

    $provisional = @($report.targets | Where-Object { [string]$_.id -eq 'linuxcontainerdemo-newthing-print' } | Select-Object -First 1)
    $provisional | Should -Not -BeNullOrEmpty
    $provisional.status | Should -Be 'warning'
    $provisional.certificationSurface | Should -Be 'print-single-file'
    $provisional.operationPayloadMode | Should -Be 'additional-operation-directory'
    $provisional.operationPayloadProvenanceState | Should -Be 'research-only'
    $provisional.checks.licenseDeclared | Should -BeFalse
    $provisional.checks.operationPayloadTracked | Should -BeTrue
    $provisional.checks.operationPayloadLicenseDeclared | Should -BeFalse
    $provisional.checks.operationPayloadPromotable | Should -BeFalse
    (($provisional.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Custom operation payload has no declared license'

    $licensedCandidate = @($report.targets | Where-Object { [string]$_.id -eq 'icon-editor-demo-canaryprobe-print' } | Select-Object -First 1)
    $licensedCandidate | Should -Not -BeNullOrEmpty
    $licensedCandidate.status | Should -Be 'warning'
    $licensedCandidate.certificationSurface | Should -Be 'print-single-file'
    $licensedCandidate.operationPayloadMode | Should -Be 'builtin'
    $licensedCandidate.operationPayloadProvenanceState | Should -Be 'research-only'
    $licensedCandidate.checks.licenseDeclared | Should -BeTrue
    $licensedCandidate.checks.successfulWorkflowEvidence | Should -BeTrue
    $licensedCandidate.checks.operationPayloadTracked | Should -BeTrue
    $licensedCandidate.checks.operationPayloadLicenseDeclared | Should -BeTrue
    $licensedCandidate.checks.operationPayloadPromotable | Should -BeFalse
    (($licensedCandidate.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Builtin operation payload metadata must still be marked accepted before promotion'
  }

  It 'fails closed when an accepted seed loses its declared license' {
    $catalog = Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json -Depth 20
    $target = @($catalog.targets | Where-Object { [string]$_.id -eq 'icon-editor-demo-vip-preinstall-history' } | Select-Object -First 1)
    $target | Should -Not -BeNullOrEmpty
    $target.source.licenseSpdx = $null

    $driftCatalogPath = Join-Path $TestDrive 'sample-corpus.drift.json'
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $driftCatalogPath -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'sample-corpus-drift'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:EvaluateScript -CatalogPath $driftCatalogPath -ResultsRoot $resultsRoot -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $outputText = ($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $outputText | Should -Match 'detected drift'

    $reportPath = Join-Path $resultsRoot 'headless-sample-vi-corpus-evaluation.json'
    $reportPath | Should -Exist
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.overallStatus | Should -Be 'drift'

    $targetReport = @($report.targets | Where-Object { [string]$_.id -eq 'icon-editor-demo-vip-preinstall-history' } | Select-Object -First 1)
    $targetReport | Should -Not -BeNullOrEmpty
    $targetReport.status | Should -Be 'drift'
    $targetReport.checks.licenseDeclared | Should -BeFalse
    (($targetReport.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Accepted targets require a declared license'
  }

  It 'fails closed when a print-single-file target is marked accepted before its custom payload becomes promotable' {
    $catalog = Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json -Depth 20
    $target = @($catalog.targets | Where-Object { [string]$_.id -eq 'linuxcontainerdemo-newthing-print' } | Select-Object -First 1)
    $target | Should -Not -BeNullOrEmpty
    $target.admission.state = 'accepted'
    $target.source.licenseSpdx = 'MIT'

    $driftCatalogPath = Join-Path $TestDrive 'sample-corpus.print-payload-drift.json'
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $driftCatalogPath -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'sample-corpus-print-payload-drift'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:EvaluateScript -CatalogPath $driftCatalogPath -ResultsRoot $resultsRoot -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $outputText = ($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $outputText | Should -Match 'detected drift'

    $reportPath = Join-Path $resultsRoot 'headless-sample-vi-corpus-evaluation.json'
    $reportPath | Should -Exist
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    $report.overallStatus | Should -Be 'drift'

    $targetReport = @($report.targets | Where-Object { [string]$_.id -eq 'linuxcontainerdemo-newthing-print' } | Select-Object -First 1)
    $targetReport | Should -Not -BeNullOrEmpty
    $targetReport.status | Should -Be 'drift'
    $targetReport.checks.operationPayloadPromotable | Should -BeFalse
    (($targetReport.notes | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) | Should -Match 'Accepted targets require a promotable custom operation payload'
  }
}
