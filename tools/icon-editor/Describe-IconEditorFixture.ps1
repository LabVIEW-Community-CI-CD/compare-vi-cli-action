#Requires -Version 7.0

param(
  [string]$FixturePath,
  [string]$ResultsRoot,
  [string]$OutputPath,
  [switch]$KeepWork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try {
    return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim()
  } catch {
    return $StartPath
  }
}

function Parse-SpecFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Spec file not found at '$Path'."
  }

  $sections = [ordered]@{}
  $current = $null
  foreach ($lineRaw in Get-Content -LiteralPath $Path) {
    $line = $lineRaw.Trim()
    if (-not $line) {
      continue
    }
    if ($line.StartsWith('#')) {
      continue
    }
    if ($line -match '^\[(.+?)\]$') {
      $sectionName = $Matches[1]
      if (-not $sections.Contains($sectionName)) {
        $sections[$sectionName] = [ordered]@{}
      }
      $current = $sectionName
      continue
    }
    if ($line -match '^(?<key>[^=]+)=(?<value>.+)$') {
      $key = $Matches['key'].Trim()
      $valueRaw = $Matches['value'].Trim()
      $value = $valueRaw.Trim('"')
      if (-not $current) {
        $current = '_root'
        if (-not $sections.Contains($current)) {
          $sections[$current] = [ordered]@{}
        }
      }
      $sections[$current][$key] = $value
    }
  }
  return $sections
}

function Get-FileHashInfo {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  $info = Get-Item -LiteralPath $Path
  return [ordered]@{
    path      = $info.FullName
    name      = $info.Name
    sizeBytes = $info.Length
    hash      = $hash.Hash.ToLowerInvariant()
  }
}

function Ensure-Directory {
  param([string]$Path)
  $resolved = Resolve-Path -LiteralPath (New-Item -ItemType Directory -Path $Path -Force)
  return $resolved.Path
}

$repoRoot = Resolve-RepoRoot
if (-not $FixturePath) {
  $FixturePath = Join-Path $repoRoot 'tests' 'fixtures' 'icon-editor' 'ni_icon_editor-1.4.1.948.vip'
}
if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
  throw "Fixture VI Package not found at '$FixturePath'."
}

$workRoot = if ($ResultsRoot) {
  Ensure-Directory $ResultsRoot
} else {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("icon-editor-describe-{0}" -f ([guid]::NewGuid().ToString('n')))
  Ensure-Directory $tmp
}

$simulationParams = @{
  FixturePath = $FixturePath
  ResultsRoot = $workRoot
  KeepExtract = $true
}

$manifest = $null
try {
  pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'tools' 'icon-editor' 'Simulate-IconEditorBuild.ps1') @simulationParams | Out-Null
  $manifestPath = Join-Path $workRoot 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Simulation manifest not found at '$manifestPath'."
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 6

  $extractRoot = Join-Path $workRoot '__fixture_extract'
  $systemExtractRoot = Join-Path $extractRoot '__system_extract'
  if (-not (Test-Path -LiteralPath $extractRoot -PathType Container)) {
    throw "Fixture extraction directory not found at '$extractRoot'."
  }
  if (-not (Test-Path -LiteralPath $systemExtractRoot -PathType Container)) {
    throw "System extraction directory not found at '$systemExtractRoot'."
  }

  $fixtureSpec = Parse-SpecFile -Path (Join-Path $extractRoot 'spec')
  $systemSpec = Parse-SpecFile -Path (Join-Path $systemExtractRoot 'spec')

  $artifactFiles = @()
  foreach ($artifact in @('ni_icon_editor-1.4.1.948.vip', 'ni_icon_editor_system-1.4.1.948.vip', 'lv_icon_x64.lvlibp', 'lv_icon_x86.lvlibp')) {
    $info = Get-FileHashInfo -Path (Join-Path $workRoot $artifact)
    if ($info) {
      $artifactFiles += $info
    }
  }

  $deploymentRoot = Join-Path $systemExtractRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Tooling\deployment'
  $customActionNames = @(
    'VIP_Pre-Install Custom Action 2021.vi',
    'VIP_Post-Install Custom Action 2021.vi',
    'VIP_Pre-Uninstall Custom Action 2021.vi',
    'VIP_Post-Uninstall Custom Action 2021.vi'
  )
  $customActions = @()
  foreach ($name in $customActionNames) {
    $fixtureInfo = Get-FileHashInfo -Path (Join-Path $deploymentRoot $name)
    $repoPath = Join-Path $repoRoot ('vendor/icon-editor/.github/actions/build-vi-package/{0}' -f $name)
    $repoInfo = Get-FileHashInfo -Path $repoPath
    $customActions += [ordered]@{
      name       = $name
      fixture    = $fixtureInfo
      repo       = $repoInfo
      hashMatch  = ($fixtureInfo -and $repoInfo -and ($fixtureInfo.hash -eq $repoInfo.hash))
    }
  }

  $runnerDependenciesFixture = Get-FileHashInfo -Path (Join-Path $deploymentRoot 'runner_dependencies.vipc')
  $runnerDependenciesRepo = Get-FileHashInfo -Path (Join-Path $repoRoot 'vendor/icon-editor/.github/actions/apply-vipc/runner_dependencies.vipc')

  $fixtureOnlyAssets = @()
  $scriptsPath = Join-Path $systemExtractRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\scripts'
  if (Test-Path -LiteralPath $scriptsPath -PathType Container) {
    Get-ChildItem -LiteralPath $scriptsPath -File | ForEach-Object {
      $item = $_
      $fixtureOnlyAssets += [ordered]@{
        category  = 'script'
        name      = $item.Name
        path      = $item.FullName
        sizeBytes = $item.Length
        hash      = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    }
  }
  $testsPath = Join-Path $systemExtractRoot 'File Group 0\National Instruments\LabVIEW Icon Editor\Test'
  if (Test-Path -LiteralPath $testsPath -PathType Container) {
    Get-ChildItem -LiteralPath $testsPath -Recurse -File | ForEach-Object {
      $item = $_
      $rel  = $item.FullName.Substring($testsPath.Length + 1)
      $fixtureOnlyAssets += [ordered]@{
        category  = 'test'
        name      = $rel
        path      = $item.FullName
        sizeBytes = $item.Length
        hash      = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
      }
    }
  }

  $fixtureVersionRaw = $fixtureSpec.Package.Version
  $systemVersionRaw = $systemSpec.Package.Version

  $summary = [ordered]@{
    schema      = 'icon-editor/fixture-report@v1'
    generatedAt = (Get-Date).ToString('o')
    source      = [ordered]@{
      fixturePath = (Resolve-Path -LiteralPath $FixturePath).Path
      repoRoot    = $repoRoot
    }
    fixture      = [ordered]@{
      package     = $fixtureSpec.Package
      description = $fixtureSpec.Description
    }
    systemPackage = [ordered]@{
      package     = $systemSpec.Package
      description = $systemSpec.Description
    }
    manifest    = $manifest
    artifacts   = $artifactFiles
    customActions = $customActions
    runnerDependencies = [ordered]@{
      fixture   = $runnerDependenciesFixture
      repo      = $runnerDependenciesRepo
      hashMatch = ($runnerDependenciesFixture -and $runnerDependenciesRepo -and ($runnerDependenciesFixture.hash -eq $runnerDependenciesRepo.hash))
    }
    fixtureOnlyAssets = $fixtureOnlyAssets
  }

  $stakeholderArtifacts = $artifactFiles | ForEach-Object {
    [ordered]@{
      name      = $_.name
      hash      = $_.hash
      sizeBytes = $_.sizeBytes
    }
  }
  $stakeholderCustomActions = $customActions | ForEach-Object {
    [ordered]@{
      name        = $_.name
      hash        = $_.fixture ? $_.fixture.hash : $null
      matchStatus = if ($_.hashMatch) { 'match' } else { 'mismatch' }
    }
  }
  $summary.stakeholder = [ordered]@{
    version             = $fixtureVersionRaw
    systemVersion       = $systemVersionRaw
    license             = $summary.fixture.description.License
    smokeStatus         = $manifest.packageSmoke.status
    simulationEnabled   = $manifest.simulation.enabled
    unitTestsRun        = $manifest.unitTestsRun
    artifacts           = $stakeholderArtifacts
    customActions       = $stakeholderCustomActions
    runnerDependencies  = [ordered]@{
      hash        = $runnerDependenciesFixture ? $runnerDependenciesFixture.hash : $null
      matchesRepo = $summary.runnerDependencies.hashMatch
    }
    generatedAt         = $summary.generatedAt
    fixtureOnlyAssets   = $fixtureOnlyAssets
  }

if ($OutputPath) {
  $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

return [pscustomobject]$summary
}
finally {
  if (-not $KeepWork.IsPresent) {
    try {
      if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {
      Write-Warning "Failed to clean descriptor workspace '$workRoot': $($_.Exception.Message)"
    }
  }
}
