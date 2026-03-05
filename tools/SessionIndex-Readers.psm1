Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SessionIndexCandidates {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDir
  )

  $base = if ([System.IO.Path]::IsPathRooted($ResultsDir)) {
    [System.IO.Path]::GetFullPath($ResultsDir)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ResultsDir))
  }

  [pscustomobject]@{
    ResultsDir = $base
    V2Path = Join-Path $base 'session-index-v2.json'
    V1Path = Join-Path $base 'session-index.json'
  }
}

function Resolve-PreferredSessionIndexPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDir
  )

  $paths = Resolve-SessionIndexCandidates -ResultsDir $ResultsDir
  if (Test-Path -LiteralPath $paths.V2Path -PathType Leaf) {
    return [pscustomobject]@{ Path = $paths.V2Path; Source = 'v2' }
  }
  if (Test-Path -LiteralPath $paths.V1Path -PathType Leaf) {
    return [pscustomobject]@{ Path = $paths.V1Path; Source = 'v1' }
  }

  return [pscustomobject]@{ Path = $null; Source = 'missing' }
}

function Read-PreferredSessionIndex {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsDir
  )

  $resolved = Resolve-PreferredSessionIndexPath -ResultsDir $ResultsDir
  $payload = [ordered]@{
    Path = $resolved.Path
    Source = $resolved.Source
    Data = $null
    Error = $null
  }

  if (-not $resolved.Path) {
    $payload.Error = "No session index found under $ResultsDir"
    return [pscustomobject]$payload
  }

  try {
    $raw = Get-Content -LiteralPath $resolved.Path -Raw -Encoding utf8
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $payload.Data = $raw | ConvertFrom-Json -ErrorAction Stop
    }
  } catch {
    $payload.Error = $_.Exception.Message
  }

  return [pscustomobject]$payload
}

Export-ModuleMember -Function Resolve-SessionIndexCandidates, Resolve-PreferredSessionIndexPath, Read-PreferredSessionIndex