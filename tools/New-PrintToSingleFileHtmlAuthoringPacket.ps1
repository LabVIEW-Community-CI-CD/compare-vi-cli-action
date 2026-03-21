#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$PayloadBundlePath = 'fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml',
  [string]$DestinationPath = '',
  [string]$ReceiptPath = '',
  [string]$AuthoringWorkspaceScriptPath = '',
  [string]$AuthoringWorkspaceReceiptPath = '',
  [string]$LabVIEWPath = '',
  [string]$OperationsProjectPath = '',
  [string]$ToolkitOperationsProjectPath = '',
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

function Get-DefaultOperationsProjectPath {
  return 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\Operations.lvproj'
}

function Get-DefaultToolkitOperationsProjectPath {
  return 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\Operations\Toolkit-Operations.lvproj'
}

function Get-DefaultLabVIEWPath {
  return 'C:\Program Files (x86)\National Instruments\LabVIEW 2026\LabVIEW.exe'
}

$repoRoot = Resolve-RepoRoot
$authoringPacketRoot = Join-Path $repoRoot 'tests' 'results' '_agent' 'custom-operation-scaffolds'
if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
  $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
  $DestinationPath = Join-Path $authoringPacketRoot ("PrintToSingleFileHtml-native-authoring-{0}" -f $timestamp)
}
$destinationResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $DestinationPath
Ensure-Directory -Path (Split-Path -Parent $destinationResolved) | Out-Null

$authoringWorkspaceScriptResolved = if ([string]::IsNullOrWhiteSpace($AuthoringWorkspaceScriptPath)) {
  Join-Path $repoRoot 'tools' 'New-PrintToSingleFileHtmlAuthoringWorkspace.ps1'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $AuthoringWorkspaceScriptPath
}
if (-not (Test-Path -LiteralPath $authoringWorkspaceScriptResolved -PathType Leaf)) {
  throw "Authoring workspace script was not found at '$authoringWorkspaceScriptResolved'."
}

$payloadBundleResolved = Resolve-AbsolutePath -BasePath $repoRoot -PathValue $PayloadBundlePath
$payloadManifestPath = Join-Path $payloadBundleResolved 'payload-provenance.json'
if (-not (Test-Path -LiteralPath $payloadManifestPath -PathType Leaf)) {
  throw "Payload manifest was not found at '$payloadManifestPath'."
}

$workspaceReceiptResolved = if ([string]::IsNullOrWhiteSpace($AuthoringWorkspaceReceiptPath)) {
  Join-Path $destinationResolved 'print-to-single-file-html-authoring-workspace.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $AuthoringWorkspaceReceiptPath
}

$authoringInvocation = @(
  '-NoLogo',
  '-NoProfile',
  '-File', $authoringWorkspaceScriptResolved,
  '-PayloadBundlePath', $payloadBundleResolved,
  '-DestinationPath', $destinationResolved,
  '-ReceiptPath', $workspaceReceiptResolved
)
if ($Force.IsPresent) {
  $authoringInvocation += '-Force'
}
if ($SkipSchemaValidation.IsPresent) {
  $authoringInvocation += '-SkipSchemaValidation'
}

$authoringOutput = & pwsh @authoringInvocation 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($authoringOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Failed to build the PrintToSingleFileHtml authoring workspace: $message"
}

if (-not (Test-Path -LiteralPath $workspaceReceiptResolved -PathType Leaf)) {
  throw "Expected authoring workspace receipt was not written to '$workspaceReceiptResolved'."
}

$workspaceReceipt = Get-Content -LiteralPath $workspaceReceiptResolved -Raw | ConvertFrom-Json -Depth 20
$payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json -Depth 20

$labviewResolved = if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
  Get-DefaultLabVIEWPath
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $LabVIEWPath
}
$operationsProjectResolved = if ([string]::IsNullOrWhiteSpace($OperationsProjectPath)) {
  Get-DefaultOperationsProjectPath
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $OperationsProjectPath
}
$toolkitOperationsProjectResolved = if ([string]::IsNullOrWhiteSpace($ToolkitOperationsProjectPath)) {
  Get-DefaultToolkitOperationsProjectPath
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ToolkitOperationsProjectPath
}

foreach ($requiredPath in @($labviewResolved, $operationsProjectResolved, $toolkitOperationsProjectResolved)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Required native authoring dependency was not found at '$requiredPath'."
  }
}

$checklistResolved = Join-Path $destinationResolved 'AUTHORING_CHECKLIST.md'
$launchScriptResolved = Join-Path $destinationResolved 'Open-PrintToSingleFileHtmlAuthoringWorkspace.ps1'
$receiptResolved = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  Join-Path $destinationResolved 'print-to-single-file-html-authoring-packet.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}
Ensure-Directory -Path (Split-Path -Parent $receiptResolved) | Out-Null

$checklistContent = (@(
  '<!-- markdownlint-disable-next-line MD041 -->',
  '# PrintToSingleFileHtml Native Authoring Checklist',
  '',
  "This packet exists because NI's supported custom-operation workflow is native",
  'LabVIEW authoring, not PowerShell synthesis of runnable .vi files.',
  '',
  'Installed authoring surfaces on this host:',
  '',
  ('- LabVIEW: {0}' -f $labviewResolved),
  ('- Operations project: {0}' -f $operationsProjectResolved),
  ('- Toolkit operations project: {0}' -f $toolkitOperationsProjectResolved),
  ('- Disposable workspace: {0}' -f $destinationResolved),
  '',
  '## Recommended flow',
  '',
  '1. Open Operations.lvproj in LabVIEW 2026 x86.',
  '2. Create a child class named PrintToSingleFileHtml that inherits from',
  '   CoreOperation.lvclass.',
  '3. Override GetHelp.vi and RunOperation.vi.',
  '4. Author repo-owned replacements in this disposable workspace. Do not commit',
  '   installed NI files verbatim.',
  '5. Once the authored files are runnable, copy only the repo-owned payload files',
  '   into fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml/.',
  '6. Rerun tools/Inspect-OperationPayloadSourceBundle.ps1 so the bundle no',
  '   longer reports source-only.',
  '',
  'Reference:',
  '',
  '- https://www.ni.com/docs/en-AS/bundle/labview/page/creating-custom-command-line-operations.html'
)) -join [Environment]::NewLine
Set-Content -LiteralPath $checklistResolved -Value $checklistContent -Encoding utf8

$launchScriptContent = @"
#Requires -Version 5.1

[CmdletBinding()]
param(
  [switch]`$OpenToolkitProject
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$labviewPath = '$($labviewResolved -replace "'", "''")'
`$operationsProjectPath = '$($operationsProjectResolved -replace "'", "''")'
`$toolkitOperationsProjectPath = '$($toolkitOperationsProjectResolved -replace "'", "''")'
`$workspacePath = '$($destinationResolved -replace "'", "''")'

`$projectPath = if (`$OpenToolkitProject.IsPresent) { `$toolkitOperationsProjectPath } else { `$operationsProjectPath }

foreach (`$requiredPath in @(`$labviewPath, `$projectPath)) {
  if (-not (Test-Path -LiteralPath `$requiredPath -PathType Leaf)) {
    throw "Required authoring dependency was not found at '`$requiredPath'."
  }
}

if (-not (Test-Path -LiteralPath `$workspacePath -PathType Container)) {
  throw "Workspace path was not found at '`$workspacePath'."
}

Write-Host ('LabVIEW: {0}' -f `$labviewPath)
Write-Host ('Project: {0}' -f `$projectPath)
Write-Host ('Workspace: {0}' -f `$workspacePath)

Start-Process -FilePath `$labviewPath -ArgumentList @(`$projectPath) | Out-Null
Start-Process -FilePath 'explorer.exe' -ArgumentList @(`$workspacePath) | Out-Null
"@
Set-Content -LiteralPath $launchScriptResolved -Value $launchScriptContent -Encoding utf8

$receipt = [ordered]@{
  schema = 'comparevi/print-to-single-file-html-authoring-packet@v1'
  generatedAt = ([DateTimeOffset]::UtcNow.ToString('o'))
  status = 'succeeded'
  payloadBundlePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadBundleResolved
  payloadManifestPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $payloadManifestPath
  payloadName = [string]$payloadManifest.name
  declaredExecutableState = [string]$payloadManifest.executableState
  authoringWorkspacePath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $destinationResolved
  authoringWorkspaceReceiptPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $workspaceReceiptResolved
  labviewPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $labviewResolved
  operationsProjectPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $operationsProjectResolved
  toolkitOperationsProjectPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $toolkitOperationsProjectResolved
  launchScriptPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $launchScriptResolved
  checklistPath = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $checklistResolved
  notes = @(
    'This packet turns the remaining gap into an explicit native LabVIEW authoring handoff.',
    'The generated launch script is a convenience wrapper and does not make the payload repo-owned on its own.',
    'Do not commit installed NI files verbatim; only commit newly authored repo-owned payload files.'
  )
}

$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptResolved -Encoding utf8

if (-not $SkipSchemaValidation.IsPresent) {
  $schemaPath = Join-Path $repoRoot 'docs' 'schemas' 'print-to-single-file-html-authoring-packet-v1.schema.json'
  Invoke-SchemaValidation -RepoRoot $repoRoot -SchemaPath $schemaPath -DataPath $receiptResolved
}

Write-Host ("PrintToSingleFileHtml native authoring packet: {0}" -f (Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $receiptResolved))

if ($PassThru.IsPresent) {
  [pscustomobject]$receipt
}
