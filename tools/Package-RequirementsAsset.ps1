param(
  [string]$RequirementsDir = 'docs/requirements',
  [string]$OutputRoot = 'artifacts/cli',
  [string]$Version,
  [switch]$RefreshChecksums = $true
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
  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

$repoRoot = Resolve-Path '.' | Select-Object -ExpandProperty Path
$requirementsPath = if ([System.IO.Path]::IsPathRooted($RequirementsDir)) { $RequirementsDir } else { Join-Path $repoRoot $RequirementsDir }
if (-not (Test-Path -LiteralPath $requirementsPath -PathType Container)) {
  throw ("Requirements directory not found: {0}" -f $requirementsPath)
}

$effectiveVersion = if ([string]::IsNullOrWhiteSpace($Version)) { Get-VersionFromProps } else { $Version }
$outputRootResolved = if ([System.IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot } else { Join-Path $repoRoot $OutputRoot }
Ensure-Dir $outputRootResolved

$zipPath = Join-Path $outputRootResolved ("comparevi-cli-requirements-v{0}.zip" -f $effectiveVersion)
if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
  Remove-Item -LiteralPath $zipPath -Force
}

Compress-Archive -Path (Join-Path $requirementsPath '*') -DestinationPath $zipPath -Force
Write-Host ("Requirements asset written: {0}" -f $zipPath) -ForegroundColor Green

if ($RefreshChecksums) {
  $archives = Get-ChildItem -LiteralPath $outputRootResolved -File -Recurse | Where-Object { $_.Name -match '\.zip$|\.tar\.gz$' }
  if ($archives) {
    $sumPath = Join-Path $outputRootResolved 'SHA256SUMS.txt'
    if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
      Remove-Item -LiteralPath $sumPath -Force
    }

    foreach ($archive in @($archives | Sort-Object Name)) {
      $hash = (Get-FileHash -Algorithm SHA256 $archive.FullName).Hash.ToLower()
      $rel = [System.IO.Path]::GetRelativePath($outputRootResolved, $archive.FullName).Replace('\\','/')
      "$hash  $rel" | Out-File -FilePath $sumPath -Append -Encoding ascii
    }

    Write-Host ("Checksums refreshed: {0}" -f $sumPath) -ForegroundColor Green
  }
}
