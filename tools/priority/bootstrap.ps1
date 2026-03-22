#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$VerboseHooks,
  [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapDecisionModule = Join-Path (Split-Path -Parent $PSCommandPath) 'bootstrap-decision.psm1'
Import-Module $bootstrapDecisionModule -Force

function Invoke-Npm {
  param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string]$WrapperRepoRoot = (Resolve-Path '.').Path,
    [string]$WorkingDirectory = (Resolve-Path '.').Path,
    [switch]$AllowFailure
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot launch npm wrapper.'
  }
  $resolvedWrapperRepoRoot = (Resolve-Path -LiteralPath $WrapperRepoRoot).Path
  $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
  $wrapperPath = Join-Path $resolvedWrapperRepoRoot 'tools/npm/run-script.mjs'
  if (-not (Test-Path -LiteralPath $wrapperPath -PathType Leaf)) {
    throw "npm wrapper not found at $wrapperPath"
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($wrapperPath)
  $psi.ArgumentList.Add($Script)
  $psi.WorkingDirectory = $resolvedWorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }

  if ($proc.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "node tools/npm/run-script.mjs $Script exited with code $($proc.ExitCode)"
  }
}

function Ensure-RepoNodeDependencies {
  param(
    [string]$RepoRoot = (Resolve-Path '.').Path,
    [string[]]$RequiredPackages = @()
  )

  if (-not @($RequiredPackages).Count) {
    return
  }

  $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  $missingPackages = New-Object System.Collections.Generic.List[string]
  foreach ($packageName in @($RequiredPackages | Select-Object -Unique)) {
    $segments = [string]$packageName -split '/'
    $packagePath = Join-Path $resolvedRepoRoot 'node_modules'
    foreach ($segment in $segments) {
      $packagePath = Join-Path $packagePath $segment
    }
    if (-not (Test-Path -LiteralPath $packagePath)) {
      $missingPackages.Add([string]$packageName)
    }
  }

  if ($missingPackages.Count -eq 0) {
    return
  }

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot install npm dependencies.'
  }

  $installerPath = Join-Path $resolvedRepoRoot 'tools/npm/cli.mjs'
  if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "npm cli wrapper not found at $installerPath"
  }

  Write-Host ("[bootstrap] Installing missing npm dependencies in helper checkout '{0}': {1}" -f $resolvedRepoRoot, ($missingPackages -join ', '))

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($installerPath)
  $psi.ArgumentList.Add('install')
  $psi.WorkingDirectory = $resolvedRepoRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }

  if ($proc.ExitCode -ne 0) {
    throw "node tools/npm/cli.mjs install exited with code $($proc.ExitCode)"
  }
}

function Invoke-NodeScriptFromRepoRoot {
  param(
    [Parameter(Mandatory=$true)][string]$ScriptRelativePath,
    [string[]]$Arguments = @(),
    [string[]]$RequiredPackages = @(),
    [string]$RepoRoot = (Resolve-Path '.').Path,
    [string]$WorkingDirectory = (Resolve-Path '.').Path,
    [switch]$AllowFailure
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot launch node script.'
  }

  $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
  Ensure-RepoNodeDependencies -RepoRoot $resolvedRepoRoot -RequiredPackages $RequiredPackages
  $scriptPath = Join-Path $resolvedRepoRoot $ScriptRelativePath
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "node script not found at $scriptPath"
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($scriptPath)
  foreach ($arg in @($Arguments)) {
    $psi.ArgumentList.Add([string]$arg)
  }
  $psi.WorkingDirectory = $resolvedWorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }

  if ($proc.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "node $ScriptRelativePath $($Arguments -join ' ') exited with code $($proc.ExitCode)"
  }
}

function Test-NodeScriptContainsToken {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$Token
  )

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    return $false
  }

  try {
    $content = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop
    return $content -match [regex]::Escape($Token)
  } catch {
    return $false
  }
}

function Invoke-WorkspaceHealthGate {
  param(
    [ValidateSet('ignore','optional','required')][string]$LeaseMode = 'optional',
    [Parameter(Mandatory=$true)][string]$ReportName
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    throw 'node not found; cannot run workspace health gate.'
  }

  $scriptPath = Join-Path (Resolve-Path '.').Path 'tools/priority/check-workspace-health.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "workspace health gate script not found at $scriptPath"
  }

  $reportPath = Join-Path (Resolve-Path '.').Path ("tests/results/_agent/health/{0}" -f $ReportName)
  $arguments = @(
    $scriptPath,
    '--repo-root', (Resolve-Path '.').Path,
    '--report', $reportPath,
    '--lease-mode', $LeaseMode
  )
  if ($LeaseMode -eq 'required' -and -not [string]::IsNullOrWhiteSpace($env:AGENT_WRITER_LEASE_OWNER)) {
    $arguments += @('--expected-owner', $env:AGENT_WRITER_LEASE_OWNER)
  }
  if ($LeaseMode -eq 'required' -and -not [string]::IsNullOrWhiteSpace($env:AGENT_WRITER_LEASE_ID)) {
    $arguments += @('--expected-lease-id', $env:AGENT_WRITER_LEASE_ID)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  foreach ($arg in $arguments) { $psi.ArgumentList.Add([string]$arg) }
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }

  if ($proc.ExitCode -ne 0) {
    throw "Workspace health gate failed (lease-mode=$LeaseMode). See $reportPath"
  }
}

function Invoke-SemVerCheck {
  param(
    [string]$RepoRoot = (Resolve-Path '.').Path,
    [string]$WorkingDirectory = (Resolve-Path '.').Path
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    Write-Warning 'node not found; skipping semver check.'
    return $null
  }

  $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
  $scriptPath = Join-Path $resolvedRepoRoot 'tools/priority/validate-semver.mjs'
  $fallbackScriptPath = Join-Path $resolvedWorkingDirectory 'tools/priority/validate-semver.mjs'
  $selectedScriptPath = $null
  if (Test-Path -LiteralPath $scriptPath -PathType Leaf) {
    $selectedScriptPath = $scriptPath
  } elseif (Test-Path -LiteralPath $fallbackScriptPath -PathType Leaf) {
    $selectedScriptPath = $fallbackScriptPath
    Write-Host '[bootstrap] SemVer helper checkout script is unavailable; using caller checkout script.'
  } else {
    Write-Warning "SemVer script not found at $scriptPath or $fallbackScriptPath"
    return $null
  }

  $selectedScriptSupportsRepoRoot = Test-SemVerRepoRootOverrideSupport `
    -ScriptPath $selectedScriptPath `
    -WorkingDirectory $resolvedWorkingDirectory `
    -NodeCommand $nodeCmd.Source
  if (
    $selectedScriptPath -eq $scriptPath `
    -and -not $selectedScriptSupportsRepoRoot `
    -and $fallbackScriptPath -ne $scriptPath `
    -and (Test-Path -LiteralPath $fallbackScriptPath -PathType Leaf)
  ) {
    $selectedScriptPath = $fallbackScriptPath
    $selectedScriptSupportsRepoRoot = Test-SemVerRepoRootOverrideSupport `
      -ScriptPath $selectedScriptPath `
      -WorkingDirectory $resolvedWorkingDirectory `
      -NodeCommand $nodeCmd.Source
    Write-Host '[bootstrap] SemVer helper checkout lacks explicit repo-root support; using caller checkout script until develop helper catches up.'
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  $psi.ArgumentList.Add($selectedScriptPath)
  if ($selectedScriptSupportsRepoRoot) {
    $psi.ArgumentList.Add('--repo-root')
    $psi.ArgumentList.Add($resolvedWorkingDirectory)
  }
  $psi.WorkingDirectory = $resolvedWorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stderr) { Write-Warning $stderr.TrimEnd() }

  $json = $null
  if ($stdout) { $json = $stdout.Trim() }

  $result = $null
  if ($json) {
    try { $result = $json | ConvertFrom-Json -ErrorAction Stop } catch { Write-Warning 'Failed to parse semver JSON output.' }
  }

  return [pscustomobject]@{
    ExitCode = $proc.ExitCode
    Raw = $json
    Result = $result
  }
}

function Test-SemVerRepoRootOverrideSupport {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,
    [string]$WorkingDirectory = (Resolve-Path '.').Path,
    [string]$NodeCommand = (Get-Command node -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
  )

  if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf) -or -not $NodeCommand) {
    return $false
  }

  try {
    $resolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
    $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NodeCommand
    foreach ($arg in @($resolvedScriptPath, '--version', '0.0.0', '--repo-root', $resolvedWorkingDirectory)) {
      $psi.ArgumentList.Add([string]$arg)
    }
    $psi.WorkingDirectory = $resolvedWorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if (-not $stdout) {
      return $false
    }

    $probe = $stdout | ConvertFrom-Json -ErrorAction Stop
    return (
      $null -ne $probe.repoRoot `
      -and ((Resolve-Path -LiteralPath $probe.repoRoot).Path -eq $resolvedWorkingDirectory)
    )
  } catch {
    return $false
  }
}

function Invoke-SafeGitReliabilitySummary {
  param(
    [string]$RepoRoot = (Resolve-Path '.').Path,
    [string]$WorkingDirectory = (Resolve-Path '.').Path
  )

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    Write-Warning 'node not found; skipping safe-git reliability summary.'
    return
  }

  $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
  $resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
  $scriptPath = Join-Path $resolvedRepoRoot 'tools/priority/summarize-safe-git-telemetry.mjs'
  $fallbackScriptPath = Join-Path $resolvedWorkingDirectory 'tools/priority/summarize-safe-git-telemetry.mjs'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    if (Test-Path -LiteralPath $fallbackScriptPath -PathType Leaf) {
      $scriptPath = $fallbackScriptPath
      Write-Host '[bootstrap] Safe-git helper checkout script is unavailable; using caller checkout script.'
    } else {
      Write-Warning "safe-git reliability summary script not found at $scriptPath or $fallbackScriptPath"
      return
    }
  }

  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    Write-Warning "safe-git reliability summary script not found at $scriptPath"
    return
  }

  $inputPath = Join-Path $resolvedWorkingDirectory 'tests/results/_agent/reliability/safe-git-events.jsonl'
  $outputPath = Join-Path $resolvedWorkingDirectory 'tests/results/_agent/reliability/safe-git-trend-summary.json'
  $arguments = @(
    $scriptPath,
    '--input', $inputPath,
    '--output', $outputPath
  )
  if ($env:GITHUB_STEP_SUMMARY) {
    $arguments += @('--step-summary', $env:GITHUB_STEP_SUMMARY)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  foreach ($arg in $arguments) { $psi.ArgumentList.Add([string]$arg) }
  $psi.WorkingDirectory = $resolvedWorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stdout) { Write-Host $stdout.TrimEnd() }
  if ($stderr) { Write-Warning $stderr.TrimEnd() }
  if ($proc.ExitCode -ne 0) {
    throw "safe-git reliability summary failed (exit=$($proc.ExitCode))"
  }
}

function Invoke-AgentWriterLeaseAcquire {
  if ($env:AGENT_WRITER_LEASE_ENABLED -eq '0') {
    Write-Host '[bootstrap] Agent writer lease disabled (AGENT_WRITER_LEASE_ENABLED=0).'
    return $null
  }

  if ($env:GITHUB_ACTIONS -eq 'true' -and $env:AGENT_WRITER_LEASE_ALLOW_CI -ne '1') {
    Write-Host '[bootstrap] Skipping agent writer lease in GitHub Actions context.'
    return $null
  }

  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $nodeCmd) {
    Write-Warning 'node not found; skipping agent writer lease.'
    return $null
  }

  $leaseScript = Join-Path (Resolve-Path '.').Path 'tools/priority/agent-writer-lease.mjs'
  if (-not (Test-Path -LiteralPath $leaseScript -PathType Leaf)) {
    Write-Warning "Agent writer lease script not found at $leaseScript"
    return $null
  }

  $owner = $env:AGENT_WRITER_LEASE_OWNER
  if ([string]::IsNullOrWhiteSpace($owner)) {
    $user = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ACTOR)) { $env:GITHUB_ACTOR } elseif (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) { $env:USERNAME } elseif (-not [string]::IsNullOrWhiteSpace($env:USER)) { $env:USER } else { 'unknown' }
    $session = if (-not [string]::IsNullOrWhiteSpace($env:AGENT_SESSION_NAME)) { $env:AGENT_SESSION_NAME } elseif (-not [string]::IsNullOrWhiteSpace($env:PS_SESSION_NAME)) { $env:PS_SESSION_NAME } else { 'default' }
    $owner = "{0}@{1}:{2}" -f $user, [System.Environment]::MachineName, $session
  }

  $reportPath = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/lease/bootstrap-lease.json'
  $arguments = @(
    $leaseScript,
    '--action', 'acquire',
    '--scope', 'workspace',
    '--owner', $owner,
    '--report', $reportPath
  )

  if ($env:AGENT_WRITER_LEASE_FORCE_TAKEOVER -eq '1') {
    $arguments += '--force-takeover'
  }
  if ($env:AGENT_WRITER_LEASE_STALE_SECONDS -match '^\d+$') {
    $arguments += @('--stale-seconds', $env:AGENT_WRITER_LEASE_STALE_SECONDS)
  }
  if ($env:AGENT_WRITER_LEASE_WAIT_MS -match '^\d+$') {
    $arguments += @('--wait-ms', $env:AGENT_WRITER_LEASE_WAIT_MS)
  }
  if ($env:AGENT_WRITER_LEASE_MAX_ATTEMPTS -match '^\d+$') {
    $arguments += @('--max-attempts', $env:AGENT_WRITER_LEASE_MAX_ATTEMPTS)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nodeCmd.Source
  foreach ($arg in $arguments) { $psi.ArgumentList.Add([string]$arg) }
  $psi.WorkingDirectory = (Resolve-Path '.').Path
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($stderr) {
    Write-Warning $stderr.TrimEnd()
  }

  $result = $null
  if ($stdout) {
    try {
      $result = $stdout | ConvertFrom-Json -ErrorAction Stop
    } catch {
      Write-Warning '[bootstrap] Unable to parse agent writer lease JSON output.'
    }
  }

  if ($result -and $result.PSObject.Properties['lease'] -and $result.lease -and $result.lease.PSObject.Properties['leaseId']) {
    $env:AGENT_WRITER_LEASE_ID = [string]$result.lease.leaseId
  }

  if ($proc.ExitCode -ne 0) {
    $statusLabel = if ($result -and $result.PSObject.Properties['status']) { [string]$result.status } else { 'unknown' }
    $message = ("[bootstrap] Agent writer lease acquisition failed (status={0}, exit={1}). " +
      "Use AGENT_WRITER_LEASE_FORCE_TAKEOVER=1 for stale takeovers or AGENT_WRITER_LEASE_ENABLED=0 to disable.") -f $statusLabel, $proc.ExitCode
    throw $message
  }

  if ($result -and $result.PSObject.Properties['status']) {
    Write-Host ("[bootstrap] Agent writer lease status: {0}" -f [string]$result.status)
  } else {
    Write-Host '[bootstrap] Agent writer lease acquired.'
  }

  return $result
}

function Invoke-GitCommand {
  param(
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & git @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $exitCode`n$output"
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-GitCurrentBranch {
  $result = Invoke-GitCommand -Arguments @('rev-parse','--abbrev-ref','HEAD') -AllowFailure
  if ($result.ExitCode -ne 0) { return $null }
  $branch = ($result.Output | Select-Object -First 1).Trim()
  if (-not $branch) { return $null }
  return $branch
}

function Get-GitStatusPorcelain {
  $result = Invoke-GitCommand -Arguments @('status','--porcelain') -AllowFailure
  if ($result.ExitCode -ne 0) { return @() }
  return @($result.Output)
}

function Test-GitWorktreeClean {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WorktreeRoot
  )

  $resolvedWorktreeRoot = (Resolve-Path -LiteralPath $WorktreeRoot).Path
  $result = Invoke-GitCommand -Arguments @('-C', $resolvedWorktreeRoot, 'status', '--porcelain') -AllowFailure
  if ($result.ExitCode -ne 0) {
    return $false
  }

  return (@($result.Output)).Count -eq 0
}

function Test-GitBranchExists {
  param([Parameter(Mandatory=$true)][string]$Name)
  Invoke-GitCommand -Arguments @('show-ref','--verify','--quiet',"refs/heads/$Name") -AllowFailure | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-RemoteDevelopRef {
  foreach ($remote in @('upstream','origin')) {
    $check = Invoke-GitCommand -Arguments @('ls-remote','--heads',$remote,'develop') -AllowFailure
    if ($check.ExitCode -eq 0 -and $check.Output) {
      return @{ Remote = $remote; Ref = "$remote/develop" }
    }
  }
  return $null
}

function Get-DevelopWorktreeRoots {
  $result = Invoke-GitCommand -Arguments @('worktree', 'list', '--porcelain') -AllowFailure
  if ($result.ExitCode -ne 0) {
    return @()
  }

  $roots = New-Object System.Collections.Generic.List[object]
  $currentWorktreePath = $null

  foreach ($line in @($result.Output)) {
    $text = [string]$line
    if ($text.StartsWith('worktree ')) {
      $currentWorktreePath = $text.Substring(9).Trim()
      continue
    }

    if ($text -eq 'branch refs/heads/develop' -and -not [string]::IsNullOrWhiteSpace($currentWorktreePath)) {
      $isClean = $false
      try {
        $isClean = Test-GitWorktreeClean -WorktreeRoot $currentWorktreePath
      } catch {
        $isClean = $false
      }
      $roots.Add([pscustomobject]@{
        Root = $currentWorktreePath
        IsClean = $isClean
      })
      continue
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
      $currentWorktreePath = $null
    }
  }

  return @(
    $roots |
      Group-Object -Property Root |
      ForEach-Object {
        $first = $_.Group | Select-Object -First 1
        [pscustomobject]@{
          Root = $first.Root
          IsClean = [bool]($first.IsClean)
        }
      }
  )
}

function Resolve-PriorityHelperRepoRoot {
  $repoRoot = (Resolve-Path '.').Path
  $currentBranch = Get-GitCurrentBranch
  $decision = Get-BootstrapHelperRootDecision `
    -CurrentBranch $currentBranch `
    -CurrentRepoRoot $repoRoot `
    -DevelopWorktreeRoots @(Get-DevelopWorktreeRoots)

  if (-not $decision) {
    return $repoRoot
  }

  if (-not [string]::IsNullOrWhiteSpace($decision.Message)) {
    Write-Host $decision.Message
  }

  if ([string]::IsNullOrWhiteSpace($decision.HelperRoot)) {
    return $repoRoot
  }

  return [string]$decision.HelperRoot
}

function Ensure-DevelopBranch {
  $current = Get-GitCurrentBranch

  $isDirty = $false
  $hasDevelop = $false
  $remoteRef = $null

  if ($current -in @('main', 'master', 'HEAD')) {
    $dirty = @(Get-GitStatusPorcelain)
    $isDirty = $dirty.Count -gt 0

    if (-not $isDirty) {
      $hasDevelop = Test-GitBranchExists -Name 'develop'
      if (-not $hasDevelop) {
        $remoteRef = Resolve-RemoteDevelopRef
      }
    }
  }

  $decision = Get-DevelopCheckoutDecision -CurrentBranch $current -IsDirty:$isDirty -HasDevelop:$hasDevelop -RemoteDevelopRef $remoteRef

  switch ($decision.Action) {
    'noop-already-develop' {
      return
    }
    'skip-unknown-branch' {
      Write-Warning $decision.Message
      return
    }
    'skip-work-branch' {
      Write-Host $decision.Message
      return
    }
    'skip-retain-branch' {
      Write-Host $decision.Message
      return
    }
    'skip-dirty' {
      Write-Warning $decision.Message
      return
    }
    'skip-no-remote-develop' {
      Write-Warning $decision.Message
      return
    }
    'create-develop-from-remote' {
      Write-Host $decision.Message
      Invoke-GitCommand -Arguments @('fetch', $decision.Remote, 'develop') | Out-Null
      Invoke-GitCommand -Arguments @('checkout', '-B', 'develop', $decision.Ref) | Out-Null
      return
    }
    'checkout-develop' {
      Write-Host $decision.Message
      Invoke-GitCommand -Arguments @('checkout', 'develop') | Out-Null
      return
    }
    default {
      throw "[bootstrap] Unsupported develop-branch decision: $($decision.Action)"
    }
  }
}

function Write-ReleaseSummary {
  param([pscustomobject]$SemVerResult)

  $handoffDir = Join-Path (Resolve-Path '.').Path 'tests/results/_agent/handoff'
  New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null

  $result = $null
  if ($SemVerResult -and $SemVerResult.PSObject.Properties['Result']) {
    $result = $SemVerResult.Result
  }

  $version = '(unknown)'
  $valid = $false
  $checkedAt = (Get-Date).ToString('o')
  $issues = @()

  if ($result) {
    if ($result.PSObject.Properties['version'] -and -not [string]::IsNullOrWhiteSpace($result.version)) {
      $version = [string]$result.version
    }
    if ($result.PSObject.Properties['valid']) {
      $valid = [bool]$result.valid
    }
    if ($result.PSObject.Properties['checkedAt'] -and $result.checkedAt) {
      $checkedAt = [string]$result.checkedAt
    }
    if ($result.PSObject.Properties['issues'] -and $result.issues) {
      $issues = @($result.issues)
    }
  }

  $summary = [ordered]@{
    schema   = 'agent-handoff/release-v1'
    version  = $version
    valid    = [bool]$valid
    issues   = $issues
    checkedAt = $checkedAt
  }

  $summaryPath = Join-Path $handoffDir 'release-summary.json'
  $previous = $null
  if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
    try { $previous = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch {}
  }

  ($summary | ConvertTo-Json -Depth 4) | Out-File -FilePath $summaryPath -Encoding utf8

  if ($previous) {
    $changed = ($previous.version -ne $summary.version) -or ($previous.valid -ne $summary.valid)
    if ($changed) {
      Write-Host ("[bootstrap] SemVer state changed {0}/{1} -> {2}/{3}" -f $previous.version,$previous.valid,$summary.version,$summary.valid) -ForegroundColor Cyan
    }
  }

  return $summary
}

Write-Host '[bootstrap] Detecting hook plane…'
Ensure-DevelopBranch
Invoke-Npm -Script 'hooks:plane' -AllowFailure

Write-Host '[bootstrap] Running workspace health gate (preflight)…'
Invoke-WorkspaceHealthGate -LeaseMode 'optional' -ReportName 'bootstrap-preflight-workspace-health.json'

Write-Host '[bootstrap] Repairing cross-plane runtime worktree registrations…'
Invoke-Npm -Script 'priority:runtime:worktrees:repair' -AllowFailure:$true

if ($env:AGENT_CODEX_STATE_HYGIENE_MODE -ne 'off') {
  $codexStateScript = if ($env:AGENT_CODEX_STATE_HYGIENE_MODE -eq 'apply') {
    'priority:codex:state:hygiene:apply'
  } else {
    'priority:codex:state:hygiene'
  }
  Write-Host ("[bootstrap] Checking Codex local-state hygiene ({0})…" -f $codexStateScript)
  Invoke-Npm -Script $codexStateScript -AllowFailure:$true
}

Write-Host '[bootstrap] Running hook preflight…'
Invoke-Npm -Script 'hooks:preflight' -AllowFailure

if ($VerboseHooks) {
  Write-Host '[bootstrap] Running hook parity diff…'
  Invoke-Npm -Script 'hooks:multi' -AllowFailure:$true
  Write-Host '[bootstrap] Validating hook summary schema…'
  Invoke-Npm -Script 'hooks:schema' -AllowFailure:$true
}

if (-not $PreflightOnly) {
  $priorityHelperRepoRoot = Resolve-PriorityHelperRepoRoot
  $priorityWorkingDirectory = (Resolve-Path '.').Path

  # Helper-root mode keeps artifacts in the caller checkout while treating the delegated develop checkout as the
  # authoritative control-plane code surface.
  Write-Host '[bootstrap] Acquiring agent writer lease…'
  $leaseResult = Invoke-AgentWriterLeaseAcquire

  $postLeaseMode = if ($leaseResult -and $leaseResult.PSObject.Properties['lease'] -and $leaseResult.lease) {
    'required'
  } else {
    'optional'
  }

  Write-Host ("[bootstrap] Running workspace health gate (post-lease, mode={0})…" -f $postLeaseMode)
  Invoke-WorkspaceHealthGate -LeaseMode $postLeaseMode -ReportName 'bootstrap-postlease-workspace-health.json'

  Write-Host '[bootstrap] Syncing standing priority snapshot…'
  Invoke-NodeScriptFromRepoRoot `
    -RepoRoot $priorityHelperRepoRoot `
    -WorkingDirectory $priorityWorkingDirectory `
    -ScriptRelativePath 'tools/priority/sync-standing-priority.mjs' `
    -RequiredPackages @('undici') `
    -Arguments @('--fail-on-missing', '--fail-on-multiple', '--auto-select-next', '--materialize-cache')
  $routerPath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/issue/router.json'
  $routerIssue = $null
  if (Test-Path -LiteralPath $routerPath -PathType Leaf) {
    try {
      $routerSnapshot = Get-Content -LiteralPath $routerPath -Raw | ConvertFrom-Json
      if ($routerSnapshot -and $routerSnapshot.PSObject.Properties['issue']) {
        $routerIssue = [int]$routerSnapshot.issue
      }
    } catch {
      Write-Warning "[bootstrap] Unable to parse router snapshot at $routerPath; standing reconciliation backstop skipped."
    }
  }
  if ($routerIssue) {
    Write-Host ("[bootstrap] Reconciling standing lane after merge completion for issue #{0}…" -f $routerIssue)
    $reconcileArgs = @('--issue', [string]$routerIssue)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
      $reconcileArgs = @('--repo', $env:GITHUB_REPOSITORY) + $reconcileArgs
    }
    Invoke-NodeScriptFromRepoRoot `
      -RepoRoot $priorityHelperRepoRoot `
      -WorkingDirectory $priorityWorkingDirectory `
      -ScriptRelativePath 'tools/priority/reconcile-standing-after-merge.mjs' `
      -RequiredPackages @('undici') `
      -Arguments $reconcileArgs `
      -AllowFailure:$true
  }
  Write-Host '[bootstrap] Projecting session-index-v2 promotion decision into issue reporting…'
  Invoke-NodeScriptFromRepoRoot `
    -RepoRoot $priorityHelperRepoRoot `
    -WorkingDirectory $priorityWorkingDirectory `
    -ScriptRelativePath 'tools/priority/project-session-index-v2-promotion-decision.mjs' `
    -RequiredPackages @('ajv', 'ajv-formats') `
    -AllowFailure:$true
  Write-Host '[bootstrap] Showing router plan…'
  $routerPath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/issue/router.json'
  if (Test-Path -LiteralPath $routerPath -PathType Leaf) {
    Write-Host (Get-Content -LiteralPath $routerPath -Raw).TrimEnd()
  } else {
    Write-Warning "[bootstrap] Router plan not found at $routerPath"
  }

  Write-Host '[bootstrap] Validating SemVer version…'
  $semverOutcome = Invoke-SemVerCheck -RepoRoot $priorityHelperRepoRoot -WorkingDirectory $priorityWorkingDirectory
  if ($semverOutcome -and $semverOutcome.Result) {
    Write-Host ('[bootstrap] Version: {0} (valid: {1})' -f $semverOutcome.Result.version, $semverOutcome.Result.valid)
    $summary = Write-ReleaseSummary -SemVerResult $semverOutcome
    if (-not $semverOutcome.Result.valid) {
      foreach ($issue in $summary.issues) { Write-Warning $issue }
    }
  } else {
    Write-Warning '[bootstrap] SemVer check skipped; writing placeholder summary.'
    $placeholder = [pscustomobject]@{
      Result = [pscustomobject]@{
        version = '(unknown)'
        valid = $false
        issues = @('SemVer check skipped during bootstrap')
        checkedAt = (Get-Date).ToString('o')
      }
    }
    Write-ReleaseSummary -SemVerResult $placeholder | Out-Null
  }

  Write-Host '[bootstrap] Summarizing safe-git reliability telemetry…'
  Invoke-SafeGitReliabilitySummary -RepoRoot $priorityHelperRepoRoot -WorkingDirectory $priorityWorkingDirectory

  Write-Host '[bootstrap] Writing continuity telemetry…'
  $continuityRuntimePath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/runtime/continuity-telemetry.json'
  $continuityHandoffPath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/handoff/continuity-summary.json'
  $continuityRepoRoot = $priorityHelperRepoRoot
  $continuityHelperScriptPath = Join-Path $priorityHelperRepoRoot 'tools/priority/continuity-telemetry.mjs'
  $continuityCallerScriptPath = Join-Path $priorityWorkingDirectory 'tools/priority/continuity-telemetry.mjs'
  if (
    (Test-Path -LiteralPath $continuityCallerScriptPath -PathType Leaf) -and
    (
      -not (Test-NodeScriptContainsToken -ScriptPath $continuityHelperScriptPath -Token 'operatorTurnEndWouldCreateIdleGap') -or
      -not (Test-NodeScriptContainsToken -ScriptPath $continuityHelperScriptPath -Token 'turnBoundary')
    )
  ) {
    $continuityRepoRoot = $priorityWorkingDirectory
    Write-Host '[bootstrap] Continuity helper checkout lacks turn-boundary support; using caller checkout script until develop helper catches up.'
  }
  Invoke-NodeScriptFromRepoRoot `
    -RepoRoot $continuityRepoRoot `
    -WorkingDirectory $priorityWorkingDirectory `
    -ScriptRelativePath 'tools/priority/continuity-telemetry.mjs' `
    -Arguments @('--repo-root', $priorityWorkingDirectory, '--output', $continuityRuntimePath, '--handoff-output', $continuityHandoffPath) `
    -AllowFailure:$true

  Write-Host '[bootstrap] Recording operator steering event evidence when continuity resumes with active work…'
  $steeringRuntimePath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/runtime/operator-steering-event.json'
  $steeringHandoffPath = Join-Path $priorityWorkingDirectory 'tests/results/_agent/handoff/operator-steering-event.json'
  $steeringHistoryDir = Join-Path $priorityWorkingDirectory 'tests/results/_agent/runtime/operator-steering-events'
  $invoiceTurnDir = Join-Path $priorityWorkingDirectory 'tests/results/_agent/cost/invoice-turns'
  $steeringRepoRoot = $priorityHelperRepoRoot
  if (-not (Test-Path -LiteralPath (Join-Path $steeringRepoRoot 'tools/priority/operator-steering-event.mjs') -PathType Leaf)) {
    $steeringRepoRoot = $priorityWorkingDirectory
    Write-Host '[bootstrap] Steering helper checkout is unavailable; using caller checkout script.'
  }
  Invoke-NodeScriptFromRepoRoot `
    -RepoRoot $steeringRepoRoot `
    -WorkingDirectory $priorityWorkingDirectory `
    -ScriptRelativePath 'tools/priority/operator-steering-event.mjs' `
    -Arguments @('--repo-root', $priorityWorkingDirectory, '--continuity', $continuityRuntimePath, '--output', $steeringRuntimePath, '--handoff-output', $steeringHandoffPath, '--history-dir', $steeringHistoryDir, '--invoice-turn-dir', $invoiceTurnDir) `
    -AllowFailure:$true
}

Write-Host '[bootstrap] Bootstrapping complete.'
