#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$BundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$InspectionReportPath = '',
  [string]$InspectionMarkdownPath = '',
  [string]$ReceiptPath = '',
  [switch]$SkipSchemaValidation,
  [switch]$PassThru
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

function Ensure-Directory {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
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

function Get-FilteredBlockingReasons {
  param([Parameter(Mandatory)][object[]]$Reasons)

  $filtered = New-Object System.Collections.Generic.List[string]
  foreach ($reason in @($Reasons | ForEach-Object { [string]$_ })) {
    if ([string]::IsNullOrWhiteSpace($reason)) {
      continue
    }

    if ($reason -match 'Runnable LabVIEW operation files are not checked in yet\.') {
      continue
    }

    $filtered.Add($reason) | Out-Null
  }

  return @($filtered.ToArray())
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

$resultsRoot = Ensure-Directory -Path (Join-Path $repoRoot 'tests' 'results' '_agent' 'operation-payload-bundles' ([System.IO.Path]::GetFileName($bundleResolved)))
$inspectionReportResolved = if ([string]::IsNullOrWhiteSpace($InspectionReportPath)) {
  Join-Path $resultsRoot 'operation-payload-source-bundle-inspection.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $InspectionReportPath
}
$inspectionMarkdownResolved = if ([string]::IsNullOrWhiteSpace($InspectionMarkdownPath)) {
  Join-Path $resultsRoot 'operation-payload-source-bundle-inspection.md'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $InspectionMarkdownPath
}
$receiptResolved = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  Join-Path $resultsRoot 'operation-payload-authoring-finalization.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}

Ensure-Directory -Path (Split-Path -Parent $inspectionReportResolved) | Out-Null
Ensure-Directory -Path (Split-Path -Parent $inspectionMarkdownResolved) | Out-Null
Ensure-Directory -Path (Split-Path -Parent $receiptResolved) | Out-Null

$inspectionScriptPath = Join-Path $repoRoot 'tools' 'Inspect-OperationPayloadSourceBundle.ps1'
if (-not (Test-Path -LiteralPath $inspectionScriptPath -PathType Leaf)) {
  throw "Inspect-OperationPayloadSourceBundle.ps1 not found at '$inspectionScriptPath'."
}

$inspectionInvocation = @(
  '-NoLogo',
  '-NoProfile',
  '-File', $inspectionScriptPath,
  '-BundlePath', $bundleResolved,
  '-ReportPath', $inspectionReportResolved,
  '-MarkdownPath', $inspectionMarkdownResolved
)
if ($SkipSchemaValidation.IsPresent) {
  $inspectionInvocation += '-SkipSchemaValidation'
}

$inspectionOutput = & pwsh @inspectionInvocation 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($inspectionOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Failed to inspect operation payload bundle: $message"
}

if (-not (Test-Path -LiteralPath $inspectionReportResolved -PathType Leaf)) {
  throw "Operation payload inspection report was not written to '$inspectionReportResolved'."
}

$inspection = Get-Content -LiteralPath $inspectionReportResolved -Raw | ConvertFrom-Json -Depth 20
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
$beforeDeclaredExecutableState = [string]$manifest.executableState
$beforeCurrentState = [string]$manifest.currentState
$beforeCheckedInOperationFiles = @($manifest.checkedInOperationFiles | ForEach-Object { [string]$_ })
$manifestUpdated = $false
$notes = New-Object System.Collections.Generic.List[string]
$status = 'blocked'

if ([string]$inspection.observedExecutableState -eq 'runnable') {
  $manifest.checkedInOperationFiles = @($inspection.checkedInOperationFiles | ForEach-Object { [string]$_ })
  $manifest.executableState = 'runnable'
  $manifest.currentState = 'authoring-complete'
  $manifest.promotionBlocked = $true

  $updatedBlockingReasons = @(Get-FilteredBlockingReasons -Reasons @($manifest.blockingReasons))
  if (-not ($updatedBlockingReasons | Where-Object { $_ -match 'No public workflow run has proven this repo-owned payload on an added or deleted VI\.' })) {
    $updatedBlockingReasons += 'No public workflow run has proven this repo-owned payload on an added or deleted VI.'
  }
  $manifest.blockingReasons = $updatedBlockingReasons

  $updatedNotes = New-Object System.Collections.Generic.List[string]
  foreach ($note in @($manifest.notes | ForEach-Object { [string]$_ })) {
    if (-not [string]::IsNullOrWhiteSpace($note)) {
      $updatedNotes.Add($note) | Out-Null
    }
  }
  if (-not ($updatedNotes | Where-Object { $_ -match 'Runnable repo-owned LabVIEW operation files are now checked in; public proof is still required before promotion\.' })) {
    $updatedNotes.Add('Runnable repo-owned LabVIEW operation files are now checked in; public proof is still required before promotion.') | Out-Null
  }
  $manifest.notes = @($updatedNotes.ToArray())

  $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8
  if (-not $SkipSchemaValidation.IsPresent) {
    $manifestSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'operation-payload-source-bundle-v1.schema.json'
    Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $manifestSchemaPath -DataPath $manifestPath
  }

  $manifestUpdated = $true
  $status = 'succeeded'
  $notes.Add('Updated payload provenance to declared executable state `runnable` based on observed LabVIEW binary files.') | Out-Null
  $notes.Add('Public standalone proof remains a separate blocker even after authoring completion.') | Out-Null
} else {
  $notes.Add('Bundle still inspects as `source-only`; payload provenance was left unchanged.') | Out-Null
  $notes.Add('Author repo-owned LabVIEW binary files first, then rerun this helper to finalize the source bundle metadata.') | Out-Null
}

$receipt = [ordered]@{
  schema = 'comparevi/operation-payload-authoring-finalization@v1'
  generatedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
  status = $status
  bundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $bundleResolved
  manifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $manifestPath
  inspectionReportPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionReportResolved
  inspectionMarkdownPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionMarkdownResolved
  manifestUpdated = $manifestUpdated
  beforeDeclaredExecutableState = $beforeDeclaredExecutableState
  observedExecutableState = [string]$inspection.observedExecutableState
  afterDeclaredExecutableState = [string]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20).executableState)
  beforeCurrentState = $beforeCurrentState
  afterCurrentState = [string]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20).currentState)
  checkedInOperationFilesBefore = @($beforeCheckedInOperationFiles)
  checkedInOperationFilesAfter = @(((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20).checkedInOperationFiles | ForEach-Object { [string]$_ }))
  promotionBlocked = [bool]((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20).promotionBlocked)
  blockingReasons = @(((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20).blockingReasons | ForEach-Object { [string]$_ }))
  notes = @($notes.ToArray())
}

$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  $receiptSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'operation-payload-authoring-finalization-v1.schema.json'
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $receiptSchemaPath -DataPath $receiptResolved
}

Write-Host ("Operation payload authoring finalization receipt: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $receiptResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$receipt
}
