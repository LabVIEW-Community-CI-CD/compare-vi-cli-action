Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Normalize-OfflineRealHistoryCorpus.ps1' -Tag 'Unit' {
  BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:NormalizeScript = Join-Path $script:RepoRoot 'tools' 'Normalize-OfflineRealHistoryCorpus.ps1'
    if (-not (Test-Path -LiteralPath $script:NormalizeScript -PathType Leaf)) {
      throw "Normalize-OfflineRealHistoryCorpus.ps1 not found at $script:NormalizeScript"
    }
  }

  It 'rebuilds the checked-in normalized corpus without drift' {
    $outputPath = Join-Path $TestDrive 'offline-corpus.normalized.json'
    $runOutput = & pwsh -NoLogo -NoProfile -File $script:NormalizeScript `
      -OutputPath $outputPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $expectedPath = Join-Path $script:RepoRoot 'fixtures' 'real-history' 'offline-corpus.normalized.json'
    $expectedPath | Should -Exist
    $outputPath | Should -Exist

    (Get-Content -LiteralPath $outputPath -Raw) | Should -BeExactly (Get-Content -LiteralPath $expectedPath -Raw)

    $schemaPath = Join-Path $script:RepoRoot 'docs' 'schemas' 'offline-real-history-corpus-v1.schema.json'
    $schemaValidation = & node (Join-Path $script:RepoRoot 'tools' 'npm' 'run-script.mjs') 'schema:validate' '--' '--schema' $schemaPath '--data' $outputPath 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($schemaValidation | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  }

  It 'tracks deterministic labels and capture summaries in the checked-in corpus fixture' {
    $corpusPath = Join-Path $script:RepoRoot 'fixtures' 'real-history' 'offline-corpus.normalized.json'
    $corpus = Get-Content -LiteralPath $corpusPath -Raw | ConvertFrom-Json -Depth 32 -DateKind String

    $corpus.schema | Should -Be 'vi-history/offline-real-history-corpus@v1'
    $corpus.storageBoundary.normalizedPath | Should -Be 'fixtures/real-history/offline-corpus.normalized.json'

    $target = @($corpus.targets | Where-Object { [string]$_.id -eq 'icon-editor-settings-init' })[0]
    @($target.annotations.outcomeLabels) | Should -Be @('clean', 'signal-diff')
    $target.annotations.modeSensitivity | Should -Be 'single-mode-observed'
    $target.annotations.coverageClass | Should -Be 'catalog-partial'
    @($target.annotations.bucketProfile) | Should -Be @('metadata')
    $target.captureSummary.presence | Should -Be 'dual-capture'
    @($target.captureSummary.lvcompareExitCodes) | Should -Be @(1)
    @($target.captureSummary.niStatuses) | Should -Be @('diff')
    @($target.provenance.lvcompareCapturePaths) | Should -Be @(
      'fixtures/cross-repo/labview-icon-editor/settings-init/default/pair-002-artifacts/lvcompare-capture.json'
    )

    $mode = @($target.modes | Where-Object { [string]$_.mode -eq 'default' })[0]
    $mode.annotations.outcomeClass | Should -Be 'signal-diff'
    @($mode.annotations.comparisonClasses) | Should -Be @('clean', 'signal-diff')
    @($mode.annotations.bucketProfile) | Should -Be @('metadata')
    $mode.captureSummary.presence | Should -Be 'dual-capture'

    @($mode.comparisons | ForEach-Object { [string]$_.annotations.outcomeClass }) | Should -Be @('clean', 'signal-diff')
  }

  It 'derives noise, error, and mixed-mode labels from synthetic history manifests' {
    $harnessRoot = Join-Path $TestDrive 'normalize-harness'
    $toolsDir = Join-Path $harnessRoot 'tools'
    $fixturesDir = Join-Path $harnessRoot 'fixtures' 'real-history'
    $syntheticFixtureDir = Join-Path $harnessRoot 'fixtures' 'cross-repo' 'synthetic'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $fixturesDir -Force | Out-Null
    New-Item -ItemType Directory -Path $syntheticFixtureDir -Force | Out-Null

    Copy-Item -LiteralPath $script:NormalizeScript -Destination (Join-Path $toolsDir 'Normalize-OfflineRealHistoryCorpus.ps1') -Force

    $catalog = [ordered]@{
      '$schema' = '../../docs/schemas/offline-real-history-corpus-targets-v1.schema.json'
      schema = 'vi-history/offline-real-history-targets@v1'
      generatedAt = '2026-03-08T00:00:00Z'
      defaultWindowsImage = 'nationalinstruments/labview:2026q1-windows'
      defaultLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      defaultCliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
      defaultComparePolicy = 'cli-only'
      storagePolicy = [ordered]@{
        checkedInCatalogPath = 'fixtures/real-history/offline-corpus.targets.json'
        checkedInNormalizedPath = 'fixtures/real-history/offline-corpus.normalized.json'
        generatedRoot = 'tests/results/offline-real-history'
        rawArtifactsInGit = $false
      }
      targets = @(
        [ordered]@{
          id = 'synthetic-target'
          label = 'Synthetic target'
          repo = [ordered]@{
            slug = 'example/synthetic'
            localPathHints = @('..')
            startRef = 'HEAD'
            endRef = $null
          }
          seedFixture = [ordered]@{
            historySuitePath = 'fixtures/cross-repo/synthetic/manifest.json'
          }
          targetPath = 'Synthetic.vi'
          requestedModes = @('default', 'block-diagram', 'attributes')
          maxPairs = 3
          reportFormat = 'html'
          notes = @('synthetic target')
        }
      )
    }
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $fixturesDir 'offline-corpus.targets.json') -Encoding utf8

    $defaultManifestPath = Join-Path $syntheticFixtureDir 'default-manifest.json'
    $blockDiagramManifestPath = Join-Path $syntheticFixtureDir 'block-diagram-manifest.json'
    $attributesManifestPath = Join-Path $syntheticFixtureDir 'attributes-manifest.json'

    $defaultManifest = [ordered]@{
      schema = 'vi-compare/history@v1'
      generatedAt = '2026-03-08T00:00:01Z'
      mode = 'default'
      flags = @('-nobd', '-noattr')
      stats = [ordered]@{
        processed = 1
        diffs = 1
        signalDiffs = 0
        noiseCollapsed = 1
        errors = 0
        missing = 0
        categoryCounts = [ordered]@{ 'vi-attribute' = 1 }
        bucketCounts = [ordered]@{ metadata = 1 }
        collapsedNoise = [ordered]@{
          count = 1
          categoryCounts = [ordered]@{ 'vi-attribute' = 1 }
          bucketCounts = [ordered]@{ metadata = 1 }
        }
      }
      comparisons = @()
      status = 'ok'
    }
    $defaultManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $defaultManifestPath -Encoding utf8

    $blockDiagramManifest = [ordered]@{
      schema = 'vi-compare/history@v1'
      generatedAt = '2026-03-08T00:00:02Z'
      mode = 'block-diagram'
      flags = @('-noattr', '-nofp')
      stats = [ordered]@{
        processed = 1
        diffs = 1
        signalDiffs = 1
        noiseCollapsed = 0
        errors = 0
        missing = 0
        categoryCounts = [ordered]@{ 'Block Diagram' = 1 }
        bucketCounts = [ordered]@{ 'functional-behavior' = 1 }
      }
      comparisons = @(
        [ordered]@{
          index = 1
          base = [ordered]@{ ref = 'base-1' }
          head = [ordered]@{ ref = 'head-1' }
          result = [ordered]@{
            diff = $true
            classification = 'signal'
            bucket = 'functional-behavior'
            categories = @('Block Diagram')
          }
        }
      )
      status = 'ok'
    }
    $blockDiagramManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $blockDiagramManifestPath -Encoding utf8

    $attributesManifest = [ordered]@{
      schema = 'vi-compare/history@v1'
      generatedAt = '2026-03-08T00:00:03Z'
      mode = 'attributes'
      flags = @('-nobd')
      stats = [ordered]@{
        processed = 1
        diffs = 0
        signalDiffs = 0
        noiseCollapsed = 0
        errors = 1
        missing = 0
        categoryCounts = [ordered]@{}
        bucketCounts = [ordered]@{}
      }
      comparisons = @(
        [ordered]@{
          index = 1
          base = [ordered]@{ ref = 'base-2' }
          head = [ordered]@{ ref = 'head-2' }
          error = 'LVCompare crashed'
        }
      )
      status = 'error'
    }
    $attributesManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $attributesManifestPath -Encoding utf8

    $suiteManifest = [ordered]@{
      schema = 'vi-compare/history-suite@v1'
      generatedAt = '2026-03-08T00:00:04Z'
      targetPath = 'Synthetic.vi'
      requestedModes = @('default', 'block-diagram', 'attributes')
      executedModes = @('default', 'block-diagram', 'attributes')
      modes = @(
        [ordered]@{
          name = 'default'
          slug = 'default'
          reportFormat = 'html'
          flags = @('-nobd', '-noattr')
          manifestPath = 'fixtures/cross-repo/synthetic/default-manifest.json'
          resultsDir = 'fixtures/cross-repo/synthetic/default'
          stats = $defaultManifest.stats
          status = 'ok'
        },
        [ordered]@{
          name = 'block-diagram'
          slug = 'block-diagram'
          reportFormat = 'html'
          flags = @('-noattr', '-nofp')
          manifestPath = 'fixtures/cross-repo/synthetic/block-diagram-manifest.json'
          resultsDir = 'fixtures/cross-repo/synthetic/block-diagram'
          stats = $blockDiagramManifest.stats
          status = 'ok'
        },
        [ordered]@{
          name = 'attributes'
          slug = 'attributes'
          reportFormat = 'html'
          flags = @('-nobd')
          manifestPath = 'fixtures/cross-repo/synthetic/attributes-manifest.json'
          resultsDir = 'fixtures/cross-repo/synthetic/attributes'
          stats = $attributesManifest.stats
          status = 'error'
        }
      )
      stats = [ordered]@{
        processed = 3
        diffs = 2
        signalDiffs = 1
        noiseCollapsed = 1
        errors = 1
        missing = 0
        categoryCounts = [ordered]@{
          'vi-attribute' = 1
          'Block Diagram' = 1
        }
        bucketCounts = [ordered]@{
          metadata = 1
          'functional-behavior' = 1
        }
      }
      status = 'error'
    }
    $suiteManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $syntheticFixtureDir 'manifest.json') -Encoding utf8

    $outputPath = Join-Path $harnessRoot 'fixtures' 'real-history' 'offline-corpus.normalized.json'
    $runOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Normalize-OfflineRealHistoryCorpus.ps1') `
      -CatalogPath 'fixtures/real-history/offline-corpus.targets.json' `
      -OutputPath 'fixtures/real-history/offline-corpus.normalized.json' `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 32 -DateKind String
    $target = @($output.targets | Where-Object { [string]$_.id -eq 'synthetic-target' })[0]
    $target.annotations.modeSensitivity | Should -Be 'mixed-observed-modes'
    $target.annotations.coverageClass | Should -Be 'catalog-aligned'
    @($target.annotations.outcomeLabels) | Should -Be @('error', 'noise-diff', 'signal-diff')
    $target.captureSummary.presence | Should -Be 'none'

    $defaultMode = @($target.modes | Where-Object { [string]$_.mode -eq 'default' })[0]
    $defaultMode.annotations.outcomeClass | Should -Be 'noise-diff'
    @($defaultMode.annotations.comparisonClasses) | Should -Be @('noise-diff')

    $attributesMode = @($target.modes | Where-Object { [string]$_.mode -eq 'attributes' })[0]
    $attributesMode.annotations.outcomeClass | Should -Be 'error'
    @($attributesMode.comparisons | ForEach-Object { [string]$_.annotations.outcomeClass }) | Should -Be @('error')
  }

  It 'preserves absolute capture paths outside the repo root when they only share a prefix' {
    $harnessRoot = Join-Path $TestDrive 'normalize-prefix'
    $externalRoot = Join-Path $TestDrive 'normalize-prefix-external'
    $toolsDir = Join-Path $harnessRoot 'tools'
    $fixturesDir = Join-Path $harnessRoot 'fixtures' 'real-history'
    $syntheticFixtureDir = Join-Path $harnessRoot 'fixtures' 'cross-repo' 'prefix'
    $externalCaptureDir = Join-Path $externalRoot 'captures'
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $fixturesDir -Force | Out-Null
    New-Item -ItemType Directory -Path $syntheticFixtureDir -Force | Out-Null
    New-Item -ItemType Directory -Path $externalCaptureDir -Force | Out-Null

    Copy-Item -LiteralPath $script:NormalizeScript -Destination (Join-Path $toolsDir 'Normalize-OfflineRealHistoryCorpus.ps1') -Force

    $catalog = [ordered]@{
      '$schema' = '../../docs/schemas/offline-real-history-corpus-targets-v1.schema.json'
      schema = 'vi-history/offline-real-history-targets@v1'
      generatedAt = '2026-03-08T00:00:00Z'
      defaultWindowsImage = 'nationalinstruments/labview:2026q1-windows'
      defaultLabVIEWPath = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
      defaultCliPath = 'C:\Program Files\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
      defaultComparePolicy = 'cli-only'
      storagePolicy = [ordered]@{
        checkedInCatalogPath = 'fixtures/real-history/offline-corpus.targets.json'
        checkedInNormalizedPath = 'fixtures/real-history/offline-corpus.normalized.json'
        generatedRoot = 'tests/results/offline-real-history'
        rawArtifactsInGit = $false
      }
      targets = @(
        [ordered]@{
          id = 'prefix-target'
          label = 'Prefix target'
          repo = [ordered]@{
            slug = 'example/prefix'
            localPathHints = @('..')
            startRef = 'HEAD'
            endRef = $null
          }
          seedFixture = [ordered]@{
            historySuitePath = 'fixtures/cross-repo/prefix/manifest.json'
            captureRoots = @($externalCaptureDir)
          }
          targetPath = 'Prefix.vi'
          requestedModes = @('default')
          maxPairs = 1
          reportFormat = 'html'
          notes = @('prefix target')
        }
      )
    }
    $catalog | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $fixturesDir 'offline-corpus.targets.json') -Encoding utf8

    $modeManifest = [ordered]@{
      schema = 'vi-compare/history@v1'
      generatedAt = '2026-03-08T00:00:01Z'
      mode = 'default'
      flags = @('-nobd')
      stats = [ordered]@{
        processed = 1
        diffs = 0
        signalDiffs = 0
        noiseCollapsed = 0
        errors = 0
        missing = 0
        categoryCounts = [ordered]@{}
        bucketCounts = [ordered]@{}
      }
      comparisons = @()
      status = 'ok'
    }
    $modeManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $syntheticFixtureDir 'default-manifest.json') -Encoding utf8

    $suiteManifest = [ordered]@{
      schema = 'vi-compare/history-suite@v1'
      generatedAt = '2026-03-08T00:00:02Z'
      targetPath = 'Prefix.vi'
      requestedModes = @('default')
      executedModes = @('default')
      modes = @(
        [ordered]@{
          name = 'default'
          slug = 'default'
          reportFormat = 'html'
          flags = @('-nobd')
          manifestPath = 'fixtures/cross-repo/prefix/default-manifest.json'
          resultsDir = 'fixtures/cross-repo/prefix/default'
          stats = $modeManifest.stats
          status = 'ok'
        }
      )
      stats = [ordered]@{
        processed = 1
        diffs = 0
        signalDiffs = 0
        noiseCollapsed = 0
        errors = 0
        missing = 0
        categoryCounts = [ordered]@{}
        bucketCounts = [ordered]@{}
      }
      status = 'ok'
    }
    $suiteManifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $syntheticFixtureDir 'manifest.json') -Encoding utf8

    ([ordered]@{
      schema = 'lvcompare-capture-v1'
      timestamp = '2026-03-08T00:00:03Z'
      cli = [ordered]@{
        diff = $false
        exitCode = 0
      }
    } | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $externalCaptureDir 'lvcompare-capture.json') -Encoding utf8

    $outputPath = Join-Path $harnessRoot 'fixtures' 'real-history' 'offline-corpus.normalized.json'
    $runOutput = & pwsh -NoLogo -NoProfile -File (Join-Path $toolsDir 'Normalize-OfflineRealHistoryCorpus.ps1') `
      -CatalogPath 'fixtures/real-history/offline-corpus.targets.json' `
      -OutputPath 'fixtures/real-history/offline-corpus.normalized.json' `
      -SkipSchemaValidation 2>&1
    $LASTEXITCODE | Should -Be 0 -Because (($runOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)

    $output = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json -Depth 32 -DateKind String
    $target = @($output.targets | Where-Object { [string]$_.id -eq 'prefix-target' })[0]
    $capturePath = @($target.provenance.lvcompareCapturePaths)[0]

    $capturePath | Should -Match '^[A-Za-z]:/'
    $capturePath | Should -Match '/normalize-prefix-external/'
  }
}
