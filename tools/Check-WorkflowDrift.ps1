
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

function Resolve-PythonExe {
  $candidates = @('python','py')
  foreach ($name in $candidates) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

$py = Resolve-PythonExe
if (-not $py) {
  Write-Host '::notice::Python not found; skipping workflow drift check.'
  exit 0
}

function Invoke-WorkflowEnclave {
  param([string[]]$Arguments)

  & $py $enclaveScript @Arguments | Out-Host
  return $LASTEXITCODE
}

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
    $message = 'Workflow drift detected.'
    if ($AutoFix) {
      $message = 'Workflow drift detected after auto-fix.'
    }
    Write-Warning $message
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
