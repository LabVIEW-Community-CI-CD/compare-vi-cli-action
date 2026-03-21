#Requires -Version 7.0

[CmdletBinding()]
param(
  [ValidateSet('linux', 'windows')]
  [string]$Platform = $(if ($IsWindows) { 'windows' } else { 'linux' }),
  [string]$ProofRoot,
  [string]$CookiecutterCacheRoot,
  [string]$ScaffoldOutputRoot,
  [string]$ReceiptPath,
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
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-SchemaValidation {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string]$DataPath
  )

  $runner = Join-Path $RepoRoot 'tools' 'npm' 'run-script.mjs'
  $output = & node $runner 'schema:validate' '--' '--schema' $SchemaPath '--data' $DataPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    $message = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Schema validation failed for '$DataPath': $message"
  }
}

function Invoke-CookiecutterScaffoldRun {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$TemplateId,
    [Parameter(Mandatory)][string]$ContextPath,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$CookiecutterCacheRoot,
    [Parameter(Mandatory)][string]$ReceiptPath
  )

  $scriptPath = Join-Path $RepoRoot 'tools' 'New-CompareVICookiecutterScaffold.ps1'
  $raw = & $scriptPath `
    -TemplateId $TemplateId `
    -ContextPath $ContextPath `
    -OutputRoot $OutputRoot `
    -CookiecutterCacheRoot $CookiecutterCacheRoot `
    -ReceiptPath $ReceiptPath `
    -NoInput 2>&1

  if ($LASTEXITCODE -ne 0) {
    $message = ($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    throw "Cookiecutter scaffold run failed for template '$TemplateId': $message"
  }

  $json = ($raw | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
  return ($json | ConvertFrom-Json -Depth 20)
}

$repoRoot = Resolve-RepoRoot
$resolvedProofRoot = if ([string]::IsNullOrWhiteSpace($ProofRoot)) {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue (Join-Path 'tests/results/_agent/cookiecutter-bootstrap' $Platform)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ProofRoot
}
$resolvedRuntimeCacheRoot = if ([string]::IsNullOrWhiteSpace($CookiecutterCacheRoot)) {
  Join-Path $resolvedProofRoot 'runtime'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $CookiecutterCacheRoot
}
$resolvedScaffoldOutputRoot = if ([string]::IsNullOrWhiteSpace($ScaffoldOutputRoot)) {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue (Join-Path 'tests/results/_agent/cookiecutter-scaffolds/bootstrap-proof' $Platform)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ScaffoldOutputRoot
}
$resolvedReceiptPath = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  Join-Path $resolvedProofRoot 'comparevi-cookiecutter-bootstrap-proof.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}

New-DirectoryIfMissing -Path $resolvedProofRoot | Out-Null
New-DirectoryIfMissing -Path $resolvedRuntimeCacheRoot | Out-Null
New-DirectoryIfMissing -Path $resolvedScaffoldOutputRoot | Out-Null
New-DirectoryIfMissing -Path (Split-Path -Parent $resolvedReceiptPath) | Out-Null

$fixturesRoot = Join-Path $repoRoot 'tests' 'fixtures' 'cookiecutter'
$scenarioContextPath = Join-Path $fixturesRoot 'scenario-pack.context.json'
$corpusContextPath = Join-Path $fixturesRoot 'corpus-seed.context.json'

$scenarioReceipt = Invoke-CookiecutterScaffoldRun `
  -RepoRoot $repoRoot `
  -TemplateId 'scenario-pack' `
  -ContextPath $scenarioContextPath `
  -OutputRoot (Join-Path $resolvedScaffoldOutputRoot 'scenario-pack') `
  -CookiecutterCacheRoot $resolvedRuntimeCacheRoot `
  -ReceiptPath (Join-Path $resolvedProofRoot 'scenario-pack-receipt.json')

$corpusReceipt = Invoke-CookiecutterScaffoldRun `
  -RepoRoot $repoRoot `
  -TemplateId 'corpus-seed' `
  -ContextPath $corpusContextPath `
  -OutputRoot (Join-Path $resolvedScaffoldOutputRoot 'corpus-seed') `
  -CookiecutterCacheRoot $resolvedRuntimeCacheRoot `
  -ReceiptPath (Join-Path $resolvedProofRoot 'corpus-seed-receipt.json')

if ([string]$scenarioReceipt.cookiecutterVersion -ne [string]$corpusReceipt.cookiecutterVersion) {
  throw 'Cookiecutter proof runs resolved different cookiecutter versions.'
}

if ([string]$scenarioReceipt.pythonExecutable -ne [string]$corpusReceipt.pythonExecutable) {
  throw 'Cookiecutter proof runs resolved different Python executables.'
}

$pythonVersionOutput = & $scenarioReceipt.pythonExecutable --version 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "Failed to probe Python version through '$($scenarioReceipt.pythonExecutable)'."
}

$proof = [ordered]@{
  schema             = 'comparevi-cookiecutter-bootstrap-proof@v1'
  generatedAt        = (Get-Date).ToUniversalTime().ToString('o')
  status             = 'succeeded'
  platform           = $Platform
  proofRoot          = $resolvedProofRoot
  runtimeCacheRoot   = $resolvedRuntimeCacheRoot
  scaffoldOutputRoot = $resolvedScaffoldOutputRoot
  cookiecutterVersion = [string]$scenarioReceipt.cookiecutterVersion
  pythonExecutable   = [string]$scenarioReceipt.pythonExecutable
  pythonVersion      = (($pythonVersionOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
  templateRuns       = @(
    [ordered]@{
      templateId         = 'scenario-pack'
      receiptPath        = [string]$scenarioReceipt.receiptPath
      destinationPath    = [string]$scenarioReceipt.destinationPath
      generatedFileCount = [int]$scenarioReceipt.generatedFileCount
    }
    [ordered]@{
      templateId         = 'corpus-seed'
      receiptPath        = [string]$corpusReceipt.receiptPath
      destinationPath    = [string]$corpusReceipt.destinationPath
      generatedFileCount = [int]$corpusReceipt.generatedFileCount
    }
  )
  notes = @(
    'Exercises the repo-pinned cookiecutter runtime through the shared scaffold wrapper.',
    'Intended for hosted Linux and hosted Windows CI bootstrap validation.',
    'Uploads both proof receipts and generated scaffold outputs for review.'
  )
}

$proofJson = $proof | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($resolvedReceiptPath, $proofJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

if (-not $SkipSchemaValidation) {
  Invoke-SchemaValidation `
    -RepoRoot $repoRoot `
    -SchemaPath (Join-Path $repoRoot 'docs' 'schemas' 'comparevi-cookiecutter-bootstrap-proof-v1.schema.json') `
    -DataPath $resolvedReceiptPath
}

$proofJson
