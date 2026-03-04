param(
  [string]$ProjectPath = "src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj",
  [string]$Configuration = "Release",
  [string[]]$Rids = @("win-x64","linux-x64"),
  [string]$OutputRoot = "artifacts/cli",
  [switch]$FrameworkDependent = $false,
  [switch]$SelfContained = $true,
  [switch]$SingleFile = $true,
  [switch]$Deterministic = $true
)

$ErrorActionPreference = 'Stop'

function Get-VersionFromProps {
  $propsPath = Join-Path $PSScriptRoot '..' 'Directory.Build.props' | Resolve-Path | Select-Object -ExpandProperty Path
  [xml]$xml = Get-Content -Raw $propsPath
  $ver = $xml.Project.PropertyGroup.Version
  if ([string]::IsNullOrWhiteSpace($ver)) { return '0.0.0' }
  return $ver
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
  if ($LASTEXITCODE -ne 0) {
    throw ("tar failed while creating archive: {0}" -f $tarGzPath)
  }
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

$version = Get-VersionFromProps
Write-Host "Publishing comparevi-cli version $version" -ForegroundColor Cyan

$projFull = Resolve-Path $ProjectPath | Select-Object -ExpandProperty Path
$root = Resolve-Path '.' | Select-Object -ExpandProperty Path
$outRoot = Join-Path $root $OutputRoot
Ensure-Dir $outRoot

$normalizedRids = New-Object System.Collections.Generic.List[string]
foreach ($ridValue in @($Rids)) {
  foreach ($ridToken in @(([string]$ridValue) -split ',')) {
    $ridTrimmed = $ridToken.Trim()
    if (-not [string]::IsNullOrWhiteSpace($ridTrimmed)) {
      $normalizedRids.Add($ridTrimmed) | Out-Null
    }
  }
}
if ($normalizedRids.Count -eq 0) {
  throw 'No runtime identifiers resolved from -Rids.'
}

foreach ($rid in $normalizedRids) {
  if ($FrameworkDependent) {
    $out = Join-Path $outRoot "fxdependent/$rid"
    Ensure-Dir $out
    dotnet publish $projFull -c $Configuration -r $rid --self-contained false -p:PublishTrimmed=false -o $out
    if ($LASTEXITCODE -ne 0) {
      throw ("dotnet publish failed for RID '{0}' (framework-dependent)." -f $rid)
    }
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
    $props = @('PublishTrimmed=false')
    if ($Deterministic) {
      $props += 'Deterministic=true'
      $props += 'ContinuousIntegrationBuild=true'
      $props += 'DeterministicSourcePaths=true'
      $props += 'DebugType=none'
      $props += 'UseAppHost=true'
    }
    if ($SingleFile) { $props += 'PublishSingleFile=true'; $props += 'IncludeNativeLibrariesForSelfExtract=true' }
    $propArgs = $props | ForEach-Object { "-p:$_" }
    dotnet publish $projFull -c $Configuration -r $rid --self-contained true @propArgs -o $out
    if ($LASTEXITCODE -ne 0) {
      throw ("dotnet publish failed for RID '{0}' (self-contained)." -f $rid)
    }
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
  foreach ($a in @($archives | Sort-Object Name)) {
    $hash = (Get-FileHash -Algorithm SHA256 $a.FullName).Hash.ToLower()
    $rel = [System.IO.Path]::GetRelativePath($outRoot, $a.FullName).Replace('\\','/')
    "$hash  $rel" | Out-File -FilePath $sumPath -Append -Encoding ascii
  }
  Write-Host "Checksums written to $sumPath" -ForegroundColor Green
}
