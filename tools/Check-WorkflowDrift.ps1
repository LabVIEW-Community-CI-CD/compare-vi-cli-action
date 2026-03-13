
[CmdletBinding()]
param(
  [switch]$AutoFix,
  [switch]$FailOnDrift,
  [switch]$Stage,
  [string]$CommitMessage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptRoot
$enclaveScript = Join-Path $repoRoot 'tools/workflows/workflow_enclave.py'
$workflowManifestPath = Join-Path $repoRoot 'tools/workflows/workflow-manifest.json'
$workflowManifest = Get-Content -LiteralPath $workflowManifestPath -Raw | ConvertFrom-Json -Depth 6
$workflowFiles = @($workflowManifest.managedWorkflowFiles)

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
    $override = (Get-Command $env:COMPAREVI_PYTHON_EXE -ErrorAction SilentlyContinue)
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

$pythonCommand = Resolve-PythonCommand
if (-not $pythonCommand) {
  Write-Host '::notice::Python 3 not found; skipping workflow drift check.'
  if ($FailOnDrift) {
    exit 2
  }
  exit 0
}

function Invoke-WorkflowEnclave {
  param([string[]]$Arguments)

  $pythonArguments = @($pythonCommand.Arguments) + @($enclaveScript) + @($Arguments)
  Push-Location $repoRoot
  try {
    & $pythonCommand.Executable @pythonArguments | Out-Host
    return $LASTEXITCODE
  } finally {
    Pop-Location
  }
}

function Invoke-RepoGit {
  param([string[]]$Arguments)

  & git -C $repoRoot @Arguments
}

function Process-Staging {
  param([string[]]$ChangedFiles)

  if (-not ($Stage -or $CommitMessage)) { return }

  if (-not $ChangedFiles -or $ChangedFiles.Count -eq 0) {
    Write-Host '::notice::No workflow drift changes to stage or commit.'
    return
  }

  Invoke-RepoGit -Arguments (@('add') + $ChangedFiles) | Out-Null
  Write-Host ('Staged workflow drift changes: {0}' -f ($ChangedFiles -join ', '))

  if (-not $CommitMessage) { return }

  $staged = Invoke-RepoGit -Arguments @('diff', '--cached', '--name-only') | Where-Object { $_ }
  $extra = @($staged | Where-Object { $ChangedFiles -notcontains $_ })
  if ($extra.Count -gt 0) {
    Write-Host ('::warning::Additional files already staged (skipping auto-commit): {0}' -f ($extra -join ', '))
    return
  }

  try {
    Invoke-RepoGit -Arguments @('commit', '-m', $CommitMessage) | Out-Host
  } catch {
    Write-Host "::notice::Commit failed or nothing to commit: $_"
  }
}

if ($AutoFix) {
  $writeExitCode = Invoke-WorkflowEnclave -Arguments @('--default-scope', '--write')
  if ($writeExitCode -ne 0) {
    exit $writeExitCode
  }
}

$exitCode = Invoke-WorkflowEnclave -Arguments @('--default-scope', '--check')

switch ($exitCode) {
  0 {
    Write-Host 'Workflow drift check passed.'
    $changed = @()
    foreach ($wf in $workflowFiles) {
      if (Invoke-RepoGit -Arguments @('status', '--porcelain', '--', $wf)) { $changed += $wf }
    }
    if ($changed.Count -gt 0) {
      Invoke-RepoGit -Arguments (@('--no-pager', 'diff', '--stat', '--') + $changed) | Out-Host
      Invoke-RepoGit -Arguments (@('--no-pager', 'diff', '--') + $changed) | Out-Host
    }
    Process-Staging -ChangedFiles $changed
    exit 0
  }
  3 {
    $message = 'Workflow drift detected.'
    if ($AutoFix) {
      $message = 'Workflow drift detected after auto-fix.'
    }
    Write-Warning $message
    $changed = @()
    foreach ($wf in $workflowFiles) {
      if (Invoke-RepoGit -Arguments @('status', '--porcelain', '--', $wf)) { $changed += $wf }
    }
    if ($changed.Count -gt 0) {
      Invoke-RepoGit -Arguments (@('--no-pager', 'diff', '--stat', '--') + $changed) | Out-Host
      Invoke-RepoGit -Arguments (@('--no-pager', 'diff', '--') + $changed) | Out-Host
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
