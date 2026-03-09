param(
  [string]$ProjectPath = "src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj",
  [string]$SharedProjectPath = "src/CompareVi.Shared/CompareVi.Shared.csproj",
  [string]$Configuration = "Release",
  [string[]]$Rids = @("win-x64","linux-x64","osx-x64"),
  [string]$OutputRoot = "artifacts/cli",
  [ValidateSet("project","package","package-first")]
  [string]$CompareViSharedSource = "package-first",
  [string]$CompareViSharedPackageVersion = "",
  [string]$CompareViSharedPackageFeed = "artifacts/shared-feed",
  [switch]$PrepareSharedPackageFeed = $true,
  [switch]$FailOnSharedFallback = $false,
  [string]$SharedSourceReportPath = "tests/results/_agent/release/shared-source-resolution.json",
  [switch]$FrameworkDependent = $true,
  [switch]$SelfContained = $true,
  [switch]$SingleFile = $true
)

$ErrorActionPreference = 'Stop'

function Get-XmlNodeText {
  param([AllowNull()]$Node)

  if ($null -eq $Node) {
    return ''
  }

  if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string]) -and -not ($Node -is [System.Xml.XmlNode])) {
    foreach ($candidate in $Node) {
      $text = Get-XmlNodeText -Node $candidate
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        return $text
      }
    }

    return ''
  }

  if ($Node -is [System.Xml.XmlNode]) {
    return $Node.InnerText.Trim()
  }

  return ([string]$Node).Trim()
}

function Get-VersionFromProps {
  $propsPath = Join-Path $PSScriptRoot '..' 'Directory.Build.props' | Resolve-Path | Select-Object -ExpandProperty Path
  [xml]$xml = Get-Content -Raw $propsPath
  $ver = Get-XmlNodeText -Node ($xml.Project.PropertyGroup.Version | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($ver)) { return '0.0.0' }
  return $ver
}

function Get-SharedPackageVersionFromProps {
  $propsPath = Join-Path $PSScriptRoot '..' 'Directory.Build.props' | Resolve-Path | Select-Object -ExpandProperty Path
  [xml]$xml = Get-Content -Raw $propsPath
  $packageVersion = Get-XmlNodeText -Node ($xml.Project.PropertyGroup.CompareViSharedPackageVersion | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($packageVersion) -and $packageVersion -notmatch '^\$\(.+\)$') {
    return $packageVersion
  }

  $version = Get-XmlNodeText -Node ($xml.Project.PropertyGroup.Version | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($version)) {
    return $version
  }

  throw "Unable to resolve CompareVi.Shared package version from Directory.Build.props"
}

function Get-SharedPackageVersion {
  param([string]$CsprojPath)
  [xml]$xml = Get-Content -Raw $CsprojPath
  $packageVersion = Get-XmlNodeText -Node ($xml.Project.PropertyGroup.PackageVersion | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($packageVersion) -and $packageVersion -notmatch '^\$\(.+\)$') { return $packageVersion }
  $version = Get-XmlNodeText -Node ($xml.Project.PropertyGroup.Version | Select-Object -First 1)
  if (-not [string]::IsNullOrWhiteSpace($version) -and $version -notmatch '^\$\(.+\)$') { return $version }
  return Get-SharedPackageVersionFromProps
}

function Ensure-Dir($path) {
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Zip-Dir($sourceDir, $zipPath) {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  Compress-Archive -Path (Join-Path $sourceDir '*') -DestinationPath $zipPath
}

function TarGz-Dir($sourceDir, $tarGzPath) {
  if (Test-Path $tarGzPath) { Remove-Item $tarGzPath -Force }
  # Use system tar; on Windows this is bsdtar. Permissions for linux/osx binaries
  # created on Windows may not preserve +x; advise consumers to chmod after extract.
  tar -czf $tarGzPath -C $sourceDir .
}

function Copy-Docs($destDir) {
  $root = Resolve-Path '.' | Select-Object -ExpandProperty Path
  foreach ($f in @('LICENSE','README.md','CHANGELOG.md')) {
    $p = Join-Path $root $f
    if (Test-Path $p) {
      Copy-Item $p (Join-Path $destDir $f) -Force
    }
  }
}

function Resolve-SharedSourceSelection {
  param(
    [string]$ProjectFullPath,
    [string]$RequestedSourceMode,
    [string]$SharedPackageVersion,
    [string]$SharedPackageFeedPath
  )

  $output = dotnet msbuild $ProjectFullPath -nologo -t:PrintCompareViSharedSource `
    "-p:CompareViSharedSource=$RequestedSourceMode" `
    "-p:CompareViSharedPackageVersion=$SharedPackageVersion" `
    "-p:CompareViSharedPackageFeed=$SharedPackageFeedPath" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to evaluate CompareVi.Shared source resolution."
  }

  $text = ($output | Out-String)
  $resolved = [regex]::Match($text, 'CompareViSharedResolvedSource=([^;]+);').Groups[1].Value
  $resolved = ($resolved -replace '\s+', '').Trim()
  $packageAvailable = [regex]::Match($text, 'CompareViSharedPackageAvailable=([A-Za-z0-9._-]+)').Groups[1].Value
  if ([string]::IsNullOrWhiteSpace($resolved)) {
    throw "Failed to parse CompareViSharedResolvedSource from msbuild output."
  }

  return [pscustomobject]@{
    RequestedSourceMode = $RequestedSourceMode
    ResolvedSource = $resolved
    PackageAvailable = $packageAvailable
    Raw = $text.Trim()
  }
}

function Write-JsonReport {
  param(
    [string]$Path,
    [object]$Data
  )

  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Dir $dir }
  $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-CliPublish {
  param(
    [string]$ProjectFullPath,
    [string]$Rid,
    [string]$OutDir,
    [bool]$IsSelfContained,
    [bool]$EnableSingleFile,
    [string]$BuildConfig,
    [string]$SharedSourceMode,
    [string]$SharedPackageVersion,
    [string]$SharedPackageFeedPath
  )

  $args = @(
    'publish',
    $ProjectFullPath,
    '-c', $BuildConfig,
    '-r', $Rid,
    '--self-contained', ($IsSelfContained ? 'true' : 'false'),
    '-p:PublishTrimmed=false',
    "-p:CompareViSharedSource=$SharedSourceMode",
    "-p:CompareViSharedPackageVersion=$SharedPackageVersion",
    "-p:CompareViSharedPackageFeed=$SharedPackageFeedPath",
    '-o', $OutDir
  )
  if ($IsSelfContained -and $EnableSingleFile) {
    $args += '-p:PublishSingleFile=true'
    $args += '-p:IncludeNativeLibrariesForSelfExtract=true'
  }
  if ($SharedSourceMode -ne 'project') {
    $args += '--source'
    $args += $SharedPackageFeedPath
    $args += '--source'
    $args += 'https://api.nuget.org/v3/index.json'
  }
  dotnet @args
}

$version = Get-VersionFromProps
Write-Host "Publishing comparevi-cli version $version" -ForegroundColor Cyan

$projFull = Resolve-Path $ProjectPath | Select-Object -ExpandProperty Path
$sharedProjFull = Resolve-Path $SharedProjectPath | Select-Object -ExpandProperty Path
$root = Resolve-Path '.' | Select-Object -ExpandProperty Path
$outRoot = if ([System.IO.Path]::IsPathRooted($OutputRoot)) {
  $OutputRoot
} else {
  Join-Path $root $OutputRoot
}
Ensure-Dir $outRoot

$sharedFeed = if ([System.IO.Path]::IsPathRooted($CompareViSharedPackageFeed)) {
  $CompareViSharedPackageFeed
} else {
  Join-Path $root $CompareViSharedPackageFeed
}
Ensure-Dir $sharedFeed

if ([string]::IsNullOrWhiteSpace($CompareViSharedPackageVersion)) {
  $CompareViSharedPackageVersion = Get-SharedPackageVersion -CsprojPath $sharedProjFull
}

if ($CompareViSharedSource -ne 'project' -and $PrepareSharedPackageFeed) {
  Write-Host "Preparing CompareVi.Shared feed at $sharedFeed (version $CompareViSharedPackageVersion)" -ForegroundColor Cyan
  dotnet restore $sharedProjFull
  dotnet build -c $Configuration $sharedProjFull --no-restore
  dotnet pack -c $Configuration $sharedProjFull -o $sharedFeed --no-build `
    -p:PackageVersion=$CompareViSharedPackageVersion `
    -p:Version=$CompareViSharedPackageVersion
}

$sharedSourceSelection = Resolve-SharedSourceSelection -ProjectFullPath $projFull `
  -RequestedSourceMode $CompareViSharedSource `
  -SharedPackageVersion $CompareViSharedPackageVersion `
  -SharedPackageFeedPath $sharedFeed

Write-Host ("CompareVi.Shared source requested={0} resolved={1} packageAvailable={2}" -f
  $sharedSourceSelection.RequestedSourceMode,
  $sharedSourceSelection.ResolvedSource,
  $sharedSourceSelection.PackageAvailable) -ForegroundColor Cyan

$sharedSourceReport = [ordered]@{
  schema = 'release/shared-source-resolution@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  requestedSource = $sharedSourceSelection.RequestedSourceMode
  resolvedSource = $sharedSourceSelection.ResolvedSource
  packageAvailable = $sharedSourceSelection.PackageAvailable
  packageVersion = $CompareViSharedPackageVersion
  packageFeed = $sharedFeed
  prepareSharedPackageFeed = [bool]$PrepareSharedPackageFeed
  failOnSharedFallback = [bool]$FailOnSharedFallback
}
Write-JsonReport -Path $SharedSourceReportPath -Data $sharedSourceReport

if ($FailOnSharedFallback -and $CompareViSharedSource -ne 'project' -and $sharedSourceSelection.ResolvedSource -ne 'package') {
  throw "CompareVi.Shared source fallback detected: requested=$CompareViSharedSource resolved=$($sharedSourceSelection.ResolvedSource)"
}

foreach ($rid in $Rids) {
  if ($FrameworkDependent) {
    $out = Join-Path $outRoot "fxdependent/$rid"
    Ensure-Dir $out
    Invoke-CliPublish -ProjectFullPath $projFull -Rid $rid -OutDir $out -IsSelfContained:$false `
      -EnableSingleFile:$false -BuildConfig $Configuration -SharedSourceMode $CompareViSharedSource `
      -SharedPackageVersion $CompareViSharedPackageVersion -SharedPackageFeedPath $sharedFeed
    Copy-Docs $out
    if ($rid -like 'win-*') {
      $zip = Join-Path $outRoot ("comparevi-cli-v{0}-{1}-fxdependent.zip" -f $version,$rid)
      Zip-Dir $out $zip
    } else {
      $tgz = Join-Path $outRoot ("comparevi-cli-v{0}-{1}-fxdependent.tar.gz" -f $version,$rid)
      TarGz-Dir $out $tgz
    }
  }

  if ($SelfContained) {
    $out = Join-Path $outRoot "selfcontained/$rid"
    Ensure-Dir $out
    Invoke-CliPublish -ProjectFullPath $projFull -Rid $rid -OutDir $out -IsSelfContained:$true `
      -EnableSingleFile:$SingleFile -BuildConfig $Configuration -SharedSourceMode $CompareViSharedSource `
      -SharedPackageVersion $CompareViSharedPackageVersion -SharedPackageFeedPath $sharedFeed
    Copy-Docs $out
    if ($rid -like 'win-*') {
      $zip = Join-Path $outRoot ("comparevi-cli-v{0}-{1}-selfcontained.zip" -f $version,$rid)
      Zip-Dir $out $zip
    } else {
      $tgz = Join-Path $outRoot ("comparevi-cli-v{0}-{1}-selfcontained.tar.gz" -f $version,$rid)
      TarGz-Dir $out $tgz
    }
  }
}

Write-Host "Artifacts ready under $outRoot" -ForegroundColor Green

# Generate SHA256SUMS.txt for all archives
$archives = Get-ChildItem $outRoot -File -Recurse | Where-Object { $_.Name -match '\.zip$|\.tar\.gz$' }
if ($archives) {
  $sumPath = Join-Path $outRoot 'SHA256SUMS.txt'
  if (Test-Path $sumPath) { Remove-Item $sumPath -Force }
  foreach ($a in $archives) {
    $hash = (Get-FileHash -Algorithm SHA256 $a.FullName).Hash.ToLower()
    # Write relative path from $outRoot for readability
    $rel = Resolve-Path -Relative $a.FullName
    "$hash  $rel" | Out-File -FilePath $sumPath -Append -Encoding ascii
  }
  Write-Host "Checksums written to $sumPath" -ForegroundColor Green
}
