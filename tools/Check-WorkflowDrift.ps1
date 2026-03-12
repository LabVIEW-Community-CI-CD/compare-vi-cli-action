
[CmdletBinding()]
param(
  [switch]$AutoFix,
  [switch]$Stage,
  [string]$CommitMessage,
  [switch]$FailOnDrift
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workflowFiles = @(
  '.github/workflows/pester-selfhosted.yml',
  '.github/workflows/fixture-drift.yml',
  '.github/workflows/ci-orchestrated.yml',
  '.github/workflows/pester-integration-on-label.yml',
  '.github/workflows/smoke.yml',
  '.github/workflows/compare-artifacts.yml'
)

function Resolve-PythonExe {
  $candidates = @('python','py')
  foreach ($name in $candidates) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Get-WorkflowDriftStateRoot {
  if ($env:RUNNER_TEMP -and $env:RUNNER_TEMP.Trim()) {
    return (Join-Path $env:RUNNER_TEMP 'comparevi-workflow-drift')
  }

  return (Join-Path (Join-Path (Get-Location) '.tmp') 'workflow-drift')
}

function Get-VenvPythonPath {
  param([Parameter(Mandatory)][string]$VenvPath)

  if ($IsWindows -or $env:OS -eq 'Windows_NT') {
    return (Join-Path $VenvPath 'Scripts\python.exe')
  }

  return (Join-Path $VenvPath 'bin/python')
}

function Test-RuamelYamlImport {
  param([Parameter(Mandatory)][string]$PythonExe)

  $null = & $PythonExe -c 'import ruamel.yaml' 2>&1
  return ($LASTEXITCODE -eq 0)
}

function Ensure-WorkflowUpdaterPython {
  param([Parameter(Mandatory)][string]$BasePythonExe)

  if (Test-RuamelYamlImport -PythonExe $BasePythonExe) {
    return $BasePythonExe
  }

  $stateRoot = Get-WorkflowDriftStateRoot
  $venvPath = Join-Path $stateRoot 'venv'
  $venvPython = Get-VenvPythonPath -VenvPath $venvPath

  if (-not (Test-Path -LiteralPath $venvPython)) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    & $BasePythonExe -m venv $venvPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython)) {
      throw "Failed to create workflow drift virtualenv at $venvPath"
    }
  }

  if (-not (Test-RuamelYamlImport -PythonExe $venvPython)) {
    $attempt = 0
    $maxAttempts = 4
    while ($attempt -lt $maxAttempts) {
      $attempt++
      & $venvPython -m pip install --disable-pip-version-check ruamel.yaml | Out-Host
      if ($LASTEXITCODE -eq 0 -and (Test-RuamelYamlImport -PythonExe $venvPython)) {
        break
      }

      if ($attempt -ge $maxAttempts) {
        throw "Failed to install ruamel.yaml for workflow drift after $attempt attempts"
      }

      $delaySeconds = [Math]::Min(20, [Math]::Pow(2, $attempt))
      Start-Sleep -Seconds $delaySeconds
    }
  }

  return $venvPython
}

$py = Resolve-PythonExe
if (-not $py) {
  Write-Host '::notice::Python not found; skipping workflow drift check.'
  exit 0
}

$workflowPython = Ensure-WorkflowUpdaterPython -BasePythonExe $py

function Process-Staging {
  param([string[]]$ChangedFiles)

  if (-not ($Stage -or $CommitMessage)) { return }

  if (-not $ChangedFiles -or $ChangedFiles.Count -eq 0) {
    Write-Host '::notice::No workflow drift changes to stage or commit.'
    return
  }

  git add $ChangedFiles | Out-Null
  Write-Host ('Staged workflow drift changes: {0}' -f ($ChangedFiles -join ', '))

  if (-not $CommitMessage) { return }

  $staged = git diff --cached --name-only | Where-Object { $_ }
  $extra = @($staged | Where-Object { $ChangedFiles -notcontains $_ })
  if ($extra.Count -gt 0) {
    Write-Host ('::warning::Additional files already staged (skipping auto-commit): {0}' -f ($extra -join ', '))
    return
  }

  try {
    git commit -m $CommitMessage | Out-Host
  } catch {
    Write-Host "::notice::Commit failed or nothing to commit: $_"
  }
}

if ($AutoFix) {
  & $workflowPython tools/workflows/update_workflows.py --write @workflowFiles | Out-Host
}

& $workflowPython tools/workflows/update_workflows.py --check @workflowFiles | Out-Host
$exitCode = $LASTEXITCODE

switch ($exitCode) {
  0 {
    Write-Host 'Workflow drift check passed.'
    $changed = @()
    foreach ($wf in $workflowFiles) {
      if (git status --porcelain $wf) { $changed += $wf }
    }
    if ($changed.Count -gt 0) {
      git --no-pager diff --stat @changed | Out-Host
      git --no-pager diff @changed | Out-Host
    }
    Process-Staging -ChangedFiles $changed
    exit 0
  }
  3 {
    if ($AutoFix) {
      Write-Warning 'Workflow drift detected (auto-fix applied).'
    } else {
      Write-Warning 'Workflow drift detected.'
    }
    $changed = @()
    foreach ($wf in $workflowFiles) {
      if (git status --porcelain $wf) { $changed += $wf }
    }
    if ($changed.Count -gt 0) {
      git --no-pager diff --stat @changed | Out-Host
      git --no-pager diff @changed | Out-Host
    }
    Process-Staging -ChangedFiles $changed
    if ($FailOnDrift) {
      exit 3
    }

    exit 0
  }
  default {
    exit $exitCode
  }
}
