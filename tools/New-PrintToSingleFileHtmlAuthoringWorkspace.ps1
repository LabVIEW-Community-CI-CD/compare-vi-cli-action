#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$PayloadBundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$InstalledOperationPath = '',
  [string]$DestinationPath = '',
  [string]$ReceiptPath = '',
  [string]$ScaffoldScriptPath = '',
  [switch]$Force,
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

$repoRoot = Resolve-RepoRoot
$payloadBundleResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadBundlePath
if (-not (Test-Path -LiteralPath $payloadBundleResolved -PathType Container)) {
  throw "PrintToSingleFileHtml payload bundle was not found at '$payloadBundleResolved'."
}

$payloadManifestPath = Join-Path $payloadBundleResolved 'payload-provenance.json'
if (-not (Test-Path -LiteralPath $payloadManifestPath -PathType Leaf)) {
  throw "Payload manifest was not found at '$payloadManifestPath'."
}

$payloadSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'operation-payload-source-bundle-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $payloadSchemaPath -DataPath $payloadManifestPath
}

$payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json -Depth 20
$sourceKind = [string]$payloadManifest.authoringBootstrap.sourceKind
$preferredInstalledOperation = [string]$payloadManifest.authoringBootstrap.preferredInstalledOperation
$installedOperationResolved = if ([string]::IsNullOrWhiteSpace($InstalledOperationPath)) {
  [System.IO.Path]::GetFullPath((Join-Path 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations' $preferredInstalledOperation))
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $InstalledOperationPath
}

$authoringRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'custom-operation-scaffolds'
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
  $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $DestinationPath = Join-Path $authoringRoot ("PrintToSingleFileHtml-{0}" -f $timestamp)
}
$destinationResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $DestinationPath
Ensure-Directory -Path (Split-Path -Parent $destinationResolved) | Out-Null

$scaffoldScriptResolved = if ([string]::IsNullOrWhiteSpace($ScaffoldScriptPath)) {
  Join-Path $repoRoot 'tools' 'New-LabVIEWCLICustomOperationWorkspace.ps1'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ScaffoldScriptPath
}
if (-not (Test-Path -LiteralPath $scaffoldScriptResolved -PathType Leaf)) {
  throw "Scaffold script was not found at '$scaffoldScriptResolved'."
}

$scaffoldInvocation = @(
  '-NoLogo',
  '-NoProfile',
  '-File', $scaffoldScriptResolved,
  '-SourceKind', $sourceKind,
  '-SourceExamplePath', $installedOperationResolved,
  '-DestinationPath', $destinationResolved
)
if ($Force.IsPresent) {
  $scaffoldInvocation += '-Force'
}
if ($SkipSchemaValidation.IsPresent) {
  $scaffoldInvocation += '-SkipSchemaValidation'
}

$scaffoldOutput = & pwsh @scaffoldInvocation 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($scaffoldOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Failed to scaffold the PrintToSingleFileHtml authoring workspace: $message"
}

$scaffoldReceiptPath = Join-Path $destinationResolved 'custom-operation-scaffold.json'
if (-not (Test-Path -LiteralPath $scaffoldReceiptPath -PathType Leaf)) {
  throw "Expected scaffold receipt was not written to '$scaffoldReceiptPath'."
}
$scaffoldReceipt = Get-Content -LiteralPath $scaffoldReceiptPath -Raw | ConvertFrom-Json -Depth 20

$receiptResolved = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  Join-Path $destinationResolved 'print-to-single-file-html-authoring-workspace.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}
Ensure-Directory -Path (Split-Path -Parent $receiptResolved) | Out-Null

$receipt = [ordered]@{
  schema = 'comparevi/print-to-single-file-html-authoring-workspace@v1'
  generatedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
  status = 'succeeded'
  payloadBundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadBundleResolved
  payloadManifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadManifestPath
  payloadName = [string]$payloadManifest.name
  declaredExecutableState = [string]$payloadManifest.executableState
  sourceKind = $sourceKind
  preferredInstalledOperation = $preferredInstalledOperation
  installedOperationPath = $installedOperationResolved
  destinationPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $destinationResolved
  scaffoldReceiptPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $scaffoldReceiptPath
  labviewPathHint = if ($scaffoldReceipt.PSObject.Properties['labviewPathHint']) { [string]$scaffoldReceipt.labviewPathHint } else { $null }
  notes = @(
    'This workspace is a disposable authoring bootstrap, not a promotable repo-owned payload.',
    'Do not commit installed NI operation files verbatim; author repo-owned runnable replacements under the payload bundle instead.'
  )
}

$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptResolved -Encoding utf8

$receiptSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'print-to-single-file-html-authoring-workspace-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $receiptSchemaPath -DataPath $receiptResolved
}

Write-Host ("PrintToSingleFileHtml authoring workspace: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $destinationResolved))
Write-Host ("PrintToSingleFileHtml authoring receipt: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $receiptResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$receipt
}
