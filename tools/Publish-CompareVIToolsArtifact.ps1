param(
  [string]$ModuleManifestPath = 'tools/CompareVI.Tools/CompareVI.Tools.psd1',
  [string]$OutputRoot = 'artifacts/cli',
  [string]$MetadataReportPath = 'tests/results/_agent/release/comparevi-tools-artifact.json',
  [string]$Repository = '',
  [string]$SourceRef = '',
  [string]$SourceSha = '',
  [string]$ReleaseTag = '',
  [switch]$EmitGitHubOutputs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Copy-OrderedDictionary {
  param([Parameter(Mandatory = $true)]$Dictionary)

  $copy = [ordered]@{}
  foreach ($entry in $Dictionary.GetEnumerator()) {
    $copy[$entry.Key] = $entry.Value
  }
  return $copy
}

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-RepositorySlug {
  param([string]$Explicit)

  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    return $Explicit.Trim()
  }

  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
    return $env:GITHUB_REPOSITORY.Trim()
  }

  try {
    $remote = (& git config --get remote.origin.url 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remote)) {
      $match = [regex]::Match($remote.Trim(), 'github\.com[:/](?<slug>[^/]+/[^/.]+)(?:\.git)?$', 'IgnoreCase')
      if ($match.Success) {
        return $match.Groups['slug'].Value
      }
    }
  } catch {}

  return 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
}

function Resolve-SourceSha {
  param([string]$Explicit)

  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    return $Explicit.Trim()
  }

  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
    return $env:GITHUB_SHA.Trim()
  }

  try {
    $sha = (& git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sha)) {
      return $sha.Trim()
    }
  } catch {}

  return ''
}

function Resolve-SourceRef {
  param([string]$Explicit)

  if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
    return $Explicit.Trim()
  }

  foreach ($candidate in @($env:GITHUB_REF_NAME, $env:GITHUB_HEAD_REF, $env:GITHUB_REF)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  try {
    $branch = (& git branch --show-current 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch)) {
      return $branch.Trim()
    }
  } catch {}

  return ''
}

function Write-GitHubOutputValue {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    return
  }

  "$Key=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

function Get-CompareVIToolsVersionContract {
  param(
    [Parameter(Mandatory = $true)][string]$ModuleVersion,
    [Parameter(Mandatory = $true)][string]$ModuleReleaseVersion,
    [AllowEmptyString()][string]$ReleaseTag
  )

  $toolsIteration = $null
  $toolsMatch = [regex]::Match($ModuleReleaseVersion, '^(?<family>\d+\.\d+\.\d+)-tools\.(?<iteration>\d+)$')
  if ($toolsMatch.Success) {
    $toolsIteration = [int]$toolsMatch.Groups['iteration'].Value
  }

  $stableFamilyTag = "v$ModuleVersion"
  $releaseTagNormalized = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $null } else { $ReleaseTag.Trim() }
  $authoritativePin = if ($releaseTagNormalized) { $releaseTagNormalized } else { $ModuleReleaseVersion }
  $authoritativePinKind = if ($releaseTagNormalized) { 'release-tag' } else { 'release-version' }
  $stableFamilyTagMutable = $ModuleReleaseVersion -ne $ModuleVersion

  return [ordered]@{
    schema = 'comparevi-tools/version-contract@v1'
    baseSemver = $ModuleVersion
    releaseVersion = $ModuleReleaseVersion
    stableFamilyTag = $stableFamilyTag
    stableFamilyTagMutable = $stableFamilyTagMutable
    toolsIteration = $toolsIteration
    authoritativeConsumerPin = $authoritativePin
    authoritativeConsumerPinKind = $authoritativePinKind
    notes = @(
      'Use authoritativeConsumerPin as the immutable consumer identity for this bundle.',
      'baseSemver and stableFamilyTag describe the compatibility family, not a mutable-friendly pin override.',
      'When toolsIteration is present, stableFamilyTag stays on the X.Y.Z family while the immutable bundle identity moves to X.Y.Z-tools.N.'
    )
  }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$moduleManifestCandidate = if ([System.IO.Path]::IsPathRooted($ModuleManifestPath)) {
  $ModuleManifestPath
} else {
  Join-Path $repoRoot $ModuleManifestPath
}
$moduleManifestResolved = (Resolve-Path -LiteralPath $moduleManifestCandidate).Path
$moduleRoot = Split-Path -Parent $moduleManifestResolved
$toolsRoot = Split-Path -Parent $moduleRoot

$requiredRelativePaths = @(
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
  'tools/Invoke-VIHistoryLocalRefinement.ps1',
  'tools/Invoke-VIHistoryLocalOperatorSession.ps1',
  'tools/Manage-VIHistoryRuntimeInDocker.ps1',
  'tools/New-CompareVIHistoryDiagnosticsBody.ps1',
  'tools/Render-VIHistoryReport.ps1',
  'tools/Run-NIWindowsContainerCompare.ps1',
  'tools/Run-NILinuxContainerCompare.ps1',
  'tools/Test-WindowsNI2026q1HostPreflight.ps1',
  'tools/VendorTools.psm1',
  'tools/VICategoryBuckets.psm1',
  'tools/priority/host-ram-budget.mjs',
  'tools/docker/Dockerfile.vi-history-dev',
  'tools/Stage-CompareInputs.ps1',
  'scripts/CompareVI.psm1',
  'scripts/ArgTokenization.psm1'
)

foreach ($relativePath in $requiredRelativePaths) {
  $candidate = Join-Path $repoRoot $relativePath
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
    throw "Required CompareVI.Tools bundle file not found: $candidate"
  }
}

$moduleManifest = Import-PowerShellDataFile -LiteralPath $moduleManifestResolved
$moduleVersion = [string]$moduleManifest.ModuleVersion
if ([string]::IsNullOrWhiteSpace($moduleVersion)) {
  throw "ModuleVersion was not found in $moduleManifestResolved"
}
$modulePrerelease = ''
if ($moduleManifest.ContainsKey('PrivateData')) {
  $privateData = $moduleManifest.PrivateData
  if ($privateData -is [hashtable] -and $privateData.ContainsKey('PSData')) {
    $psData = $privateData.PSData
    if ($psData -is [hashtable] -and $psData.ContainsKey('Prerelease') -and -not [string]::IsNullOrWhiteSpace([string]$psData.Prerelease)) {
      $modulePrerelease = [string]$psData.Prerelease
    }
  }
}
$moduleReleaseVersion = if ([string]::IsNullOrWhiteSpace($modulePrerelease)) {
  $moduleVersion
} else {
  "$moduleVersion-$modulePrerelease"
}

$repositorySlug = Resolve-RepositorySlug -Explicit $Repository
$resolvedSourceRef = Resolve-SourceRef -Explicit $SourceRef
$resolvedSourceSha = Resolve-SourceSha -Explicit $SourceSha
$resolvedReleaseTag = if (-not [string]::IsNullOrWhiteSpace($ReleaseTag)) {
  $ReleaseTag.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME) -and $env:GITHUB_REF -like 'refs/tags/*') {
  $env:GITHUB_REF_NAME.Trim()
} else {
  ''
}
$versionContract = Get-CompareVIToolsVersionContract `
  -ModuleVersion $moduleVersion `
  -ModuleReleaseVersion $moduleReleaseVersion `
  -ReleaseTag $resolvedReleaseTag

$outputRootResolved = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
  $OutputRoot
} else {
  Join-Path $repoRoot $OutputRoot
}
Ensure-Directory -Path $outputRootResolved

$metadataReportResolved = if ([System.IO.Path]::IsPathRooted($MetadataReportPath)) {
  $MetadataReportPath
} else {
  Join-Path $repoRoot $MetadataReportPath
}
Ensure-Directory -Path (Split-Path -Parent $metadataReportResolved)

$bundleFolderName = "CompareVI.Tools-v$moduleReleaseVersion"
$archiveName = "$bundleFolderName.zip"
$archivePath = Join-Path $outputRootResolved $archiveName

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-tools-bundle-" + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot $bundleFolderName
Ensure-Directory -Path $packageRoot

try {
  $fileEntries = New-Object System.Collections.Generic.List[object]

  foreach ($relativePath in $requiredRelativePaths) {
    $sourcePath = Join-Path $repoRoot $relativePath
    $destinationPath = Join-Path $packageRoot $relativePath
    Ensure-Directory -Path (Split-Path -Parent $destinationPath)
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force

    $sha256 = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $fileEntries.Add([pscustomobject]@{
      path = $relativePath.Replace('\', '/')
      sha256 = $sha256
      sizeBytes = (Get-Item -LiteralPath $sourcePath).Length
    }) | Out-Null
  }

  $bundleReadmePath = Join-Path $packageRoot 'README.md'
  @(
    '# CompareVI.Tools Release Bundle'
    ''
    "This bundle is extracted from `$repositorySlug`."
    ''
    '## Import path'
    ''
    '`tools/CompareVI.Tools/CompareVI.Tools.psd1`'
    ''
    '## Compatibility'
    ''
    '- Keep all files from this bundle together; do not mix files across tags.'
    '- For cross-repo VI history, extract the archive and import the module from this bundle instead of checking out the full repository.'
    '- Prefer `Invoke-CompareVIHistoryFacade` when downstream tooling needs a stable summary object plus the generated report paths.'
    '- For comparevi-history comment/summary rendering, resolve `tools/New-CompareVIHistoryDiagnosticsBody.ps1` from this bundle or from the workflow `tooling-path` output instead of copying inline PowerShell helpers.'
    '- For local-first VI history refinement, use `tools/Build-VIHistoryDevImage.ps1`, `tools/Invoke-VIHistoryLocalRefinement.ps1`, and `tools/Manage-VIHistoryRuntimeInDocker.ps1` from this bundle root.'
    '- For Windows mirror proof on a Windows host, keep `tools/Test-WindowsNI2026q1HostPreflight.ps1` and `tools/Run-NIWindowsContainerCompare.ps1` adjacent in the extracted bundle; `windows-mirror-proof` is pinned to `nationalinstruments/labview:2026q1-windows`.'
    '- For a unified local operator shell, use `tools/Invoke-VIHistoryLocalOperatorSession.ps1` or the exported `Invoke-CompareVIHistoryLocalOperatorSessionFacade` wrapper from this bundle.'
    '- The first documented downstream local-first consumer is `LabVIEW-Community-CI-CD/labview-icon-editor-demo` via comparevi-history local-review/local-proof targeting `develop`.'
    '- Treat the bundle metadata `versionContract.authoritativeConsumerPin` as the immutable toolchain identity. If `versionContract.toolsIteration` is present, `vX.Y.Z` remains the compatibility family tag and `vX.Y.Z-tools.N` is the immutable release identity.'
    '- The runtime facade JSON is written to `history-summary.json` under the selected results directory.'
    '- Real compare execution still requires the same LVCompare/LabVIEW prerequisites as the source repository.'
  ) | Set-Content -LiteralPath $bundleReadmePath -Encoding utf8

  $readmeHash = (Get-FileHash -LiteralPath $bundleReadmePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $fileEntries.Add([pscustomobject]@{
    path = 'README.md'
    sha256 = $readmeHash
    sizeBytes = (Get-Item -LiteralPath $bundleReadmePath).Length
  }) | Out-Null

  $moduleMetadata = [ordered]@{
    name = 'CompareVI.Tools'
    version = $moduleVersion
    releaseVersion = $moduleReleaseVersion
    prerelease = if ([string]::IsNullOrWhiteSpace($modulePrerelease)) { $null } else { $modulePrerelease }
    manifestPath = 'tools/CompareVI.Tools/CompareVI.Tools.psd1'
    importPath = 'tools/CompareVI.Tools/CompareVI.Tools.psd1'
    exportedFunctions = @($moduleManifest.FunctionsToExport)
  }

  $sourceMetadata = [ordered]@{
    repository = $repositorySlug
    ref = $resolvedSourceRef
    sha = $resolvedSourceSha
    releaseTag = $resolvedReleaseTag
  }

  $compatibilityMetadata = [ordered]@{
    supportedPaths = @(
      'extract-archive-and-import-module',
      'cross-repo-vi-history-via-module',
      'cross-repo-vi-history-via-facade',
      'cross-repo-vi-history-via-hosted-ni-linux-runner',
      'local-vi-history-refinement-via-runtime-profiles',
      'local-vi-history-operator-session-via-runtime-and-review-hooks',
      'comparevi-history-comment-rendering-via-tooling-path'
    )
    requires = @(
      'git-history-in-target-repo',
      'lvcompare-or-invoke-script-stub'
    )
    notes = @(
      'The bundle is self-contained for CompareVI.Tools module usage.',
      'Do not mix files from different release tags.',
      'Downstream comparevi-history consumers can resolve the diagnostics body renderer from the tooling root instead of copying inline PowerShell helpers.'
    )
  }

  $consumerContractMetadata = [ordered]@{
    capabilities = [ordered]@{
      viHistory = [ordered]@{
        schema = 'comparevi-tools/vi-history-capability@v1'
        capabilityId = 'vi-history'
        displayName = 'VI History'
        distributionRole = 'upstream-producer'
        distributionModel = 'release-bundle'
        bundleMetadataPath = 'comparevi-tools-release.json'
        bundleImportPath = 'tools/CompareVI.Tools/CompareVI.Tools.psd1'
        releaseAssetPattern = 'CompareVI.Tools-v<release-version>.zip'
        authoritativeConsumerPinFieldPath = 'versionContract.authoritativeConsumerPin'
        authoritativeConsumerPinKindFieldPath = 'versionContract.authoritativeConsumerPinKind'
        contractPaths = [ordered]@{
          historyFacade = 'consumerContract.historyFacade'
          localRuntimeProfiles = 'consumerContract.localRuntimeProfiles'
          localOperatorSession = 'consumerContract.localOperatorSession'
          diagnosticsCommentRenderer = 'consumerContract.diagnosticsCommentRenderer'
          hostedNiLinuxRunner = 'consumerContract.hostedNiLinuxRunner'
        }
        notes = @(
          'Use this capability record when a downstream distributor such as LabviewGitHubCiTemplate needs to stamp vi-history support into generated repositories without copying compare internals.',
          'Resolve the immutable downstream pin from versionContract.authoritativeConsumerPin and then read the referenced consumer contract paths from the same comparevi-tools-release.json payload.',
          'The capability contract declares compare-vi-cli-action as the upstream producer; downstream repositories should distribute or consume the capability, not vendor the full backend control plane.'
        )
      }
    }
    historyFacade = [ordered]@{
      schema = 'comparevi-tools/history-facade@v1'
      schemaUrl = 'https://labview-community-ci-cd.github.io/compare-vi-cli-action/schemas/comparevi-tools-history-facade-v1.schema.json'
      exportedFunction = 'Invoke-CompareVIHistoryFacade'
      resultsRelativePath = 'history-summary.json'
      stableFields = @(
        'target.path',
        'target.requestedStartRef',
        'target.effectiveStartRef',
        'target.sourceBranchRef',
        'target.branchBudget',
        'execution.requestedModes',
        'execution.executedModes',
        'execution.reportFormat',
        'execution.status',
        'observedInterpretation.coverageClass',
        'observedInterpretation.modeSensitivity',
        'observedInterpretation.outcomeLabels',
        'summary',
        'reports',
        'modes'
      )
      notes = @(
        'Use the reviewed release tag and bundle metadata as the supported downstream pin.',
        'The facade omits raw per-comparison backend payloads so downstream consumers only depend on the stabilized summary surface.',
        'When source-branch budgeting is requested, the facade also records the evaluated branch budget so downstream consumers can audit the safeguard without parsing raw git state.'
      )
    }
    localRuntimeProfiles = [ordered]@{
      schema = 'comparevi-tools/local-refinement-facade@v1'
      schemaUrl = 'https://labview-community-ci-cd.github.io/compare-vi-cli-action/schemas/comparevi-tools-local-refinement-facade-v1.schema.json'
      exportedFunction = 'Invoke-CompareVIHistoryLocalRefinementFacade'
      resultsRelativePath = 'local-refinement.json'
      benchmarkRelativePath = 'local-refinement-benchmark.json'
      runtimeProfiles = @(
        'proof',
        'dev-fast',
        'warm-dev',
        'windows-mirror-proof'
      )
      defaultProfile = 'dev-fast'
      stableFields = @(
        'runtimeProfile',
        'runtimePlane',
        'image',
        'toolSource',
        'cacheReuseState',
        'coldWarmClass',
        'benchmarkSampleKind',
        'timings',
        'history',
        'reviewSuite',
        'reviewLoop',
        'hostRamBudget',
        'windowsMirror',
        'warmRuntime',
        'artifacts',
        'finalStatus'
      )
      notes = @(
        'Use the module facade when comparevi-history or another downstream needs profile-aware local refinement without hard-coding backend script paths.',
        'The facade defaults RepoRoot to the caller working directory so extracted tooling bundles can target downstream repositories cleanly.',
        'Proof stays the canonical runtime truth; dev-fast and warm-dev are local acceleration planes only.',
        'windows-mirror-proof is the first Windows mirror plane and exists to validate a repeatable headless Windows container surface before any host-native 32-bit promotion.',
        'The first documented downstream adoption proof is LabVIEW-Community-CI-CD/labview-icon-editor-demo via comparevi-history local-review/local-proof targeting develop.'
      )
    }
    localOperatorSession = [ordered]@{
      schema = 'comparevi-tools/local-operator-session-facade@v1'
      schemaUrl = 'https://labview-community-ci-cd.github.io/compare-vi-cli-action/schemas/comparevi-tools-local-operator-session-facade-v1.schema.json'
      exportedFunction = 'Invoke-CompareVIHistoryLocalOperatorSessionFacade'
      resultsRelativePath = 'local-operator-session.json'
      runtimeProfiles = @(
        'proof',
        'dev-fast',
        'warm-dev',
        'windows-mirror-proof'
      )
      defaultProfile = 'dev-fast'
      stableFields = @(
        'runtimeProfile',
        'runtimePlane',
        'repoRoot',
        'resultsRoot',
        'hostRamBudget',
        'localRefinement',
        'review.status',
        'review.commandPath',
        'review.outputs',
        'artifacts',
        'finalStatus',
        'failure'
      )
      notes = @(
        'Use the operator-session facade when a downstream wants one local command surface that composes runtime execution with an optional review hook.',
        'The session contract records the existing local-refinement receipt plus downstream review output paths without moving review-compiler ownership into this repository.',
        'comparevi-history should consume this seam rather than recreating runtime orchestration.',
        'windows-mirror-proof is proof-only in this first slice; Windows acceleration and warm runtime reuse remain follow-on work.'
      )
    }
    diagnosticsCommentRenderer = [ordered]@{
      entryScriptPath = 'tools/New-CompareVIHistoryDiagnosticsBody.ps1'
      variants = @(
        'comment-gated',
        'manual'
      )
      notes = @(
        'Resolve the renderer from the extracted bundle root or comparevi-history tooling-path output instead of copying inline PowerShell comment bodies into downstream repositories.',
        'The renderer consumes stabilized facade outputs and mode summary markdown so downstream callers can publish deterministic PR comments and step summaries.'
      )
    }
    hostedNiLinuxRunner = [ordered]@{
      entryScriptPath = 'tools/Run-NILinuxContainerCompare.ps1'
      supportScriptPaths = @(
        'tools/Assert-DockerRuntimeDeterminism.ps1',
        'tools/Compare-ExitCodeClassifier.ps1'
      )
      captureFileName = 'ni-linux-container-capture.json'
      defaultImage = 'nationalinstruments/labview:2026q1-linux'
      notes = @(
        'Hosted Linux consumers can resolve the runner from COMPAREVI_SCRIPTS_ROOT without a full backend checkout.',
        'Keep the entry script and support scripts adjacent inside the extracted bundle so runtime guard and exit-code classification remain available.',
        'The same extracted bundle also carries the local-only VI history acceleration surfaces (`Build-VIHistoryDevImage.ps1`, `Invoke-VIHistoryLocalRefinement.ps1`, `Invoke-VIHistoryLocalOperatorSession.ps1`, and `Manage-VIHistoryRuntimeInDocker.ps1`) for downstream local refinement loops.',
        'The first Windows mirror proof slice also ships `Test-WindowsNI2026q1HostPreflight.ps1` and `Run-NIWindowsContainerCompare.ps1` so Windows-host consumers can validate the pinned headless NI image without a full backend checkout.'
      )
    }
  }

  $bundleMetadata = [ordered]@{
    folder = $bundleFolderName
    archiveName = $archiveName
    readmePath = 'README.md'
    files = @($fileEntries.ToArray())
  }

  $metadata = [ordered]@{
    schema = 'comparevi-tools-release-manifest@v1'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    module = $moduleMetadata
    versionContract = $versionContract
    source = $sourceMetadata
    compatibility = $compatibilityMetadata
    consumerContract = $consumerContractMetadata
    bundle = $bundleMetadata
  }

  $metadataPath = Join-Path $packageRoot 'comparevi-tools-release.json'
  $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding utf8
  $metadataCopy = Copy-OrderedDictionary -Dictionary $metadata
  $metadataCopy.bundle = Copy-OrderedDictionary -Dictionary $metadata.bundle
  $metadataCopy.bundle.metadataPath = 'comparevi-tools-release.json'

  $metadataCopy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataPath -Encoding utf8
  $metadataCopy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $metadataReportResolved -Encoding utf8

  if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    Remove-Item -LiteralPath $archivePath -Force
  }
  Compress-Archive -Path $packageRoot -DestinationPath $archivePath

  Write-Host "CompareVI.Tools bundle written to $archivePath"
  Write-Host "CompareVI.Tools metadata written to $metadataReportResolved"

  if ($EmitGitHubOutputs.IsPresent) {
    Write-GitHubOutputValue -Key 'comparevi_tools_module_version' -Value $moduleVersion
    Write-GitHubOutputValue -Key 'comparevi_tools_release_version' -Value $moduleReleaseVersion
    Write-GitHubOutputValue -Key 'comparevi_tools_module_prerelease' -Value $modulePrerelease
    Write-GitHubOutputValue -Key 'comparevi_tools_archive_path' -Value $archivePath
    Write-GitHubOutputValue -Key 'comparevi_tools_metadata_path' -Value $metadataReportResolved
  }
} finally {
  if (Test-Path -LiteralPath $stagingRoot -PathType Container) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
