#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KnownVICompareReportLeafNames = @(
  'compare-report.html',
  'compare-report.xml',
  'compare-report.txt',
  'cli-compare-report.html',
  'cli-compare-report.xml',
  'cli-compare-report.txt',
  'linux-compare-report.html',
  'linux-compare-report.xml',
  'linux-compare-report.txt',
  'windows-compare-report.html',
  'windows-compare-report.xml',
  'windows-compare-report.txt'
)

function Resolve-VICompareArtifactPath {
  param(
    [AllowEmptyString()][string]$PathValue,
    [string[]]$BaseDirectories = @()
  )

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    $candidates.Add([System.IO.Path]::GetFullPath($PathValue)) | Out-Null
  } else {
    foreach ($baseDirectory in @($BaseDirectories)) {
      if ([string]::IsNullOrWhiteSpace($baseDirectory)) { continue }
      $candidates.Add([System.IO.Path]::GetFullPath((Join-Path $baseDirectory $PathValue))) | Out-Null
    }
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return $null
}

function Test-IsVICompareReportArtifactName {
  param(
    [AllowEmptyString()][string]$Name
  )

  if ([string]::IsNullOrWhiteSpace($Name)) {
    return $false
  }

  $leafName = [System.IO.Path]::GetFileName($Name)
  if ([string]::IsNullOrWhiteSpace($leafName)) {
    return $false
  }

  if ($script:KnownVICompareReportLeafNames -contains $leafName) {
    return $true
  }

  if ($leafName -match '^(?:(?:compare|diff|print|cli-compare|linux-compare|windows-compare)-report(?:-.+)?)\.(?:html|xml|txt)$') {
    return $true
  }

  return $false
}

function Get-VICompareReportCandidatesFromCapture {
  param(
    [AllowEmptyString()][string]$CapturePath,
    [string[]]$BaseDirectories = @()
  )

  if ([string]::IsNullOrWhiteSpace($CapturePath) -or -not (Test-Path -LiteralPath $CapturePath -PathType Leaf)) {
    return @()
  }

  $captureDirectory = Split-Path -Parent $CapturePath
  $resolutionBases = @($captureDirectory) + @($BaseDirectories)

  try {
    $capture = Get-Content -LiteralPath $CapturePath -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 12
  } catch {
    return @()
  }

  $candidateValues = New-Object System.Collections.Generic.List[string]
  foreach ($nodeName in @('out', 'cli')) {
    if (-not $capture.PSObject.Properties[$nodeName]) { continue }
    $node = $capture.$nodeName
    if (-not $node) { continue }
    foreach ($propertyName in @('reportHtml', 'reportPath')) {
      if ($node.PSObject.Properties[$propertyName] -and $node.$propertyName) {
        $candidateValues.Add([string]$node.$propertyName) | Out-Null
      }
    }
  }
  if ($capture.PSObject.Properties['reportPath'] -and $capture.reportPath) {
    $candidateValues.Add([string]$capture.reportPath) | Out-Null
  }

  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($candidateValue in ($candidateValues | Select-Object -Unique)) {
    $candidatePath = Resolve-VICompareArtifactPath -PathValue $candidateValue -BaseDirectories $resolutionBases
    if ($candidatePath -and -not $resolved.Contains($candidatePath)) {
      $resolved.Add($candidatePath) | Out-Null
    }
  }

  return @($resolved.ToArray())
}

function Find-VICompareReportArtifact {
  param(
    [AllowEmptyString()][string]$ExplicitReportPath,
    [AllowEmptyString()][string]$CapturePath,
    [string[]]$SearchDirectories = @(),
    [switch]$Recursive
  )

  $existingDirectories = @(
    $SearchDirectories |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { [System.IO.Path]::GetFullPath($_) } |
      Where-Object { Test-Path -LiteralPath $_ -PathType Container } |
      Select-Object -Unique
  )

  $explicitPath = Resolve-VICompareArtifactPath -PathValue $ExplicitReportPath -BaseDirectories $existingDirectories
  if ($explicitPath) {
    return $explicitPath
  }

  $captureCandidates = @(Get-VICompareReportCandidatesFromCapture -CapturePath $CapturePath -BaseDirectories $existingDirectories)
  if ($captureCandidates.Count -gt 0) {
    return $captureCandidates[0]
  }

  foreach ($directory in $existingDirectories) {
    foreach ($leafName in $script:KnownVICompareReportLeafNames) {
      $candidatePath = Join-Path $directory $leafName
      if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        return [System.IO.Path]::GetFullPath($candidatePath)
      }
    }
  }

  foreach ($directory in $existingDirectories) {
    try {
      $candidateFiles = if ($Recursive) {
        Get-ChildItem -LiteralPath $directory -Recurse -File -ErrorAction SilentlyContinue
      } else {
        Get-ChildItem -LiteralPath $directory -File -ErrorAction SilentlyContinue
      }
      $matchedFile = @(
        $candidateFiles |
          Where-Object { Test-IsVICompareReportArtifactName -Name $_.Name } |
          Sort-Object FullName |
          Select-Object -First 1
      )
      if ($matchedFile.Count -gt 0) {
        return [System.IO.Path]::GetFullPath([string]$matchedFile[0].FullName)
      }
    } catch {}
  }

  return $null
}

Export-ModuleMember -Function Resolve-VICompareArtifactPath, Test-IsVICompareReportArtifactName, Get-VICompareReportCandidatesFromCapture, Find-VICompareReportArtifact
