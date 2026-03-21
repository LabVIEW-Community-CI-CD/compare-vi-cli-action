#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$BundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$ReportPath = '',
  [string]$MarkdownPath = '',
  [switch]$SkipSchemaValidation,
  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binaryToolsModule = Join-Path $PSScriptRoot 'LabVIEWBinaryTools.psm1'
if (-not (Test-Path -LiteralPath $binaryToolsModule -PathType Leaf)) {
  throw ("LabVIEWBinaryTools.psm1 not found: {0}" -f $binaryToolsModule)
}
Import-Module $binaryToolsModule -Force

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

$repoRoot = Resolve-RepoRoot
$bundleResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $BundlePath
if (-not (Test-Path -LiteralPath $bundleResolved -PathType Container)) {
  throw "Operation payload bundle directory was not found at '$bundleResolved'."
}

$manifestPath = Join-Path $bundleResolved 'payload-provenance.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Operation payload manifest was not found at '$manifestPath'."
}

$schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'operation-payload-source-bundle-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $schemaPath -DataPath $manifestPath
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
$expectedFiles = @($manifest.expectedOperationFiles | ForEach-Object { [string]$_ })
$checkedInFiles = New-Object System.Collections.Generic.List[string]
$binaryOperationFiles = New-Object System.Collections.Generic.List[string]
$missingFiles = New-Object System.Collections.Generic.List[string]
$nonBinaryOperationFiles = New-Object System.Collections.Generic.List[string]
$fileStatuses = New-Object System.Collections.Generic.List[object]
foreach ($relativePath in $expectedFiles) {
  $candidatePath = Join-Path $bundleResolved $relativePath
  $exists = Test-Path -LiteralPath $candidatePath -PathType Leaf
  $isLabVIEWBinary = $false
  if ($exists) {
    $checkedInFiles.Add($relativePath) | Out-Null
    $isLabVIEWBinary = Test-IsLabVIEWBinaryFile -Path $candidatePath
    if ($isLabVIEWBinary) {
      $binaryOperationFiles.Add($relativePath) | Out-Null
    } else {
      $nonBinaryOperationFiles.Add($relativePath) | Out-Null
    }
  } else {
    $missingFiles.Add($relativePath) | Out-Null
  }
  $fileStatuses.Add([pscustomobject]@{
      path = $relativePath
      exists = $exists
      isLabVIEWBinary = $isLabVIEWBinary
    }) | Out-Null
}

$observedExecutableState = if ($missingFiles.Count -eq 0 -and $nonBinaryOperationFiles.Count -eq 0 -and $expectedFiles.Count -gt 0) {
  'runnable'
} else {
  'source-only'
}
$declaredExecutableState = [string]$manifest.executableState
$executableStateAligned = $declaredExecutableState -eq $observedExecutableState
$status = if ($executableStateAligned) { 'succeeded' } else { 'drift' }

$resultsRoot = New-DirectoryIfMissing -Path (Join-Path $repoRoot 'tests' 'results' '_agent' 'operation-payload-bundles' ([System.IO.Path]::GetFileName($bundleResolved)))
$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRoot 'operation-payload-source-bundle-inspection.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$markdownResolved = if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
  Join-Path $resultsRoot 'operation-payload-source-bundle-inspection.md'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $MarkdownPath
}
New-DirectoryIfMissing -Path (Split-Path -Parent $reportResolved) | Out-Null
New-DirectoryIfMissing -Path (Split-Path -Parent $markdownResolved) | Out-Null

$notes = New-Object System.Collections.Generic.List[string]
if ($status -eq 'succeeded') {
  $notes.Add(("Declared executable state matches observed state '{0}'." -f $observedExecutableState)) | Out-Null
} else {
  $notes.Add(("Declared executable state '{0}' does not match observed state '{1}'." -f $declaredExecutableState, $observedExecutableState)) | Out-Null
}
if ($missingFiles.Count -gt 0) {
  $notes.Add(("Missing runnable operation files: {0}." -f (($missingFiles.ToArray()) -join ', '))) | Out-Null
}
if ($nonBinaryOperationFiles.Count -gt 0) {
  $notes.Add(("Expected operation files are present but do not look like LabVIEW binaries: {0}." -f (($nonBinaryOperationFiles.ToArray()) -join ', '))) | Out-Null
}

$report = [ordered]@{
  schema = 'comparevi/operation-payload-source-bundle-inspection@v1'
  generatedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
  status = $status
  bundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $bundleResolved
  manifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $manifestPath
  name = [string]$manifest.name
  payloadMode = [string]$manifest.payloadMode
  currentState = [string]$manifest.currentState
  declaredExecutableState = $declaredExecutableState
  observedExecutableState = $observedExecutableState
  executableStateAligned = $executableStateAligned
  expectedOperationFiles = $expectedFiles
  checkedInOperationFiles = @($checkedInFiles.ToArray())
  binaryOperationFiles = @($binaryOperationFiles.ToArray())
  missingOperationFiles = @($missingFiles.ToArray())
  nonBinaryOperationFiles = @($nonBinaryOperationFiles.ToArray())
  operationFileStatus = @($fileStatuses.ToArray())
  promotionBlocked = [bool]$manifest.promotionBlocked
  blockingReasons = @($manifest.blockingReasons | ForEach-Object { [string]$_ })
  notes = @($notes.ToArray())
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportResolved -Encoding utf8

$markdownLines = New-Object System.Collections.Generic.List[string]
$markdownLines.Add('# Operation Payload Source Bundle Inspection') | Out-Null
$markdownLines.Add('') | Out-Null
$markdownLines.Add(('- Bundle: `{0}`' -f $report.bundlePath)) | Out-Null
$markdownLines.Add(('- Final status: `{0}`' -f $status)) | Out-Null
$markdownLines.Add(('- Current state: `{0}`' -f $report.currentState)) | Out-Null
$markdownLines.Add(('- Declared executable state: `{0}`' -f $declaredExecutableState)) | Out-Null
$markdownLines.Add(('- Observed executable state: `{0}`' -f $observedExecutableState)) | Out-Null
$markdownLines.Add('') | Out-Null
$markdownLines.Add('## Operation Files') | Out-Null
$markdownLines.Add('') | Out-Null
$markdownLines.Add('| File | Present | LabVIEW Binary |') | Out-Null
$markdownLines.Add('| --- | --- | --- |') | Out-Null
foreach ($statusRow in @($fileStatuses.ToArray())) {
  $markdownLines.Add(('| `{0}` | `{1}` | `{2}` |' -f $statusRow.path, ($(if ($statusRow.exists) { 'yes' } else { 'no' })), ($(if ($statusRow.isLabVIEWBinary) { 'yes' } else { 'no' })))) | Out-Null
}
$markdownLines.Add('') | Out-Null
$markdownLines.Add('## Notes') | Out-Null
$markdownLines.Add('') | Out-Null
foreach ($note in @($notes.ToArray())) {
  $markdownLines.Add(('- {0}' -f $note)) | Out-Null
}

$markdownLines -join [Environment]::NewLine | Set-Content -LiteralPath $markdownResolved -Encoding utf8

Write-Output ("Operation payload source bundle inspection report: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved))
Write-Output ("Operation payload source bundle inspection summary: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $markdownResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$report
}
