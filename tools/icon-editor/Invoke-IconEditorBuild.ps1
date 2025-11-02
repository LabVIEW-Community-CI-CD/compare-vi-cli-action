#Requires -Version 7.0

param(
  [string]$IconEditorRoot,
  [int]$Major = 0,
  [int]$Minor = 0,
  [int]$Patch = 0,
  [int]$Build = 0,
  [string]$Commit,
  [string]$CompanyName = 'LabVIEW Community CI/CD',
  [string]$AuthorName = 'LabVIEW Community CI/CD',
  [string]$MinimumSupportedLVVersion = '2021',
  [int]$LabVIEWMinorRevision = 3,
  [bool]$InstallDependencies = $true,
  [switch]$SkipPackaging,
  [switch]$RequirePackaging,
  [switch]$RunUnitTests,
  [string]$ResultsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  param([string]$StartPath = (Get-Location).Path)
  try { return (git -C $StartPath rev-parse --show-toplevel 2>$null).Trim() } catch { return $StartPath }
}

$repoRoot = Resolve-RepoRoot
Import-Module (Join-Path $repoRoot 'tools' 'VendorTools.psm1') -Force
Import-Module (Join-Path $repoRoot 'tools' 'icon-editor' 'IconEditorDevMode.psm1') -Force

if (-not $IconEditorRoot) {
  $IconEditorRoot = Join-Path $repoRoot 'vendor' 'icon-editor'
}

if (-not (Test-Path -LiteralPath $IconEditorRoot -PathType Container)) {
  throw "Icon editor root not found at '$IconEditorRoot'. Vendor the labview-icon-editor repository first."
}

if (-not $ResultsRoot) {
  $ResultsRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'icon-editor'
}

$ResultsRoot = (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Path $ResultsRoot -Force)).Path

$gCliPath = Resolve-GCliPath
if (-not $gCliPath) {
  throw "Unable to locate g-cli.exe. Update configs/labview-paths.local.json or set GCLI_EXE_PATH so the automation can find g-cli."
}

$gCliDirectory = Split-Path -Parent $gCliPath
$previousPath = $env:Path
$requiredLabVIEW = @(
  @{ Version = 2021; Bitness = 32 },
  @{ Version = 2021; Bitness = 64 },
  @{ Version = 2023; Bitness = 64 }
)
$missingLabVIEW = @()
foreach ($requirement in $requiredLabVIEW) {
  $requiredPath = Find-LabVIEWVersionExePath -Version $requirement.Version -Bitness $requirement.Bitness
  if (-not $requiredPath) {
    $missingLabVIEW += $requirement
  }
}
if ($missingLabVIEW.Count -gt 0) {
  $missingText = ($missingLabVIEW | ForEach-Object { "LabVIEW {0} ({1}-bit)" -f $_.Version, $_.Bitness }) -join ', '
  throw ("Required LabVIEW installations not found: {0}. Install the missing versions or set `versions.<version>.<bitness>.LabVIEWExePath` in configs/labview-paths.local.json." -f $missingText)
}
$devModeWasToggled = $false
$devModeActive = $false
try {
  if ($previousPath -notlike "$gCliDirectory*") {
    $env:Path = "$gCliDirectory;$previousPath"
  }

  if (-not $Commit) {
    try {
      $Commit = (git -C $repoRoot rev-parse --short HEAD).Trim()
    } catch {
      $Commit = 'vendored'
    }
  }

  $actionsRoot = Join-Path $IconEditorRoot '.github' 'actions'

  $unitTestScript     = Join-Path $actionsRoot 'run-unit-tests' 'RunUnitTests.ps1'
  $buildLvlibpScript  = Join-Path $actionsRoot 'build-lvlibp' 'Build_lvlibp.ps1'
  $closeLabviewScript = Join-Path $actionsRoot 'close-labview' 'Close_LabVIEW.ps1'
  $renameScript       = Join-Path $actionsRoot 'rename-file' 'Rename-file.ps1'
  $modifyVipbScript   = Join-Path $actionsRoot 'modify-vipb-display-info' 'ModifyVIPBDisplayInfo.ps1'
  $buildVipScript     = Join-Path $actionsRoot 'build-vi-package' 'build_vip.ps1'
  $packageSmokeScript = Join-Path $repoRoot 'tools' 'icon-editor' 'Test-IconEditorPackage.ps1'

  foreach ($required in @($buildLvlibpScript, $closeLabviewScript, $renameScript, $modifyVipbScript, $buildVipScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Expected script '$required' was not found."
    }
  }

  function Invoke-IconEditorAction {
    param(
      [string]$ScriptPath,
      [string[]]$Arguments
    )

    Invoke-IconEditorDevModeScript -ScriptPath $ScriptPath -ArgumentList $Arguments -RepoRoot $repoRoot -IconEditorRoot $IconEditorRoot
  }

  if ($SkipPackaging.IsPresent -and $RequirePackaging.IsPresent) {
    throw 'Specify either -SkipPackaging or -RequirePackaging, not both.'
  }

  $packagingRequested = -not $SkipPackaging.IsPresent
  if ($RequirePackaging.IsPresent) {
    $packagingRequested = $true
  }

  $buildStart = Get-Date

  $previousDevState = Get-IconEditorDevModeState -RepoRoot $repoRoot
  $devModeWasToggled = $false
  $devModeActive = $false
  if ($InstallDependencies -and (-not $previousDevState.Active)) {
    Write-Host 'Enabling icon editor development mode...' -ForegroundColor Cyan
    Enable-IconEditorDevelopmentMode -RepoRoot $repoRoot -IconEditorRoot $IconEditorRoot | Out-Null
    $devModeWasToggled = $true
    $devModeActive = $true
  } elseif ($previousDevState.Active) {
    $devModeActive = $true
  }

  $pluginsPath = Join-Path $IconEditorRoot 'resource' 'plugins'
  if (Test-Path -LiteralPath $pluginsPath -PathType Container) {
    Get-ChildItem -LiteralPath $pluginsPath -Filter '*.lvlibp' -ErrorAction SilentlyContinue | ForEach-Object {
      Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
  }

  $lvLibPath = Join-Path $pluginsPath 'lv_icon.lvlibp'
  $renameToX86 = 'lv_icon_x86.lvlibp'
  $renameToX64 = 'lv_icon_x64.lvlibp'

  Write-Host 'Building icon editor packed libraries...' -ForegroundColor Cyan

  Invoke-IconEditorAction `
    -ScriptPath $buildLvlibpScript `
    -Arguments @(
      '-MinimumSupportedLVVersion','2021',
      '-SupportedBitness','32',
      '-RelativePath', $IconEditorRoot,
      '-Major', "$Major",
      '-Minor', "$Minor",
      '-Patch', "$Patch",
      '-Build', "$Build",
      '-Commit', $Commit
    )

  Invoke-IconEditorAction `
    -ScriptPath $closeLabviewScript `
    -Arguments @(
      '-MinimumSupportedLVVersion','2021',
      '-SupportedBitness','32'
    )

  Invoke-IconEditorAction `
    -ScriptPath $renameScript `
    -Arguments @(
      '-CurrentFilename', $lvLibPath,
      '-NewFilename', $renameToX86
    )

  Invoke-IconEditorAction `
    -ScriptPath $buildLvlibpScript `
    -Arguments @(
      '-MinimumSupportedLVVersion','2021',
      '-SupportedBitness','64',
      '-RelativePath', $IconEditorRoot,
      '-Major', "$Major",
      '-Minor', "$Minor",
      '-Patch', "$Patch",
      '-Build', "$Build",
      '-Commit', $Commit
    )

  Invoke-IconEditorAction `
    -ScriptPath $closeLabviewScript `
    -Arguments @(
      '-MinimumSupportedLVVersion','2021',
      '-SupportedBitness','64'
    )

  Invoke-IconEditorAction `
    -ScriptPath $renameScript `
    -Arguments @(
      '-CurrentFilename', $lvLibPath,
      '-NewFilename', $renameToX64
    )

  $displayInfo = [ordered]@{
    'Package Version' = [ordered]@{
      major = $Major
      minor = $Minor
      patch = $Patch
      build = $Build
    }
    'Product Name'                   = ''
    'Company Name'                   = $CompanyName
    'Author Name (Person or Company)' = $AuthorName
    'Product Homepage (URL)'         = ''
    'Legal Copyright'                = ''
    'License Agreement Name'         = ''
    'Product Description Summary'    = ''
    'Product Description'            = ''
    'Release Notes - Change Log'     = ''
  }

  $displayInfoJson = $displayInfo | ConvertTo-Json -Depth 3
  $vipArtifacts = @()
  $packageSmokeSummary = $null

  if ($packagingRequested) {
    Write-Host 'Packaging icon editor VIP...' -ForegroundColor Cyan

    $vipbRelativePath = 'Tooling\deployment\NI Icon editor.vipb'
    $releaseNotesPath = Join-Path $IconEditorRoot 'Tooling\deployment\release_notes.md'

    Invoke-IconEditorAction `
      -ScriptPath $modifyVipbScript `
      -Arguments @(
        '-SupportedBitness','64',
        '-RelativePath', $IconEditorRoot,
        '-VIPBPath', $vipbRelativePath,
        '-MinimumSupportedLVVersion','2023',
        '-LabVIEWMinorRevision', "$LabVIEWMinorRevision",
        '-Major', "$Major",
        '-Minor', "$Minor",
        '-Patch', "$Patch",
        '-Build', "$Build",
        '-Commit', $Commit,
        '-ReleaseNotesFile', $releaseNotesPath,
        '-DisplayInformationJSON', $displayInfoJson
      )

    Invoke-IconEditorAction `
      -ScriptPath $buildVipScript `
      -Arguments @(
        '-SupportedBitness','64',
        '-MinimumSupportedLVVersion','2023',
        '-LabVIEWMinorRevision', "$LabVIEWMinorRevision",
        '-Major', "$Major",
        '-Minor', "$Minor",
        '-Patch', "$Patch",
        '-Build', "$Build",
        '-Commit', $Commit,
        '-ReleaseNotesFile', $releaseNotesPath,
        '-DisplayInformationJSON', $displayInfoJson
      )

    Invoke-IconEditorAction `
      -ScriptPath $closeLabviewScript `
      -Arguments @(
        '-MinimumSupportedLVVersion','2023',
        '-SupportedBitness','64'
      )

    $vipCandidates = Get-ChildItem -Path $IconEditorRoot -Filter '*.vip' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $buildStart }
    foreach ($vip in $vipCandidates) {
      $destName = $vip.Name
      $destPath = Join-Path $ResultsRoot $destName
      Copy-Item -LiteralPath $vip.FullName -Destination $destPath -Force
      $vipArtifacts += @{ Source = $vip.FullName; Name = $destName; Kind = 'vip' }
    }
  } elseif ($RequirePackaging.IsPresent) {
    throw 'Packaging was required but could not be executed.'
  } else {
    Write-Host 'Packaging skipped by request.' -ForegroundColor Yellow
  }

  if (Test-Path -LiteralPath $packageSmokeScript -PathType Leaf) {
    $vipDestinations = @()
    foreach ($entry in $vipArtifacts) {
      $vipDestinations += (Join-Path $ResultsRoot $entry.Name)
    }

    try {
      $packageSmokeSummary = & $packageSmokeScript `
        -VipPath $vipDestinations `
        -ResultsRoot $ResultsRoot `
        -VersionInfo @{
          major  = $Major
          minor  = $Minor
          patch  = $Patch
          build  = $Build
          commit = $Commit
        } `
        -RequireVip:$packagingRequested
    } catch {
      if ($RequirePackaging.IsPresent -or $packagingRequested) {
        throw
      }

      Write-Warning "Package smoke test failed: $($_.Exception.Message)"
    }
  }

  $artifactMap = @(
    @{ Source = Join-Path $IconEditorRoot 'resource\plugins\lv_icon_x86.lvlibp'; Name = 'lv_icon_x86.lvlibp'; Kind = 'lvlibp' },
    @{ Source = Join-Path $IconEditorRoot 'resource\plugins\lv_icon_x64.lvlibp'; Name = 'lv_icon_x64.lvlibp'; Kind = 'lvlibp' }
  )

  foreach ($artifact in $artifactMap) {
    if (Test-Path -LiteralPath $artifact.Source -PathType Leaf) {
      Copy-Item -LiteralPath $artifact.Source -Destination (Join-Path $ResultsRoot $artifact.Name) -Force
    }
  }

  if ($RunUnitTests) {
    if (-not (Test-Path -LiteralPath $unitTestScript -PathType Leaf)) {
      throw "Unit test script '$unitTestScript' not found."
    }

    Push-Location (Split-Path -Parent $unitTestScript)
    try {
      & $unitTestScript -MinimumSupportedLVVersion $MinimumSupportedLVVersion -SupportedBitness '64'
    } finally {
      Pop-Location
    }

    $reportPath = Join-Path (Split-Path -Parent $unitTestScript) 'UnitTestReport.xml'
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
      Copy-Item -LiteralPath $reportPath -Destination (Join-Path $ResultsRoot 'UnitTestReport.xml') -Force
    }
  }

  if ($devModeActive -and $devModeWasToggled) {
    Write-Host 'Disabling icon editor development mode...' -ForegroundColor Cyan
    try {
      Disable-IconEditorDevelopmentMode -RepoRoot $repoRoot -IconEditorRoot $IconEditorRoot | Out-Null
      $devModeActive = $false
    } catch {
      Write-Warning "Failed to disable icon editor development mode: $($_.Exception.Message)"
    }
  }

  $manifest = [ordered]@{
    schema        = 'icon-editor/build@v1'
    generatedAt   = (Get-Date).ToString('o')
    iconEditorRoot = $IconEditorRoot
    resultsRoot   = $ResultsRoot
    version       = @{
      major = $Major
      minor = $Minor
      patch = $Patch
      build = $Build
      commit = $Commit
    }
    dependenciesApplied = [bool]$devModeWasToggled
    unitTestsRun        = [bool]$RunUnitTests
    packagingRequested  = [bool]$packagingRequested
    artifacts = @()
  }

  if ($packageSmokeSummary) {
    $manifest.packageSmoke = $packageSmokeSummary
  }

  $devModeState = Get-IconEditorDevModeState -RepoRoot $repoRoot
  $manifest.developmentMode = [ordered]@{
    active    = $devModeState.Active
    updatedAt = $devModeState.UpdatedAt
    source    = $devModeState.Source
    toggled   = [bool]$devModeWasToggled
  }

  foreach ($artifact in $artifactMap) {
    $dest = Join-Path $ResultsRoot $artifact.Name
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
      $info = Get-Item -LiteralPath $dest
      $manifest.artifacts += [ordered]@{
        name = $artifact.Name
        path = $info.FullName
        sizeBytes = $info.Length
        kind = $artifact.Kind
      }
    }
  }

  foreach ($entry in $vipArtifacts) {
    $dest = Join-Path $ResultsRoot $entry.Name
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
      $info = Get-Item -LiteralPath $dest
      $manifest.artifacts += [ordered]@{
        name = $entry.Name
        path = $info.FullName
        sizeBytes = $info.Length
        kind = $entry.Kind
      }
    }
  }

  $manifestPath = Join-Path $ResultsRoot 'manifest.json'
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

  Write-Host "Icon Editor build completed. Artifacts captured in $ResultsRoot"
}
finally {
  if ($devModeWasToggled -and $devModeActive) {
    try {
      Write-Host 'Disabling icon editor development mode...' -ForegroundColor Cyan
      Disable-IconEditorDevelopmentMode -RepoRoot $repoRoot -IconEditorRoot $IconEditorRoot | Out-Null
    } catch {
      Write-Warning "Failed to disable icon editor development mode: $($_.Exception.Message)"
    }
  }
  $env:Path = $previousPath
}
