#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$CatalogPath = 'fixtures/headless-corpus/sample-vi-corpus.targets.json',
  [string]$TargetId = 'icon-editor-demo-canaryprobe-print',
  [string]$PayloadBundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$ResultsRoot = 'tests/results/_agent/headless-sample-corpus/print-proof',
  [string]$ReportPath = '',
  [string]$MarkdownPath = '',
  [string]$InspectionScriptPath = '',
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

  $resolved = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $PathValue
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
$catalogResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CatalogPath
if (-not (Test-Path -LiteralPath $catalogResolved -PathType Leaf)) {
  throw "Headless sample VI corpus catalog not found at '$catalogResolved'."
}

$inspectionScriptResolved = if ([string]::IsNullOrWhiteSpace($InspectionScriptPath)) {
  Join-Path $repoRoot 'tools' 'Inspect-OperationPayloadSourceBundle.ps1'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $InspectionScriptPath
}
if (-not (Test-Path -LiteralPath $inspectionScriptResolved -PathType Leaf)) {
  throw "Inspection script not found at '$inspectionScriptResolved'."
}

$catalogSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-targets-v1.schema.json'
$proofSchemaPath = Join-Path $repoRoot 'docs' 'schemas' 'headless-sample-vi-corpus-print-proof-v1.schema.json'
if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $catalogSchemaPath -DataPath $catalogResolved
}

$catalog = Get-Content -LiteralPath $catalogResolved -Raw | ConvertFrom-Json -Depth 32
$target = @($catalog.targets | Where-Object { [string]$_.id -eq $TargetId } | Select-Object -First 1)
if ($target.Count -eq 0) {
  throw "Target '$TargetId' was not found in '$catalogResolved'."
}
$target = $target[0]

$changeKind = [string]$target.source.changeKind
$certificationSurface = [string]$target.renderStrategy.certificationSurface
$operation = [string]$target.renderStrategy.operation
if ($changeKind -notin @('added', 'deleted')) {
  throw "Target '$TargetId' must be an added/deleted print target; observed changeKind '$changeKind'."
}
if ($certificationSurface -ne 'print-single-file' -or $operation -ne 'PrintToSingleFileHtml') {
  throw "Target '$TargetId' is not aligned to the PrintToSingleFileHtml proof surface."
}

$resultsRootResolved = New-DirectoryIfMissing -Path (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ResultsRoot)
$reportResolved = if ([string]::IsNullOrWhiteSpace($ReportPath)) {
  Join-Path $resultsRootResolved ("print-proof-{0}.json" -f $TargetId)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReportPath
}
$markdownResolved = if ([string]::IsNullOrWhiteSpace($MarkdownPath)) {
  Join-Path $resultsRootResolved ("print-proof-{0}.md" -f $TargetId)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $MarkdownPath
}
New-DirectoryIfMissing -Path (Split-Path -Parent $reportResolved) | Out-Null
New-DirectoryIfMissing -Path (Split-Path -Parent $markdownResolved) | Out-Null

$inspectionReportPath = Join-Path $resultsRootResolved ("payload-inspection-{0}.json" -f $TargetId)
$inspectionMarkdownPath = Join-Path $resultsRootResolved ("payload-inspection-{0}.md" -f $TargetId)
$inspectionArgs = @(
  '-NoLogo',
  '-NoProfile',
  '-File', $inspectionScriptResolved,
  '-BundlePath', $PayloadBundlePath,
  '-ReportPath', $inspectionReportPath,
  '-MarkdownPath', $inspectionMarkdownPath
)
if ($SkipSchemaValidation.IsPresent) {
  $inspectionArgs += '-SkipSchemaValidation'
}
$inspectionOutput = & pwsh @inspectionArgs 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($inspectionOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Payload inspection failed: $message"
}

$inspectionReport = Get-Content -LiteralPath $inspectionReportPath -Raw | ConvertFrom-Json -Depth 20
$observedExecutableState = [string]$inspectionReport.observedExecutableState
$declaredExecutableState = [string]$inspectionReport.declaredExecutableState

$finalStatus = if ($observedExecutableState -eq 'source-only') { 'blocked' } else { 'ready' }
$blockingReason = if ($finalStatus -eq 'blocked') { 'payload-source-only' } else { $null }
$notes = New-Object System.Collections.Generic.List[string]
if ($finalStatus -eq 'blocked') {
  $notes.Add('Proof execution was not attempted because the repo-owned payload bundle is still source-only.') | Out-Null
  $notes.Add('This is the intended fail-closed state until runnable repo-owned payload files land.') | Out-Null
} else {
  $notes.Add('Payload inspection no longer reports source-only; the Linux execution runner can be wired next.') | Out-Null
}

$report = [ordered]@{
  schema = 'vi-headless/sample-print-proof@v1'
  generatedAt = (Get-Date).ToUniversalTime().ToString('o')
  catalogPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $catalogResolved
  targetId = $TargetId
  targetPath = [string]$target.source.targetPath
  changeKind = $changeKind
  certificationSurface = $certificationSurface
  operation = $operation
  payloadBundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue (Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadBundlePath)
  payloadInspectionPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionReportPath
  payloadInspectionMarkdownPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $inspectionMarkdownPath
  payloadDeclaredExecutableState = $declaredExecutableState
  payloadObservedExecutableState = $observedExecutableState
  executionAttempted = $false
  finalStatus = $finalStatus
  blockingReason = $blockingReason
  notes = @($notes.ToArray())
}

$report | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reportResolved -Encoding utf8

$markdownLines = @(
  '# Headless Sample VI Corpus Print Proof',
  '',
  ('- Target: `{0}`' -f $TargetId),
  ('- Target Path: `{0}`' -f $report.targetPath),
  ('- Final Status: `{0}`' -f $finalStatus),
  ('- Payload Declared Executable State: `{0}`' -f $declaredExecutableState),
  ('- Payload Observed Executable State: `{0}`' -f $observedExecutableState),
  ('- Execution Attempted: `{0}`' -f $report.executionAttempted.ToString().ToLowerInvariant()),
  ''
)
if ($blockingReason) {
  $markdownLines += ('- Blocking Reason: `{0}`' -f $blockingReason)
  $markdownLines += ''
}
$markdownLines += '## Notes'
$markdownLines += ''
foreach ($note in @($report.notes)) {
  $markdownLines += ('- {0}' -f [string]$note)
}
$markdownLines += ''
$markdownLines += ('- Payload Inspection Report: `{0}`' -f $report.payloadInspectionPath)
$markdownLines += ('- Payload Inspection Summary: `{0}`' -f $report.payloadInspectionMarkdownPath)

$markdownLines -join [Environment]::NewLine | Set-Content -LiteralPath $markdownResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $proofSchemaPath -DataPath $reportResolved
}

Write-Output ("Headless sample print proof report: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $reportResolved))
Write-Output ("Headless sample print proof summary: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $markdownResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$report
}
