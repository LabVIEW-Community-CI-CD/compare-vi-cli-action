Describe 'CompareVI.Tools artifact publishing' -Tag 'REQ:DOTNET_CLI_RELEASE_ASSET','REQ:DOTNET_CLI_RELEASE_CHECKLIST' {
  BeforeAll {
    $candidateRoots = @()
    foreach ($candidate in @($PSScriptRoot, $PSCommandPath, (Get-Location).Path)) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }

      $resolved = $candidate
      if (Test-Path -LiteralPath $candidate) {
        $item = Get-Item -LiteralPath $candidate
        $resolved = if ($item.PSIsContainer) { $item.FullName } else { Split-Path -Parent $item.FullName }
      }
      $candidateRoots += $resolved
    }

    $repoRoot = $null
    foreach ($root in $candidateRoots | Select-Object -Unique) {
      $cursor = $root
      while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        $marker = Join-Path $cursor 'tools' 'Publish-CompareVIToolsArtifact.ps1'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
          $repoRoot = $cursor
          break
        }

        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) {
          break
        }
        $cursor = $parent
      }

      if ($repoRoot) {
        break
      }
    }

    if (-not $repoRoot) {
      throw 'Unable to resolve repository root for CompareVI.Tools artifact tests.'
    }

    $publishScript = Join-Path $repoRoot 'tools' 'Publish-CompareVIToolsArtifact.ps1'
    $modulePath = Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1'
    $schemaScript = Join-Path $repoRoot 'tools' 'Invoke-JsonSchemaLite.ps1'
    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'comparevi-tools-release-manifest-v1.schema.json'
    $moduleManifest = Import-PowerShellDataFile -LiteralPath $modulePath
    $moduleVersion = [string]$moduleManifest.ModuleVersion
    $modulePrerelease = if ($moduleManifest.ContainsKey('PrivateData') -and $moduleManifest.PrivateData.PSData.ContainsKey('Prerelease')) {
      [string]$moduleManifest.PrivateData.PSData.Prerelease
    } else {
      ''
    }
    $moduleReleaseVersion = if ([string]::IsNullOrWhiteSpace($modulePrerelease)) {
      $moduleVersion
    } else {
      "$moduleVersion-$modulePrerelease"
    }
  }

  It 'writes a self-contained release zip and metadata manifest' {
    $outDir = Join-Path $TestDrive 'artifacts'
    $metadataPath = Join-Path $TestDrive 'comparevi-tools-artifact.json'

    & $publishScript `
      -OutputRoot $outDir `
      -MetadataReportPath $metadataPath `
      -Repository 'owner/repo' `
      -SourceRef 'refs/tags/v9.9.9' `
      -SourceSha '0123456789abcdef0123456789abcdef01234567' `
      -ReleaseTag 'v9.9.9'

    Test-Path -LiteralPath $metadataPath | Should -BeTrue
    & $schemaScript -JsonPath $metadataPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.schema | Should -Be 'comparevi-tools-release-manifest@v1'
    $metadata.module.name | Should -Be 'CompareVI.Tools'
    $metadata.module.version | Should -Be $moduleVersion
    $metadata.module.releaseVersion | Should -Be $moduleReleaseVersion
    @($metadata.module.exportedFunctions) | Should -Contain 'Invoke-CompareVIHistoryFacade'
    @($metadata.module.exportedFunctions) | Should -Contain 'Invoke-CompareVIHistoryLocalRefinementFacade'
    @($metadata.module.exportedFunctions) | Should -Contain 'Invoke-CompareVIHistoryLocalOperatorSessionFacade'
    $metadata.source.repository | Should -Be 'owner/repo'
    $metadata.source.ref | Should -Be 'refs/tags/v9.9.9'
    $metadata.source.sha | Should -Be '0123456789abcdef0123456789abcdef01234567'
    $metadata.source.releaseTag | Should -Be 'v9.9.9'
    @($metadata.compatibility.supportedPaths) | Should -Contain 'cross-repo-vi-history-via-hosted-ni-linux-runner'
    $metadata.consumerContract.historyFacade.schema | Should -Be 'comparevi-tools/history-facade@v1'
    $metadata.consumerContract.historyFacade.exportedFunction | Should -Be 'Invoke-CompareVIHistoryFacade'
    $metadata.consumerContract.historyFacade.resultsRelativePath | Should -Be 'history-summary.json'
    @($metadata.consumerContract.historyFacade.stableFields) | Should -Contain 'target.sourceBranchRef'
    @($metadata.consumerContract.historyFacade.stableFields) | Should -Contain 'target.branchBudget'
    $metadata.consumerContract.localRuntimeProfiles.schema | Should -Be 'comparevi-tools/local-refinement-facade@v1'
    $metadata.consumerContract.localRuntimeProfiles.exportedFunction | Should -Be 'Invoke-CompareVIHistoryLocalRefinementFacade'
    $metadata.consumerContract.localRuntimeProfiles.resultsRelativePath | Should -Be 'local-refinement.json'
    $metadata.consumerContract.localRuntimeProfiles.benchmarkRelativePath | Should -Be 'local-refinement-benchmark.json'
    @($metadata.consumerContract.localRuntimeProfiles.runtimeProfiles) | Should -Be @(
      'proof',
      'dev-fast',
      'warm-dev',
      'windows-mirror-proof'
    )
    $metadata.consumerContract.localRuntimeProfiles.defaultProfile | Should -Be 'dev-fast'
    @($metadata.consumerContract.localRuntimeProfiles.stableFields) | Should -Contain 'benchmarkSampleKind'
    @($metadata.consumerContract.localRuntimeProfiles.stableFields) | Should -Contain 'runtimePlane'
    @($metadata.consumerContract.localRuntimeProfiles.stableFields) | Should -Contain 'hostRamBudget'
    @($metadata.consumerContract.localRuntimeProfiles.stableFields) | Should -Contain 'windowsMirror'
    @($metadata.consumerContract.localRuntimeProfiles.stableFields) | Should -Contain 'warmRuntime'
    ((@($metadata.consumerContract.localRuntimeProfiles.notes) -join [Environment]::NewLine)) | Should -Match 'labview-icon-editor-demo'
    ((@($metadata.consumerContract.localRuntimeProfiles.notes) -join [Environment]::NewLine)) | Should -Match 'comparevi-history'
    ((@($metadata.consumerContract.localRuntimeProfiles.notes) -join [Environment]::NewLine)) | Should -Match 'windows-mirror-proof'
    $metadata.consumerContract.localOperatorSession.schema | Should -Be 'comparevi-tools/local-operator-session-facade@v1'
    $metadata.consumerContract.localOperatorSession.exportedFunction | Should -Be 'Invoke-CompareVIHistoryLocalOperatorSessionFacade'
    $metadata.consumerContract.localOperatorSession.resultsRelativePath | Should -Be 'local-operator-session.json'
    @($metadata.consumerContract.localOperatorSession.runtimeProfiles) | Should -Be @(
      'proof',
      'dev-fast',
      'warm-dev',
      'windows-mirror-proof'
    )
    $metadata.consumerContract.localOperatorSession.defaultProfile | Should -Be 'dev-fast'
    @($metadata.consumerContract.localOperatorSession.stableFields) | Should -Contain 'runtimePlane'
    @($metadata.consumerContract.localOperatorSession.stableFields) | Should -Contain 'hostRamBudget'
    @($metadata.consumerContract.localOperatorSession.stableFields) | Should -Contain 'review.outputs'
    ((@($metadata.consumerContract.localOperatorSession.notes) -join [Environment]::NewLine)) | Should -Match 'comparevi-history'
    $metadata.consumerContract.diagnosticsCommentRenderer.entryScriptPath | Should -Be 'tools/New-CompareVIHistoryDiagnosticsBody.ps1'
    @($metadata.consumerContract.diagnosticsCommentRenderer.variants) | Should -Be @(
      'comment-gated',
      'manual'
    )
    $metadata.consumerContract.hostedNiLinuxRunner.entryScriptPath | Should -Be 'tools/Run-NILinuxContainerCompare.ps1'
    @($metadata.consumerContract.hostedNiLinuxRunner.supportScriptPaths) | Should -Be @(
      'tools/Assert-DockerRuntimeDeterminism.ps1',
      'tools/Compare-ExitCodeClassifier.ps1'
    )
    $metadata.consumerContract.hostedNiLinuxRunner.captureFileName | Should -Be 'ni-linux-container-capture.json'
    $metadata.consumerContract.hostedNiLinuxRunner.defaultImage | Should -Be 'nationalinstruments/labview:2026q1-linux'

    $archivePath = Join-Path $outDir $metadata.bundle.archiveName
    Test-Path -LiteralPath $archivePath | Should -BeTrue

    $extractRoot = Join-Path $TestDrive 'extracted'
    Expand-Archive -Path $archivePath -DestinationPath $extractRoot

    $bundleRoot = Join-Path $extractRoot $metadata.bundle.folder
    Test-Path -LiteralPath $bundleRoot | Should -BeTrue

    $bundleReadme = Get-Content -LiteralPath (Join-Path $bundleRoot 'README.md') -Raw
    $bundleReadme | Should -Match 'labview-icon-editor-demo'
    $bundleReadme | Should -Match 'comparevi-history'
    $bundleReadme | Should -Match 'windows-mirror-proof'

    $expectedFiles = @(
      'comparevi-tools-release.json',
      'README.md',
      'tools/CompareVI.Tools/CompareVI.Tools.psd1',
      'tools/CompareVI.Tools/CompareVI.Tools.psm1',
      'tools/Assert-DockerRuntimeDeterminism.ps1',
      'tools/Build-VIHistoryDevImage.ps1',
      'tools/Compare-ExitCodeClassifier.ps1',
      'tools/HostRamBudget.psm1',
      'tools/Compare-VIHistory.ps1',
      'tools/Compare-RefsToTemp.ps1',
      'tools/Invoke-LVCompare.ps1',
      'tools/Invoke-NILinuxReviewSuite.ps1',
      'tools/Invoke-VIHistoryLocalOperatorSession.ps1',
      'tools/Invoke-VIHistoryLocalRefinement.ps1',
      'tools/Manage-VIHistoryRuntimeInDocker.ps1',
      'tools/New-CompareVIHistoryDiagnosticsBody.ps1',
      'tools/Render-VIHistoryReport.ps1',
      'tools/Run-NILinuxContainerCompare.ps1',
      'tools/Run-NIWindowsContainerCompare.ps1',
      'tools/Stage-CompareInputs.ps1',
      'tools/Test-WindowsNI2026q1HostPreflight.ps1',
      'tools/VendorTools.psm1',
      'tools/VICategoryBuckets.psm1',
      'tools/priority/host-ram-budget.mjs',
      'tools/docker/Dockerfile.vi-history-dev',
      'scripts/CompareVI.psm1',
      'scripts/ArgTokenization.psm1'
    )
    foreach ($relativePath in $expectedFiles) {
      $candidate = Join-Path $bundleRoot $relativePath
      Test-Path -LiteralPath $candidate | Should -BeTrue
    }

    $archiveMetadataPath = Join-Path $bundleRoot 'comparevi-tools-release.json'
    $archiveMetadata = Get-Content -LiteralPath $archiveMetadataPath -Raw | ConvertFrom-Json
    $archiveMetadata.bundle.metadataPath | Should -Be 'comparevi-tools-release.json'
    $archiveMetadata.bundle.files.Count | Should -BeGreaterThan 5
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Build-VIHistoryDevImage.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Invoke-VIHistoryLocalOperatorSession.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Invoke-VIHistoryLocalRefinement.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Manage-VIHistoryRuntimeInDocker.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/HostRamBudget.psm1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/priority/host-ram-budget.mjs'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Run-NILinuxContainerCompare.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Run-NIWindowsContainerCompare.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Test-WindowsNI2026q1HostPreflight.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Assert-DockerRuntimeDeterminism.ps1'
    @($archiveMetadata.bundle.files.path) | Should -Contain 'tools/Compare-ExitCodeClassifier.ps1'
  }

  It 'emits an empty prerelease GitHub output for stable CompareVI.Tools bundles' {
    $outDir = Join-Path $TestDrive 'artifacts-github-output'
    $metadataPath = Join-Path $TestDrive 'comparevi-tools-artifact-github-output.json'
    $githubOutputPath = Join-Path $TestDrive 'github-output.txt'

    $originalGitHubOutput = $env:GITHUB_OUTPUT
    try {
      $env:GITHUB_OUTPUT = $githubOutputPath

      & $publishScript `
        -OutputRoot $outDir `
        -MetadataReportPath $metadataPath `
        -Repository 'owner/repo' `
        -SourceRef 'refs/tags/v9.9.9' `
        -SourceSha '0123456789abcdef0123456789abcdef01234567' `
        -ReleaseTag 'v9.9.9' `
        -EmitGitHubOutputs
    } finally {
      if ($null -ne $originalGitHubOutput) {
        $env:GITHUB_OUTPUT = $originalGitHubOutput
      } else {
        Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
      }
    }

    Test-Path -LiteralPath $githubOutputPath | Should -BeTrue
    $outputLines = Get-Content -LiteralPath $githubOutputPath
    $outputLines | Should -Contain "comparevi_tools_module_version=$moduleVersion"
    $outputLines | Should -Contain "comparevi_tools_release_version=$moduleReleaseVersion"
    $outputLines | Should -Contain 'comparevi_tools_module_prerelease='
    @($outputLines | Where-Object { $_ -like 'comparevi_tools_module_prerelease=*' }).Count | Should -Be 1
  }

  It 'exports the bundle root through COMPAREVI_SCRIPTS_ROOT when invoking the module wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'scripts-root.txt'
    @'
param(
  [string]$TargetPath
)
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Compare-VIHistory.ps1') -Encoding utf8

    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      Invoke-CompareVIHistory -TargetPath 'Dummy.vi'
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }

  It 'returns the stabilized history facade when invoking the module facade wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle-facade'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'facade-scripts-root.txt'
    @'
param(
  [string]$TargetPath,
  [string[]]$Mode = @('default'),
  [string]$ResultsDir = 'tests/results/ref-compare/history',
  [string]$GitHubOutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$resolvedResultsDir = (Resolve-Path -LiteralPath $ResultsDir).Path
$summaryPath = Join-Path $resolvedResultsDir 'history-summary.json'
$summary = [ordered]@{
  schema = 'comparevi-tools/history-facade@v1'
  generatedAtUtc = '2026-03-08T00:00:00Z'
  target = [ordered]@{
    path = $TargetPath
    requestedStartRef = 'HEAD'
    effectiveStartRef = 'HEAD'
  }
  execution = [ordered]@{
    status = 'ok'
    reportFormat = 'html'
    resultsDir = $resolvedResultsDir
    manifestPath = (Join-Path $resolvedResultsDir 'manifest.json')
    requestedModes = @('default', 'attributes')
    executedModes = @('default')
  }
  observedInterpretation = [ordered]@{
    coverageClass = 'catalog-partial'
    coverageDetail = 'requested: 2; executed: 1; missing: attributes'
    modeSensitivity = 'single-mode-observed'
    outcomeLabels = @('clean', 'signal-diff')
  }
  summary = [ordered]@{
    modes = 1
    comparisons = 2
    diffs = 1
    signalDiffs = 1
    noiseCollapsed = 0
    missing = 0
    errors = 0
    categories = @('VI Attribute')
    bucketProfile = @('metadata')
    categoryCountKeys = @('vi-attribute')
    bucketCountKeys = @('metadata')
  }
  reports = [ordered]@{
    markdownPath = (Join-Path $resolvedResultsDir 'history-report.md')
    htmlPath = (Join-Path $resolvedResultsDir 'history-report.html')
  }
  modes = @(
    [ordered]@{
      name = 'default'
      slug = 'default'
      status = 'ok'
      processed = 2
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      missing = 0
      errors = 0
      categories = @('VI Attribute')
      bucketProfile = @('metadata')
      flags = @('-nobd')
      manifestPath = (Join-Path $resolvedResultsDir 'default' 'manifest.json')
      resultsDir = (Join-Path $resolvedResultsDir 'default')
    }
  )
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($GitHubOutputPath) {
  "history-summary-json=$summaryPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Compare-VIHistory.ps1') -Encoding utf8

    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      $result = Invoke-CompareVIHistoryFacade -TargetPath 'Dummy.vi' -ResultsDir (Join-Path $TestDrive 'facade-results')
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    $result | Should -Not -BeNullOrEmpty
    $result.schema | Should -Be 'comparevi-tools/history-facade@v1'
    @($result.execution.requestedModes) | Should -Be @('default', 'attributes')
    @($result.execution.executedModes) | Should -Be @('default')
    $result.observedInterpretation.coverageClass | Should -Be 'catalog-partial'
    @($result.observedInterpretation.outcomeLabels) | Should -Be @('clean', 'signal-diff')
    @($result.modes | ForEach-Object { [string]$_.slug }) | Should -Be @('default')

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }

  It 'returns the stabilized local refinement facade when invoking the module wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle-local-refinement-facade'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    $downstreamRepoRoot = Join-Path $TestDrive 'downstream-repo'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $downstreamRepoRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $downstreamRepoRoot 'fixtures/vi-attr') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $downstreamRepoRoot 'fixtures/vi-attr/Base.vi') -Value 'base' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $downstreamRepoRoot 'fixtures/vi-attr/Head.vi') -Value 'head' -Encoding utf8

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'local-refinement-scripts-root.txt'
    @'
param(
  [string]$Profile = 'dev-fast',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  (Get-Location).Path
} elseif ([System.IO.Path]::IsPathRooted($RepoRoot)) {
  [System.IO.Path]::GetFullPath($RepoRoot)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $RepoRoot))
}
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/warm-dev'
} elseif ([System.IO.Path]::IsPathRooted($ResultsRoot)) {
  [System.IO.Path]::GetFullPath($ResultsRoot)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $ResultsRoot))
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$receiptPath = Join-Path $resolvedResultsRoot 'local-refinement.json'
$benchmarkPath = Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json'
$receipt = [ordered]@{
  schema = 'comparevi/local-refinement@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  image = 'comparevi-vi-history-dev:local'
  toolSource = 'local-dev-image'
  cacheReuseState = 'warm-runtime-reused'
  coldWarmClass = 'warm'
  benchmarkSampleKind = 'warm-dev-repeat'
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  timings = [ordered]@{
    elapsedMilliseconds = 1234
    elapsedSeconds = 1.234
  }
  history = [ordered]@{
    targetPath = (Join-Path $resolvedRepoRoot 'fixtures/vi-attr/Head.vi')
    branchRef = 'HEAD'
    baselineRef = ''
    maxPairs = 2
    maxCommitCount = 64
  }
  reviewSuite = [ordered]@{
    schema = 'ni-linux-review-suite@v1'
    image = 'comparevi-vi-history-dev:local'
    scenarioCount = 1
    summaryPath = (Join-Path $resolvedResultsRoot 'review-suite-summary.json')
  }
  reviewLoop = [ordered]@{
    schema = 'ni-linux-review-suite-review-loop@v1'
    path = (Join-Path $resolvedResultsRoot 'vi-history-review-loop-receipt.json')
  }
  warmRuntime = [ordered]@{
    schema = 'comparevi/local-runtime-state@v1'
    action = 'reconcile'
    outcome = 'healthy'
    container = [ordered]@{
      name = 'warm-stub'
      image = 'comparevi-vi-history-dev:local'
    }
    artifacts = [ordered]@{
      statePath = (Join-Path $resolvedResultsRoot 'runtime/local-runtime-state.json')
      leasePath = (Join-Path $resolvedResultsRoot 'runtime/local-runtime-lease.json')
      healthPath = (Join-Path $resolvedResultsRoot 'runtime/local-runtime-health.json')
      heartbeatPath = (Join-Path $resolvedResultsRoot 'runtime/local-runtime-heartbeat.json')
    }
  }
  hostRamBudget = [ordered]@{
    path = (Join-Path $resolvedResultsRoot 'runtime/host-ram-budget.json')
    targetProfile = 'heavy'
    requestedParallelism = 0
    recommendedParallelism = 2
    actualParallelism = 1
    decisionSource = 'host-ram-budget'
    reason = 'warm-runtime-single-container'
  }
  finalStatus = 'succeeded'
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -Encoding utf8
[ordered]@{
  schema = 'comparevi/local-refinement-benchmark@v1'
  generatedAt = '2026-03-19T00:00:01Z'
  latest = [ordered]@{}
  selectedSamples = [ordered]@{}
  comparisons = [ordered]@{}
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $benchmarkPath -Encoding utf8
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Invoke-VIHistoryLocalRefinement.ps1') -Encoding utf8

    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'comparevi-tools-local-refinement-facade-v1.schema.json'
    $schemaReportPath = Join-Path $TestDrive 'local-refinement-facade.json'
    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      Push-Location $downstreamRepoRoot
      try {
        $result = Invoke-CompareVIHistoryLocalRefinementFacade -Profile 'warm-dev'
      } finally {
        Pop-Location | Out-Null
      }
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    $result | Should -Not -BeNullOrEmpty
    $result.schema | Should -Be 'comparevi-tools/local-refinement-facade@v1'
    $result.backendReceiptSchema | Should -Be 'comparevi/local-refinement@v1'
    $result.runtimeProfile | Should -Be 'warm-dev'
    $result.benchmarkSampleKind | Should -Be 'warm-dev-repeat'
    $result.hostRamBudget.reason | Should -Be 'warm-runtime-single-container'
    $result.repoRoot | Should -Be $downstreamRepoRoot
    $result.warmRuntime.container.name | Should -Be 'warm-stub'
    $result.artifacts.localRefinementPath | Should -Be (Join-Path $downstreamRepoRoot 'tests/results/local-vi-history/warm-dev/local-refinement.json')
    $result.artifacts.benchmarkPath | Should -Be (Join-Path $downstreamRepoRoot 'tests/results/local-vi-history/warm-dev/local-refinement-benchmark.json')
    $result.artifacts.hostRamBudgetPath | Should -Be (Join-Path $downstreamRepoRoot 'tests/results/local-vi-history/warm-dev/runtime/host-ram-budget.json')

    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $schemaReportPath -Encoding utf8
    & $schemaScript -JsonPath $schemaReportPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }

  It 'returns the stabilized local operator session facade when invoking the module wrapper' {
    $bundleRoot = Join-Path $TestDrive 'bundle-local-operator-session-facade'
    $moduleRoot = Join-Path $bundleRoot 'tools' 'CompareVI.Tools'
    $toolsRoot = Join-Path $bundleRoot 'tools'
    $downstreamRepoRoot = Join-Path $TestDrive 'downstream-operator-repo'
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $downstreamRepoRoot -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psd1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psd1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tools' 'CompareVI.Tools' 'CompareVI.Tools.psm1') -Destination (Join-Path $moduleRoot 'CompareVI.Tools.psm1')

    $capturePath = Join-Path $TestDrive 'local-operator-session-scripts-root.txt'
    @'
param(
  [string]$Profile = 'dev-fast',
  [string]$RepoRoot = '',
  [string]$ResultsRoot = '',
  [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath $env:COMPAREVI_CAPTURE_PATH -Value $env:COMPAREVI_SCRIPTS_ROOT -Encoding utf8
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  (Get-Location).Path
} elseif ([System.IO.Path]::IsPathRooted($RepoRoot)) {
  [System.IO.Path]::GetFullPath($RepoRoot)
} else {
  [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $RepoRoot))
}
$resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
  Join-Path $resolvedRepoRoot 'tests/results/local-vi-history/dev-fast'
} elseif ([System.IO.Path]::IsPathRooted($ResultsRoot)) {
  [System.IO.Path]::GetFullPath($ResultsRoot)
} else {
  [System.IO.Path]::GetFullPath((Join-Path $resolvedRepoRoot $ResultsRoot))
}
New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null
$sessionPath = Join-Path $resolvedResultsRoot 'local-operator-session.json'
$receipt = [ordered]@{
  schema = 'comparevi/local-operator-session@v1'
  generatedAt = '2026-03-19T00:00:00Z'
  runtimeProfile = $Profile
  repoRoot = $resolvedRepoRoot
  resultsRoot = $resolvedResultsRoot
  localRefinement = [ordered]@{
    schema = 'comparevi/local-refinement@v1'
    receiptPath = (Join-Path $resolvedResultsRoot 'local-refinement.json')
    benchmarkPath = (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json')
    image = 'comparevi-vi-history-dev:local'
    toolSource = 'local-dev-image'
    cacheReuseState = 'existing-local-image'
    coldWarmClass = 'warm'
    benchmarkSampleKind = 'dev-fast-repeat'
    hostRamBudget = [ordered]@{
      path = (Join-Path $resolvedResultsRoot 'host-ram-budget.json')
      targetProfile = 'heavy'
      requestedParallelism = 0
      recommendedParallelism = 3
      actualParallelism = 1
      decisionSource = 'host-ram-budget'
      reason = 'single-review-execution'
    }
    timings = [ordered]@{
      elapsedMilliseconds = 1000
      elapsedSeconds = 1.0
    }
    finalStatus = 'succeeded'
  }
  hostRamBudget = [ordered]@{
    path = (Join-Path $resolvedResultsRoot 'host-ram-budget.json')
    targetProfile = 'heavy'
    requestedParallelism = 0
    recommendedParallelism = 3
    actualParallelism = 1
    decisionSource = 'host-ram-budget'
    reason = 'single-review-execution'
  }
  review = [ordered]@{
    status = 'succeeded'
    commandPath = (Join-Path $resolvedRepoRoot 'scripts/local-review.ps1')
    arguments = @('--profile', 'dev-fast')
    workingDirectory = $resolvedRepoRoot
    timings = [ordered]@{
      elapsedMilliseconds = 200
      elapsedSeconds = 0.2
    }
    outputs = [ordered]@{
      receiptPath = (Join-Path $resolvedResultsRoot 'local-review.json')
      reviewBundlePath = (Join-Path $resolvedResultsRoot 'review-bundle.json')
      workspaceHtmlPath = (Join-Path $resolvedResultsRoot 'index.html')
      workspaceMarkdownPath = (Join-Path $resolvedResultsRoot 'index.md')
      previewManifestPath = (Join-Path $resolvedResultsRoot 'pr-preview-manifest.json')
      runPath = (Join-Path $resolvedResultsRoot 'pr-run.json')
    }
  }
  artifacts = [ordered]@{
    sessionPath = $sessionPath
    localRefinementPath = (Join-Path $resolvedResultsRoot 'local-refinement.json')
    benchmarkPath = (Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json')
    hostRamBudgetPath = (Join-Path $resolvedResultsRoot 'host-ram-budget.json')
    warmRuntimeStatePath = $null
    warmRuntimeHealthPath = $null
    warmRuntimeLeasePath = $null
    reviewReceiptPath = (Join-Path $resolvedResultsRoot 'local-review.json')
    reviewBundlePath = (Join-Path $resolvedResultsRoot 'review-bundle.json')
    workspaceHtmlPath = (Join-Path $resolvedResultsRoot 'index.html')
    workspaceMarkdownPath = (Join-Path $resolvedResultsRoot 'index.md')
    previewManifestPath = (Join-Path $resolvedResultsRoot 'pr-preview-manifest.json')
    runPath = (Join-Path $resolvedResultsRoot 'pr-run.json')
  }
  finalStatus = 'succeeded'
  failure = $null
}
$receipt | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $sessionPath -Encoding utf8
if ($PassThru) {
  [pscustomobject]$receipt
}
'@ | Set-Content -LiteralPath (Join-Path $toolsRoot 'Invoke-VIHistoryLocalOperatorSession.ps1') -Encoding utf8

    $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'comparevi-tools-local-operator-session-facade-v1.schema.json'
    $schemaReportPath = Join-Path $TestDrive 'local-operator-session-facade.json'
    $env:COMPAREVI_CAPTURE_PATH = $capturePath
    try {
      Import-Module (Join-Path $moduleRoot 'CompareVI.Tools.psd1') -Force
      Push-Location $downstreamRepoRoot
      try {
        $result = Invoke-CompareVIHistoryLocalOperatorSessionFacade -Profile 'dev-fast'
      } finally {
        Pop-Location | Out-Null
      }
    } finally {
      Remove-Module CompareVI.Tools -Force -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_CAPTURE_PATH -ErrorAction SilentlyContinue
      Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
    }

    $result | Should -Not -BeNullOrEmpty
    $result.schema | Should -Be 'comparevi-tools/local-operator-session-facade@v1'
    $result.backendReceiptSchema | Should -Be 'comparevi/local-operator-session@v1'
    $result.runtimeProfile | Should -Be 'dev-fast'
    $result.hostRamBudget.reason | Should -Be 'single-review-execution'
    $result.review.status | Should -Be 'succeeded'
    $result.review.outputs.reviewBundlePath | Should -Be (Join-Path $downstreamRepoRoot 'tests/results/local-vi-history/dev-fast/review-bundle.json')
    $result.artifacts.sessionPath | Should -Be (Join-Path $downstreamRepoRoot 'tests/results/local-vi-history/dev-fast/local-operator-session.json')

    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $schemaReportPath -Encoding utf8
    & $schemaScript -JsonPath $schemaReportPath -SchemaPath $schemaPath
    $LASTEXITCODE | Should -Be 0

    Test-Path -LiteralPath $capturePath | Should -BeTrue
    $capturedRoot = (Get-Content -LiteralPath $capturePath -Raw).Trim()
    $capturedRoot | Should -Be $bundleRoot
  }

  It 'ships the reusable comparevi-history diagnostics body helper in the published bundle' {
    $outDir = Join-Path $TestDrive 'artifacts-helper'
    $metadataPath = Join-Path $TestDrive 'comparevi-tools-helper-artifact.json'

    & $publishScript `
      -OutputRoot $outDir `
      -MetadataReportPath $metadataPath `
      -Repository 'owner/repo' `
      -SourceRef 'refs/tags/v9.9.9' `
      -SourceSha '0123456789abcdef0123456789abcdef01234567' `
      -ReleaseTag 'v9.9.9'

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $archivePath = Join-Path $outDir $metadata.bundle.archiveName
    $extractRoot = Join-Path $TestDrive 'extracted-helper'
    Expand-Archive -Path $archivePath -DestinationPath $extractRoot

    $bundleRoot = Join-Path $extractRoot $metadata.bundle.folder
    $helperPath = Join-Path $bundleRoot 'tools' 'New-CompareVIHistoryDiagnosticsBody.ps1'
    Test-Path -LiteralPath $helperPath | Should -BeTrue

    $body = & $helperPath `
      -Variant comment-gated `
      -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1.0.4' `
      -IssueNumber '2' `
      -TargetPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi' `
      -ContainerImage 'nationalinstruments/labview:2026q1-linux' `
      -RequestedModes 'attributes,front-panel,block-diagram' `
      -ExecutedModes 'attributes,front-panel,block-diagram' `
      -TotalProcessed '3' `
      -TotalDiffs '2' `
      -StepConclusion 'success' `
      -IsFork 'True' `
      -RunUrl 'https://github.com/example/repo/actions/runs/123' `
      -ModeSummaryMarkdown '| Mode | Diffs |'

    $body | Should -Match 'comparevi-history diagnostics finished for PR #2\.'
    $body | Should -Match 'Requested modes: `attributes,front-panel,block-diagram`'
    $body | Should -Not -Match '\$env:ACTION_REF|\$env:REQUESTED_MODES'
  }
}
