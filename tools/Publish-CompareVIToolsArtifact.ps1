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
    [Parameter(Mandatory = $true)][string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    return
  }

  "$Key=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$moduleManifestResolved = (Resolve-Path -LiteralPath (Join-Path $repoRoot $ModuleManifestPath)).Path
$moduleRoot = Split-Path -Parent $moduleManifestResolved
$toolsRoot = Split-Path -Parent $moduleRoot

$requiredRelativePaths = @(
  'tools/CompareVI.Tools/CompareVI.Tools.psd1',
  'tools/CompareVI.Tools/CompareVI.Tools.psm1',
  'tools/Compare-VIHistory.ps1',
  'tools/Compare-RefsToTemp.ps1',
  'tools/Invoke-LVCompare.ps1',
  'tools/Render-VIHistoryReport.ps1',
  'tools/VendorTools.psm1',
  'tools/VICategoryBuckets.psm1',
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
      'cross-repo-vi-history-via-module'
    )
    requires = @(
      'git-history-in-target-repo',
      'lvcompare-or-invoke-script-stub'
    )
    notes = @(
      'The bundle is self-contained for CompareVI.Tools module usage.',
      'Do not mix files from different release tags.'
    )
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
    source = $sourceMetadata
    compatibility = $compatibilityMetadata
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
