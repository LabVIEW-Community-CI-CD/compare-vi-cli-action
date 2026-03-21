#Requires -Version 7.0

[CmdletBinding()]
param(
  [ValidateSet('ni-example', 'installed-cli-operation')]
  [string]$SourceKind = 'ni-example',
  [string]$SourceExamplePath = '',
  [string]$DestinationPath,
  [string]$LabVIEWPathHint,
  [string]$ReceiptPath,
  [switch]$Force,
  [switch]$SkipSchemaValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
  return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory)][string]$BasePath,
    [Parameter(Mandatory)][string]$PathValue
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $PathValue))
}

function New-DirectoryIfMissing {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
      New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Convert-ToRepoRelativePath {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$PathValue
  )

  $resolved = [System.IO.Path]::GetFullPath($PathValue)
  $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $resolved)
  if ($relative -eq '.') {
    return '.'
  }

  if ($relative -eq '..' -or
      $relative.StartsWith('..' + [System.IO.Path]::DirectorySeparatorChar) -or
      $relative.StartsWith('..' + [System.IO.Path]::AltDirectorySeparatorChar)) {
    return ($resolved -replace '\\', '/')
  }

  return ($relative -replace '\\', '/')
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Schema validation runner not found at '$runner'."
  }

  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Get-LabVIEWVersionHint {
  param([AllowNull()][string]$PathValue)

  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  if ($PathValue -match 'LabVIEW\s+(\d{4}(?:\s*Q\d)?)') {
    return (($matches[1] -replace '\s+', '')).Trim()
  }

  return $null
}

function Get-ScaffoldSourceDefinition {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('ni-example', 'installed-cli-operation')]
    [string]$SourceKind
  )

  switch ($SourceKind) {
    'ni-example' {
      return [ordered]@{
        defaultPath = 'C:\Users\Public\Documents\National Instruments\LabVIEW CLI\Examples\AddTwoNumbers'
        requiredFiles = @(
          'AddTwoNumbers.lvclass',
          'AddTwoNumbers.vi',
          'GetHelp.vi',
          'RunOperation.vi'
        )
        notes = @(
          'Scaffolded from the installed NI AddTwoNumbers example.',
          'The destination is intentionally disposable and is not a repo-owned payload.'
        )
      }
    }
    'installed-cli-operation' {
      return [ordered]@{
        defaultPath = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\CreateComparisonReport'
        requiredFiles = @(
          'GetHelp.vi',
          'RunOperation.vi'
        )
        notes = @(
          'Scaffolded from an installed official LabVIEW CLI operation directory.',
          'The copied files remain disposable bootstrap material and must not be committed verbatim as repo-owned payload sources.'
        )
      }
    }
    default {
      throw "Unsupported scaffold source kind '$SourceKind'."
    }
  }
}

function Get-PreferredLabVIEWHint {
  param([Parameter(Mandatory)][string]$RepoRoot)

  $vendorModule = Join-Path $RepoRoot 'tools' 'VendorTools.psm1'
  if (-not (Test-Path -LiteralPath $vendorModule -PathType Leaf)) {
    return $null
  }

  Import-Module $vendorModule -Force | Out-Null
  $candidates = @(Get-LabVIEWCandidateExePaths)
  if ($candidates.Count -eq 0) {
    return $null
  }

  $preferred32Bit2026 = @(
    $candidates |
      Where-Object {
        ($_ -match 'LabVIEW\s+2026') -and
        ($_ -match '(?i)(Program Files \(x86\)|\(32-bit\))')
      } |
      Select-Object -First 1
  )
  if ($preferred32Bit2026.Count -gt 0) {
    return $preferred32Bit2026[0]
  }

  $preferred = @($candidates | Where-Object { $_ -match 'LabVIEW\s+2026' } | Select-Object -First 1)
  if ($preferred.Count -gt 0) {
    return $preferred[0]
  }

  return $candidates[0]
}

function Get-RelativeFileList {
  param(
    [Parameter(Mandatory)][string]$RootPath,
    [string[]]$ExcludedRelativePaths = @()
  )

  $excludedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($pathValue in $ExcludedRelativePaths) {
    if (-not [string]::IsNullOrWhiteSpace($pathValue)) {
      [void]$excludedSet.Add(($pathValue -replace '\\', '/'))
    }
  }

  $files = @(Get-ChildItem -LiteralPath $RootPath -File -Recurse | Sort-Object FullName)
  $relativePaths = New-Object System.Collections.Generic.List[string]
  foreach ($file in $files) {
    $relativePath = [System.IO.Path]::GetRelativePath($RootPath, $file.FullName)
    $normalizedRelativePath = $relativePath -replace '\\', '/'
    if ($excludedSet.Contains($normalizedRelativePath)) {
      continue
    }

    $relativePaths.Add($normalizedRelativePath) | Out-Null
  }

  return @($relativePaths.ToArray())
}

$repoRoot = Resolve-RepoRoot
$customOperationResultsRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'tests' 'results' '_agent' 'custom-operation-scaffolds'))
$sourceDefinition = Get-ScaffoldSourceDefinition -SourceKind $SourceKind

if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
  $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $DestinationPath = Join-Path $customOperationResultsRoot ("AddTwoNumbers-{0}" -f $timestamp)
}

$effectiveSourcePath = if ([string]::IsNullOrWhiteSpace($SourceExamplePath)) {
  [string]$sourceDefinition.defaultPath
} else {
  $SourceExamplePath
}

$resolvedSource = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $effectiveSourcePath
$resolvedDestination = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $DestinationPath
$resolvedCustomOperationResultsRoot = [System.IO.Path]::GetFullPath($customOperationResultsRoot)
$resolvedLabVIEWPathHint = if ([string]::IsNullOrWhiteSpace($LabVIEWPathHint)) {
  Get-PreferredLabVIEWHint -RepoRoot $repoRoot
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $LabVIEWPathHint
}

if (-not (Test-Path -LiteralPath $resolvedSource -PathType Container)) {
  throw "LabVIEW CLI scaffold source was not found at '$resolvedSource'."
}

$sourceName = Split-Path -Leaf $resolvedSource
$sourceFiles = @($sourceDefinition.requiredFiles)
foreach ($requiredFile in $sourceFiles) {
  $requiredPath = Join-Path $resolvedSource $requiredFile
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "LabVIEW CLI scaffold source is incomplete; expected '$requiredFile' under '$resolvedSource'."
  }
}

$sourcePathWithSeparator = $resolvedSource.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
$destinationPathWithSeparator = $resolvedDestination.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($resolvedSource -eq $resolvedDestination -or
    $resolvedDestination.StartsWith($sourcePathWithSeparator, [System.StringComparison]::OrdinalIgnoreCase) -or
    $resolvedSource.StartsWith($destinationPathWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'Source and destination must be disjoint directories.'
}

$destinationInsideRepo = $resolvedDestination.StartsWith($repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
  $resolvedDestination.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
if ($resolvedDestination.Equals($resolvedCustomOperationResultsRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw ("Destination '{0}' cannot be the shared scaffold root itself. Choose a child workspace path under 'tests/results/_agent/custom-operation-scaffolds/'." -f $resolvedDestination)
}
$destinationAllowedInRepo = $resolvedDestination.StartsWith($resolvedCustomOperationResultsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
if ($destinationInsideRepo -and -not $destinationAllowedInRepo) {
  throw ("Destination '{0}' is inside the repository but outside 'tests/results/_agent/custom-operation-scaffolds/'. This helper refuses to copy NI example files into git-tracked source trees." -f $resolvedDestination)
}

if (Test-Path -LiteralPath $resolvedDestination) {
  if (-not $Force.IsPresent) {
    throw "Destination already exists: '$resolvedDestination'. Pass -Force to overwrite."
  }

  Remove-Item -LiteralPath $resolvedDestination -Recurse -Force
}

New-DirectoryIfMissing -Path (Split-Path -Parent $resolvedDestination) | Out-Null
Copy-Item -LiteralPath $resolvedSource -Destination $resolvedDestination -Recurse -Force

$resolvedDestination = (Resolve-Path -LiteralPath $resolvedDestination).Path
$defaultReceiptPath = Join-Path $resolvedDestination 'custom-operation-scaffold.json'
$resolvedReceiptPath = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  $defaultReceiptPath
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}
New-DirectoryIfMissing -Path (Split-Path -Parent $resolvedReceiptPath) | Out-Null

$excludedRelativePaths = @()
if ($resolvedReceiptPath.StartsWith($resolvedDestination.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
  $excludedRelativePaths += ([System.IO.Path]::GetRelativePath($resolvedDestination, $resolvedReceiptPath) -replace '\\', '/')
}
$copiedFiles = Get-RelativeFileList -RootPath $resolvedDestination -ExcludedRelativePaths $excludedRelativePaths
$receipt = [ordered]@{
  schema = 'labview-cli-custom-operation-scaffold@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  status = 'succeeded'
  sourceKind = $SourceKind
  sourceExampleName = $sourceName
  sourceExamplePath = $resolvedSource
  destinationPath = $resolvedDestination
  destinationPolicy = if ($destinationInsideRepo) { 'repo-results-root' } else { 'outside-repo' }
  receiptPath = $resolvedReceiptPath
  sourceExists = $true
  destinationExists = (Test-Path -LiteralPath $resolvedDestination -PathType Container)
  labviewPathHint = $resolvedLabVIEWPathHint
  labviewVersionHint = Get-LabVIEWVersionHint -PathValue $resolvedLabVIEWPathHint
  copiedFileCount = $copiedFiles.Count
  copiedFiles = @($copiedFiles)
  notes = @($sourceDefinition.notes)
}

$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedReceiptPath -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'labview-cli-custom-operation-scaffold-v1.schema.json'
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $schemaPath -DataPath $resolvedReceiptPath
}

Write-Information ("LabVIEW CLI custom operation workspace scaffolded at: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $resolvedDestination)) -InformationAction Continue
return [pscustomobject]$receipt
