#Requires -Version 7.0

[CmdletBinding()]
param(
  [ValidateSet('scenario-pack', 'corpus-seed')]
  [string]$TemplateId,
  [string]$ContextPath,
  [string]$OutputRoot,
  [string]$ReceiptPath,
  [string]$CookiecutterCacheRoot,
  [switch]$NoInput,
  [switch]$Force,
  [switch]$ListTemplates,
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

function New-DirectoryIfMissing {
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }

  return (Resolve-Path -LiteralPath $Path).Path
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

function Test-Python3Command {
  param(
    [string]$Executable,
    [string[]]$Arguments = @()
  )

  if ([string]::IsNullOrWhiteSpace($Executable)) {
    return $false
  }

  $probeArguments = @($Arguments) + @('-c', 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)')
  & $Executable @probeArguments *> $null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-PythonCommand {
  if (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_PYTHON_EXE)) {
    $override = Get-Command $env:COMPAREVI_PYTHON_EXE -ErrorAction SilentlyContinue
    if ($override -and (Test-Python3Command -Executable $override.Source)) {
      return @{
        Executable = $override.Source
        Arguments  = @()
      }
    }
  }

  $candidates = @()
  if ($IsWindows) {
    $py = Get-Command 'py' -ErrorAction SilentlyContinue
    if ($py) {
      $candidates += @{
        Executable = $py.Source
        Arguments  = @('-3')
      }
    }
  }

  foreach ($name in @('python3', 'python')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      $candidates += @{
        Executable = $cmd.Source
        Arguments  = @()
      }
    }
  }

  foreach ($candidate in $candidates) {
    if (Test-Python3Command -Executable $candidate.Executable -Arguments $candidate.Arguments) {
      return $candidate
    }
  }

  return $null
}

function Invoke-Python {
  param(
    [Parameter(Mandatory)][hashtable]$PythonCommand,
    [Parameter(Mandatory)][string[]]$Arguments
  )

  & $PythonCommand.Executable @($PythonCommand.Arguments) @Arguments
  return $LASTEXITCODE
}

function Ensure-CookiecutterRuntime {
  param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$RuntimeCacheRoot,
    [Parameter(Mandatory)][string]$CookiecutterVersion
  )

  $pythonCommand = Resolve-PythonCommand
  if (-not $pythonCommand) {
    throw 'Python 3 is required to run cookiecutter scaffolds.'
  }

  $resolvedRuntimeCacheRoot = Resolve-AbsolutePath -BasePath $RepoRoot -PathValue $RuntimeCacheRoot
  New-DirectoryIfMissing -Path $resolvedRuntimeCacheRoot | Out-Null

  $runtimeRoot = Join-Path $resolvedRuntimeCacheRoot $CookiecutterVersion
  $venvRoot = Join-Path $runtimeRoot 'venv'
  $venvPython = if ($IsWindows) {
    Join-Path $venvRoot 'Scripts\python.exe'
  } else {
    Join-Path $venvRoot 'bin/python'
  }

  if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    New-DirectoryIfMissing -Path $runtimeRoot | Out-Null
    $createExit = Invoke-Python -PythonCommand $pythonCommand -Arguments @('-m', 'venv', $venvRoot)
    if ($createExit -ne 0) {
      throw "Failed to create cookiecutter runtime venv at '$venvRoot'."
    }
  }

  $showOutput = & $venvPython -m pip show cookiecutter 2>$null
  $cookiecutterInstalled = ($LASTEXITCODE -eq 0)
  $needsInstall = $true
  if ($cookiecutterInstalled) {
    foreach ($line in @($showOutput)) {
      $text = [string]$line
      if ($text -match '^Version:\s*(.+)$') {
        $needsInstall = ($matches[1].Trim() -ne $CookiecutterVersion)
        break
      }
    }
  }

  if ($needsInstall) {
    & $venvPython -m pip install --disable-pip-version-check ("cookiecutter=={0}" -f $CookiecutterVersion) *> $null
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to install cookiecutter $CookiecutterVersion in '$venvRoot'."
    }
  }

  return @{
    PythonExecutable = $venvPython
    RuntimeRoot      = $runtimeRoot
  }
}

$repoRoot = Resolve-RepoRoot
$catalogPath = Join-Path $repoRoot 'tools' 'policy' 'comparevi-cookiecutter-templates.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -Depth 20

if ($ListTemplates) {
  $catalog.templates |
    Select-Object id, description, directory, defaultOutputRoot |
    ConvertTo-Json -Depth 10
  return
}

if ([string]::IsNullOrWhiteSpace($TemplateId)) {
  throw 'TemplateId is required unless -ListTemplates is used.'
}

$template = @($catalog.templates | Where-Object { [string]$_.id -eq $TemplateId } | Select-Object -First 1)
if (-not $template) {
  throw "Template '$TemplateId' was not found in $catalogPath."
}

$scaffoldResultsRoot = Resolve-AbsolutePath -BasePath $repoRoot -PathValue ([string]$catalog.scaffoldResultsRoot)
$resolvedOutputRoot = if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue ([string]$template.defaultOutputRoot)
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $OutputRoot
}
$resolvedContextPath = if ([string]::IsNullOrWhiteSpace($ContextPath)) {
  $null
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ContextPath
}
if ($resolvedContextPath -and -not (Test-Path -LiteralPath $resolvedContextPath -PathType Leaf)) {
  throw "Context JSON was not found at '$resolvedContextPath'."
}

$outputInsideRepo = $resolvedOutputRoot.StartsWith($repoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
  $resolvedOutputRoot.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
$outputAllowedInRepo = $resolvedOutputRoot.StartsWith($scaffoldResultsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
  $resolvedOutputRoot.Equals($scaffoldResultsRoot, [System.StringComparison]::OrdinalIgnoreCase)
if ($outputInsideRepo -and -not $outputAllowedInRepo) {
  throw ("Output root '{0}' is inside the repository but outside '{1}'. This scaffold helper only writes repo-local output under the dedicated results subtree." -f $resolvedOutputRoot, $scaffoldResultsRoot)
}

New-DirectoryIfMissing -Path $resolvedOutputRoot | Out-Null

$runtime = Ensure-CookiecutterRuntime `
  -RepoRoot $repoRoot `
  -RuntimeCacheRoot $(if ([string]::IsNullOrWhiteSpace($CookiecutterCacheRoot)) { [string]$catalog.runtimeCacheRoot } else { $CookiecutterCacheRoot }) `
  -CookiecutterVersion ([string]$catalog.cookiecutterVersion)

$templateRoot = Resolve-AbsolutePath -BasePath $repoRoot -PathValue ([string]$catalog.templateRoot)
$helperScript = Join-Path $repoRoot 'tools' 'cookiecutter' 'run-cookiecutter.py'

$helperArguments = @(
  $helperScript,
  '--template-root', $templateRoot,
  '--directory', ([string]$template.directory),
  '--output-dir', $resolvedOutputRoot,
  '--accept-hooks', 'yes'
)
if ($resolvedContextPath) {
  $helperArguments += @('--context-file', $resolvedContextPath)
}
if ($NoInput.IsPresent) {
  $helperArguments += '--no-input'
}
if ($Force.IsPresent) {
  $helperArguments += '--overwrite-if-exists'
}

$helperOutput = & $runtime.PythonExecutable @helperArguments 2>&1
if ($LASTEXITCODE -ne 0) {
  $message = ($helperOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
  throw "Cookiecutter generation failed for template '$TemplateId': $message"
}

$helperJson = ($helperOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
$helperResult = $helperJson | ConvertFrom-Json -Depth 5
$resolvedDestinationPath = [System.IO.Path]::GetFullPath([string]$helperResult.project_dir)

$resolvedReceiptPath = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
  Join-Path $resolvedDestinationPath 'comparevi-cookiecutter-scaffold.json'
} else {
  Resolve-AbsolutePath -BasePath $repoRoot -PathValue $ReceiptPath
}
New-DirectoryIfMissing -Path (Split-Path -Parent $resolvedReceiptPath) | Out-Null

$replayFilePath = Join-Path $resolvedDestinationPath 'cookiecutter-replay.json'
if (-not (Test-Path -LiteralPath $replayFilePath -PathType Leaf)) {
  throw "Cookiecutter replay file was not written at '$replayFilePath'."
}

$excludedRelativePaths = @()
if ($resolvedReceiptPath.StartsWith($resolvedDestinationPath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
  $excludedRelativePaths += ([System.IO.Path]::GetRelativePath($resolvedDestinationPath, $resolvedReceiptPath) -replace '\\', '/')
}

$generatedFiles = Get-RelativeFileList -RootPath $resolvedDestinationPath -ExcludedRelativePaths $excludedRelativePaths
$receipt = [ordered]@{
  schema              = 'comparevi-cookiecutter-scaffold@v1'
  generatedAt         = (Get-Date).ToUniversalTime().ToString('o')
  status              = 'succeeded'
  templateId          = [string]$template.id
  templateDirectory   = [string]$template.directory
  templateRoot        = Convert-ToRepoRelativePath -RepoRoot $repoRoot -PathValue $templateRoot
  cookiecutterVersion = [string]$catalog.cookiecutterVersion
  pythonExecutable    = $runtime.PythonExecutable
  contextPath         = if ($resolvedContextPath) { $resolvedContextPath } else { $null }
  outputRoot          = $resolvedOutputRoot
  destinationPath     = $resolvedDestinationPath
  destinationPolicy   = if ($outputInsideRepo) { 'repo-results-root' } else { 'outside-repo' }
  receiptPath         = $resolvedReceiptPath
  replayFilePath      = $replayFilePath
  replayFileExists    = (Test-Path -LiteralPath $replayFilePath -PathType Leaf)
  generatedFileCount  = $generatedFiles.Count
  generatedFiles      = @($generatedFiles)
  notes               = @(
    'Generated through the repo-local cookiecutter catalog.',
    'The replay file captures deterministic answers for agent reuse.',
    'Template output is intended for promotion into checked-in contracts after review.'
  )
}

$receiptJson = $receipt | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($resolvedReceiptPath, $receiptJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

if (-not $SkipSchemaValidation) {
  Invoke-SchemaValidation `
    -RepoRoot $repoRoot `
    -SchemaPath (Join-Path $repoRoot 'docs' 'schemas' 'comparevi-cookiecutter-scaffold-v1.schema.json') `
    -DataPath $resolvedReceiptPath
}

$receiptJson
