Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Invoke-OfflineRealHistoryCorpusEvaluation.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:EvaluateScript = Join-Path $script:RepoRoot 'tools' 'Invoke-OfflineRealHistoryCorpusEvaluation.ps1'
    if (-not (Test-Path -LiteralPath $script:EvaluateScript -PathType Leaf)) {
      throw "Invoke-OfflineRealHistoryCorpusEvaluation.ps1 not found at $script:EvaluateScript"
    }

    $script:CorpusPath = Join-Path $script:RepoRoot 'fixtures' 'real-history' 'offline-corpus.normalized.json'
    $script:ResolveEvaluationOutputPath = {
      param([Parameter(Mandatory)][string]$PathValue)

      if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
      }

      return (Join-Path $script:RepoRoot ($PathValue -replace '/', '\'))
    }
  }

  It 'passes against the checked-in corpus and records report coverage checks' {
    $resultsRoot = Join-Path $TestDrive 'offline-corpus-eval'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:EvaluateScript `
      -ResultsRoot $resultsRoot 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $reportPath = Join-Path $resultsRoot 'offline-real-history-corpus-evaluation.json'
    $reportPath | Should -Exist

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 12
    $report.schema | Should -Be 'vi-history/offline-real-history-corpus-evaluation@v1'
    $report.overallStatus | Should -Be 'ok'

    $target = @($report.targets | Where-Object { [string]$_.id -eq 'icon-editor-settings-init' } | Select-Object -First 1)
    $target | Should -Not -BeNullOrEmpty
    $target.status | Should -Be 'ok'
    $target.expected.coverageClass | Should -Be 'catalog-partial'
    $target.expected.modeSensitivity | Should -Be 'single-mode-observed'
    @($target.expected.outcomeLabels) | Should -Be @('clean', 'signal-diff')

    $target.observed.markdown.coverageClass | Should -BeTrue
    $target.observed.markdown.modeSensitivity | Should -BeTrue
    $target.observed.markdown.outcomeLabels | Should -BeTrue
    $target.observed.html.coverageClass | Should -BeTrue
    $target.observed.html.modeSensitivity | Should -BeTrue
    $target.observed.html.outcomeLabels | Should -BeTrue
    $target.observed.stepSummary.coverageClass | Should -BeTrue
    $target.observed.stepSummary.modeSensitivity | Should -BeTrue
    $target.observed.stepSummary.outcomeLabels | Should -BeTrue

    $markdownPath = & $script:ResolveEvaluationOutputPath ([string]$target.outputs.markdownPath)
    $htmlPath = & $script:ResolveEvaluationOutputPath ([string]$target.outputs.htmlPath)
    $stepSummaryPath = & $script:ResolveEvaluationOutputPath ([string]$target.outputs.stepSummaryPath)
    $markdownPath | Should -Exist
    $htmlPath | Should -Exist
    $stepSummaryPath | Should -Exist

    $markdown = Get-Content -LiteralPath $markdownPath -Raw
    $markdown | Should -Match '## Observed interpretation'
    $markdown | Should -Match '\| Coverage Class \| `catalog-partial` \|'
    $markdown | Should -Match '\| Mode Sensitivity \| `single-mode-observed` \|'
    $markdown | Should -Match '\| Outcome Labels \| `clean`, `signal-diff` \|'
  }

  It 'detects drift when corpus expectations no longer match the rendered report' {
    $corpus = Get-Content -LiteralPath $script:CorpusPath -Raw | ConvertFrom-Json -Depth 20
    $corpusTarget = @($corpus.targets | Where-Object { [string]$_.id -eq 'icon-editor-settings-init' } | Select-Object -First 1)
    $corpusTarget | Should -Not -BeNullOrEmpty
    $corpusTarget.annotations.coverageClass = 'catalog-aligned'
    $driftCorpusPath = Join-Path $TestDrive 'offline-corpus.drift.json'
    $corpus | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $driftCorpusPath -Encoding utf8

    $resultsRoot = Join-Path $TestDrive 'offline-corpus-drift'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:EvaluateScript `
      -CorpusPath $driftCorpusPath `
      -ResultsRoot $resultsRoot `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Not -Be 0

    $outputText = ($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $outputText | Should -Match 'detected report drift'

    $reportPath = Join-Path $resultsRoot 'offline-real-history-corpus-evaluation.json'
    $reportPath | Should -Exist
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 12
    $report.overallStatus | Should -Be 'drift'

    $target = @($report.targets | Where-Object { [string]$_.id -eq 'icon-editor-settings-init' } | Select-Object -First 1)
    $target | Should -Not -BeNullOrEmpty
    $target.status | Should -Be 'drift'
    $target.observed.markdown.coverageClass | Should -BeFalse
    ((@($target.notes)) -join [Environment]::NewLine) | Should -Match 'coverageClass'
  }
}
