[CmdletBinding()]
param(
  [Parameter(Mandatory = $false)]
  [string]$ResultsDir = 'tests/results/pester-windows-container-surface',

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = 'pester-windows-container-surface.json',

  [Parameter(Mandatory = $false)]
  [string]$PinnedImage = 'nationalinstruments/labview:2026q1-windows',

  [Parameter(Mandatory = $false)]
  [string]$HostPlatformOverride = '',

  [Parameter(Mandatory = $false)]
  [string]$DockerServerJson = '',

  [Parameter(Mandatory = $false)]
  [string]$ImageInspectJson = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-OptionalPath {
  param(
    [Parameter(Mandatory = $true)][string]$BasePath,
    [string]$PathValue
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function Read-JsonFromSource {
  param(
    [string]$InlineJson,
    [string]$FilePath
  )

  if (-not [string]::IsNullOrWhiteSpace($InlineJson)) {
    return $InlineJson | ConvertFrom-Json -ErrorAction Stop
  }
  if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    return Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Json -ErrorAction Stop
  }
  return $null
}

$resolvedResultsDir = [System.IO.Path]::GetFullPath($ResultsDir)
if (-not (Test-Path -LiteralPath $resolvedResultsDir -PathType Container)) {
  New-Item -ItemType Directory -Path $resolvedResultsDir -Force | Out-Null
}
$resolvedOutputPath = Resolve-OptionalPath -BasePath $resolvedResultsDir -PathValue $OutputPath
if (-not $resolvedOutputPath) {
  $resolvedOutputPath = Join-Path $resolvedResultsDir 'pester-windows-container-surface.json'
}

$hostPlatform = if (-not [string]::IsNullOrWhiteSpace($HostPlatformOverride)) {
  $HostPlatformOverride
} else {
  [System.Environment]::OSVersion.Platform.ToString()
}

$status = 'unknown'
$reason = 'probe-not-run'
$server = $null
$imageInfo = $null
$dockerCommand = Get-Command docker -ErrorAction SilentlyContinue

if ($hostPlatform -notmatch 'Win') {
  $status = 'not-windows-host'
  $reason = 'surface-requires-windows-host'
} elseif (-not $dockerCommand -and [string]::IsNullOrWhiteSpace($DockerServerJson)) {
  $status = 'docker-cli-missing'
  $reason = 'docker-cli-not-found'
} else {
  try {
    if ([string]::IsNullOrWhiteSpace($DockerServerJson)) {
      $server = docker version --format '{{json .Server}}' | ConvertFrom-Json -ErrorAction Stop
    } else {
      $server = Read-JsonFromSource -InlineJson $DockerServerJson
    }
  } catch {
    $status = 'docker-unavailable'
    $reason = 'docker-server-query-failed'
  }

  if ($server) {
    $osType = if ($server.PSObject.Properties.Name -contains 'Os') { [string]$server.Os } elseif ($server.PSObject.Properties.Name -contains 'OSType') { [string]$server.OSType } else { '' }
    if ($osType -ne 'windows') {
      $status = 'docker-engine-not-windows'
      $reason = 'docker-server-not-windows'
    } else {
      try {
        if ([string]::IsNullOrWhiteSpace($ImageInspectJson)) {
          $inspectRaw = docker image inspect $PinnedImage --format '{{json .}}' 2>$null
          if ([string]::IsNullOrWhiteSpace($inspectRaw)) {
            $status = 'ni-image-missing'
            $reason = 'pinned-image-not-present'
          } else {
            $imageInfo = $inspectRaw | ConvertFrom-Json -ErrorAction Stop
            $status = 'ready'
            $reason = 'windows-container-surface-ready'
          }
        } else {
          $imageInfo = Read-JsonFromSource -InlineJson $ImageInspectJson
          $status = 'ready'
          $reason = 'windows-container-surface-ready'
        }
      } catch {
        $status = 'ni-image-missing'
        $reason = 'pinned-image-not-present'
      }
    }
  }
}

$payload = [ordered]@{
  schema = 'pester-windows-container-surface@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  hostPlatform = [string]$hostPlatform
  status = [string]$status
  reason = [string]$reason
  pinnedImage = [string]$PinnedImage
  recommendedCommands = @(
    'npm run docker:ni:windows:bootstrap',
    'npm run compare:docker:ni:windows:probe',
    'npm run compare:docker:ni:windows'
  )
  dockerServer = if ($server) { $server } else { $null }
  pinnedImagePresent = [bool]$imageInfo
  pinnedImageInfo = if ($imageInfo) { $imageInfo } else { $null }
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8

if ($env:GITHUB_OUTPUT) {
  "status=$($payload.status)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "reason=$($payload.reason)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
  "path=$resolvedOutputPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

Write-Host '### Pester Windows container surface' -ForegroundColor Cyan
Write-Host ("status : {0}" -f $payload.status)
Write-Host ("reason : {0}" -f $payload.reason)
Write-Host ("path   : {0}" -f $resolvedOutputPath)

exit 0
