#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$AutoCommit,
  [string]$CommitMessage,
  [string]$BaseBranch = 'develop',
  [switch]$SkipBranchCreation,
  [switch]$NoSummary,
  [switch]$Force,
  [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Args')]
    [string[]]$GitArgs
  )
  $output = & git @GitArgs 2>&1
  $exit = $LASTEXITCODE
  [pscustomobject]@{
    ExitCode = $exit
    Output   = if ($output -is [System.Array]) { @($output) } elseif ($null -eq $output) { @() } else { @($output) }
  }
}

function Get-GitSingleLine {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('Args')]
    [string[]]$GitArgs
  )
  $result = Invoke-Git -Args $GitArgs
  if ($result.ExitCode -ne 0) { return $null }
  ($result.Output -join "`n").Trim()
}

function Get-StandingPriority {
  param([string]$RepoRoot)
  $cache = Join-Path $RepoRoot '.agent_priority_cache.json'
  if (-not (Test-Path -LiteralPath $cache -PathType Leaf)) {
    throw "Standing priority cache not found: $cache. Run priority:sync first."
  }
  $content = Get-Content -LiteralPath $cache -Raw | ConvertFrom-Json -ErrorAction Stop
  if (-not $content.number -or -not $content.title) {
    throw "Standing priority cache missing number/title. Re-run priority:sync."
  }
  return $content
}

function Get-StandingBranchName {
  param([int]$Number,[string]$Title,[string]$Prefix = 'issue')
  $slug = ($Title -replace '[^a-zA-Z0-9\- ]','' -replace '\s+','-').ToLowerInvariant()
  if (-not $slug) { $slug = 'work' }
  "{0}/{1}-{2}" -f $Prefix,$Number,$slug
}

function Ensure-StandingBranch {
  param(
    [string]$TargetBranch,
    [string]$BaseBranch,
    [switch]$SkipCreation
  )
  $current = Get-GitSingleLine -Args @('rev-parse','--abbrev-ref','HEAD')
  if ($current -eq $TargetBranch) { return $current }
  if ($SkipCreation) {
    throw "Currently on '$current' but expected '$TargetBranch'. Use -SkipBranchCreation only when branch is already checked out."
  }
  $existsLocal = Invoke-Git -Args @('rev-parse','--verify','--quiet',"refs/heads/$TargetBranch")
  if ($existsLocal.ExitCode -eq 0) {
    $switchResult = Invoke-Git -Args @('checkout',$TargetBranch)
    if ($switchResult.ExitCode -ne 0) { throw "Failed to checkout $TargetBranch." }
    return $TargetBranch
  }
  $baseRef = $BaseBranch
  if (-not $baseRef) { $baseRef = 'develop' }
  [void](Invoke-Git -Args @('fetch','origin',$baseRef))
  $createResult = Invoke-Git -Args @('checkout','-b',$TargetBranch,$baseRef)
  if ($createResult.ExitCode -ne 0) {
    # fallback: create from current HEAD to preserve changes
    $fallback = Invoke-Git -Args @('checkout','-b',$TargetBranch)
    if ($fallback.ExitCode -ne 0) { throw "Failed to create branch $TargetBranch." }
  }
  return $TargetBranch
}

function Get-StatusEntries {
  param()
  $result = Invoke-Git -Args @('status','--porcelain=v2','--untracked-files=normal')
  if ($result.ExitCode -ne 0) { throw "git status failed.`n$($result.Output -join "`n")" }
  $entries = @()
  foreach ($line in $result.Output) {
    if (-not $line) { continue }
    if ($line.StartsWith('1 ')) {
      $parts = $line.Split(' ')
      $path = $parts[-1]
      $entries += [pscustomobject]@{
        Path = $path
        Type = 'tracked'
        Code = $parts[1]
      }
    } elseif ($line.StartsWith('? ')) {
      $path = $line.Substring(2)
      $entries += [pscustomobject]@{
        Path = $path
        Type = 'untracked'
        Code = '??'
      }
    }
  }
  return $entries
}

function Should-SkipPath {
  param([string]$Path)
  $patterns = @(
    '^\.agent_priority_cache\.json$',
    '^\.agent_push_config\.json$',
    '^tests/results/',
    '^tests\\results\\',
    '^tmp/',
    '^tmp\\',
    '^\.tmp/',
    '^node_modules/',
    '^dist/',
    '^artifacts/',
    '^\.vscode/'
  )
  foreach ($pattern in $patterns) {
    if ($Path -match $pattern) { return $true }
  }
  return $false
}

function Is-DocumentationPath {
  param([string]$Path)
  if (-not $Path) { return $false }
  $normalized = $Path -replace '\\','/'
  if ($normalized -match '^docs/') { return $true }
  $name = [System.IO.Path]::GetFileName($normalized)
  $docNames = @(
    'README.md',
    'AGENTS.md',
    'PR_NOTES.md',
    'TAG_PREP_CHECKLIST.md',
    'CONTRIBUTING.md'
  )
  if ($docNames -contains $name) { return $true }
  $extension = [System.IO.Path]::GetExtension($normalized)
  if (-not [string]::IsNullOrWhiteSpace($extension)) {
    $extension = $extension.ToLowerInvariant()
    $docExtensions = @('.md','.adoc','.txt','.rst','.mdown')
    if ($docExtensions -contains $extension) { return $true }
  }
  return $false
}

function Get-PesterSummary {
  param([string]$RepoRoot)
  $summaryPath = Join-Path $RepoRoot 'tests/results/pester-summary.json'
  if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) { return $null }
  try {
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
  $timestamp = $null
  if ($summary.PSObject.Properties['timestamp'] -and $summary.timestamp) {
    try {
      $timestamp = [datetime]::Parse($summary.timestamp, [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
      $timestamp = $null
    }
  }
  return [pscustomobject]@{
    Path               = $summaryPath
    Timestamp          = $timestamp
    TimestampUtc       = if ($timestamp) { $timestamp.ToUniversalTime() } else { $null }
    TimestampFormatted = if ($timestamp) { $timestamp.ToString('o') } else { $null }
    IncludeIntegration = if ($summary.PSObject.Properties['includeIntegration']) { [bool]$summary.includeIntegration } else { $null }
  }
}

function Get-TestDecision {
  param(
    [string[]]$Paths,
    [object[]]$DiffEntries,
    [string]$RepoRoot
  )

  $result = [ordered]@{
    decision          = 'unknown'
    reasons           = @()
    lastRun           = $null
    includeIntegration= $null
    summaryPath       = $null
    stagedLatestChange= $null
    docOnly           = $false
  }

  if (-not $Paths -or (@($Paths)).Count -eq 0) {
    $result.decision = 'skip'
    $result.reasons  = @('no-staged-files')
    return [pscustomobject]$result
  }

  $docOnly = $true
  foreach ($path in $Paths) {
    if (-not (Is-DocumentationPath -Path $path)) {
      $docOnly = $false
      break
    }
  }
  $result.docOnly = $docOnly

  $pesterSummary = Get-PesterSummary -RepoRoot $RepoRoot
  if ($pesterSummary) {
    $result.lastRun = $pesterSummary.TimestampFormatted
    $result.includeIntegration = $pesterSummary.IncludeIntegration
    $result.summaryPath = $pesterSummary.Path
  }

  if ($docOnly) {
    $result.decision = 'skip'
    $result.reasons  = @('doc-only-changes')
    return [pscustomobject]$result
  }

  if (-not $pesterSummary) {
    $result.decision = 'required'
    $result.reasons  = @('pester-summary-missing')
    return [pscustomobject]$result
  }

  $latestChangeUtc = $null
  foreach ($path in $Paths) {
    $fsPath = Join-Path $RepoRoot $path
    if (Test-Path -LiteralPath $fsPath) {
      try {
        $info = Get-Item -LiteralPath $fsPath -ErrorAction Stop
        $candidate = $info.LastWriteTimeUtc
        if (-not $latestChangeUtc -or $candidate -gt $latestChangeUtc) {
          $latestChangeUtc = $candidate
        }
      } catch {
        # ignore retrieval failures; treat as requiring fresh tests
        $latestChangeUtc = [datetime]::UtcNow
        break
      }
    } else {
      # deleted or renamed entry – conservative and require fresh tests
      $latestChangeUtc = [datetime]::UtcNow
      break
    }
  }

  if (-not $latestChangeUtc) {
    $latestChangeUtc = [datetime]::UtcNow
  }

  $result.stagedLatestChange = $latestChangeUtc.ToString('o')

  if (-not $pesterSummary.TimestampUtc) {
    $result.decision = 'required'
    $result.reasons  = @('pester-summary-missing-timestamp')
    return [pscustomobject]$result
  }

  $freshThreshold = $pesterSummary.TimestampUtc.AddSeconds(10)
  if ($latestChangeUtc -gt $freshThreshold) {
    $result.decision = 'required'
    $result.reasons  = @('tests-older-than-staged-changes')
  } else {
    $result.decision = 'fresh'
    $result.reasons  = @()
  }

  return [pscustomobject]$result
}

function Get-CommitSuggestion {
  param(
    [string[]]$Paths,
    [object[]]$DiffEntries,
    [int]$IssueNumber
  )

  $paths = @($Paths | Where-Object { $_ })
  $docOnly = $true
  $hasAddition = $false
  if ($DiffEntries) {
    foreach ($entry in $DiffEntries) {
      if ($entry.Status -match 'A') { $hasAddition = $true; break }
    }
  }

  $labels = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($path in $paths) {
    if (-not (Is-DocumentationPath -Path $path)) {
      $docOnly = $false
    }
    $root = if ($path -match '[\\/]') { ($path -split '[\\/]',2)[0] } else { $path }
    switch -Regex ($path) {
      'Ensure-AgentPushTarget' { $null = $labels.Add('push-target helper'); continue }
      'Prepare-StandingCommit' { $null = $labels.Add('standing commit helper'); continue }
    }
    switch -Regex ($root) {
      '^tools$' { $null = $labels.Add('tools'); continue }
      '^tests$' { $null = $labels.Add('tests'); continue }
      '^docs$' { $null = $labels.Add('docs'); continue }
      '^\.github$' { $null = $labels.Add('ci'); continue }
    }
    if ($root -match 'AGENT') { $null = $labels.Add('agent docs'); continue }
    if ($root -eq 'README.md') { $null = $labels.Add('readme'); continue }
    if ($root -match '\.ps1$') { $null = $labels.Add('scripts'); continue }
    $null = $labels.Add('repo')
  }

  if ($labels.Count -eq 0) { $null = $labels.Add('standing priority update') }

  $description = [string]::Join(' + ', $labels)
  $type = if ($hasAddition) { 'feat' } else { 'chore' }
  $labelArray = @()
  foreach ($label in $labels) {
    $labelArray += $label
  }
  return [pscustomobject]@{
    Type = $type
    Description = $description
    Message = ("{0}(#{1}): {2}" -f $type,$IssueNumber,$description)
    Labels = $labelArray
    DocOnly = [bool]$docOnly
  }
}

$repoRoot = $null
$popLocation = $false
if ($RepositoryRoot) {
  $repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
  Push-Location $repoRoot
  $popLocation = $true
} else {
  $repoRoot = Get-GitSingleLine -Args @('rev-parse','--show-toplevel')
  if (-not $repoRoot) { throw 'Not inside a git repository.' }
  Push-Location $repoRoot
  $popLocation = $true
}
try {
  $standing = Get-StandingPriority -RepoRoot $repoRoot
  $issueNumber = [int]$standing.number
  $branchName = Get-StandingBranchName -Number $issueNumber -Title $standing.title

  Ensure-StandingBranch -TargetBranch $branchName -BaseBranch $BaseBranch -SkipCreation:$SkipBranchCreation | Out-Null

  $statusEntries = Get-StatusEntries
  $autoStage = @()
  $skipped = @()
  foreach ($entry in $statusEntries) {
    if (Should-SkipPath -Path $entry.Path) {
      $skipped += $entry
      continue
    }
    $autoStage += $entry
  }

  if ($autoStage.Count -eq 0 -and -not $Force) {
    Write-Host '[prepare] No eligible files found to stage.' -ForegroundColor Yellow
  } else {
    foreach ($path in ($autoStage | Select-Object -ExpandProperty Path -Unique)) {
      $stageResult = Invoke-Git -Args @('add','--', $path)
      if ($stageResult.ExitCode -ne 0) { throw "Failed to stage $path" }
    }
    if ($autoStage.Count -gt 0) {
      Write-Host ("[prepare] Staged {0} file(s)." -f $autoStage.Count) -ForegroundColor Green
    }
  }

  $stagedAfter = Invoke-Git -Args @('diff','--cached','--name-only')
  $stagedPaths = if ($stagedAfter.ExitCode -eq 0) { @($stagedAfter.Output) } else { @() }

  $nameStatusResult = Invoke-Git -Args @('diff','--cached','--name-status')
  $diffEntries = @()
  if ($nameStatusResult.ExitCode -eq 0) {
    foreach ($line in $nameStatusResult.Output) {
      if (-not $line) { continue }
      $parts = $line -split '\s+',3
      if ($parts.Count -lt 2) { continue }
      $status = $parts[0]
      $path = $parts[-1]
      $diffEntries += [pscustomobject]@{ Status = $status; Path = $path }
    }
  }

    $suggestion = Get-CommitSuggestion -Paths $stagedPaths -DiffEntries $diffEntries -IssueNumber $issueNumber
    $commitLabels = @()
    if ($suggestion.PSObject.Properties['Labels']) {
      $commitLabels = @($suggestion.Labels)
    }
    $commitMessageReasons = @()
    if ((@($commitLabels)).Count -eq 1 -and $commitLabels[0] -eq 'standing priority update') {
      $commitMessageReasons += 'generic-description'
    }
    $testDecision = Get-TestDecision -Paths $stagedPaths -DiffEntries $diffEntries -RepoRoot $repoRoot

    $docOnlyChange = $false
    if ($suggestion.PSObject.Properties['DocOnly'] -and $suggestion.DocOnly) {
      $docOnlyChange = $true
    } elseif ($testDecision -and $testDecision.PSObject.Properties['docOnly'] -and $testDecision.docOnly) {
      $docOnlyChange = $true
    }
    if ($docOnlyChange -and $suggestion.Type -eq 'feat') {
      $commitMessageReasons += 'doc-only-change-prefers-chore'
    }
    $commitMessageNeedsEdit = (@($commitMessageReasons)).Count -gt 0
    $commitIssued = $false

    if ($AutoCommit) {
    if (-not $stagedPaths -or (@($stagedPaths)).Count -eq 0) {
        Write-Host '[prepare] AutoCommit requested but nothing is staged; skipping commit.' -ForegroundColor Yellow
    } else {
      $message = if ($CommitMessage) { $CommitMessage } else { $suggestion.Message }
      $commitResult = Invoke-Git -Args @('commit','-m',$message)
      if ($commitResult.ExitCode -ne 0) { throw 'git commit failed.' }
      Write-Host ("[prepare] Created commit: {0}" -f $message) -ForegroundColor Green
      $commitIssued = $true
    }
  } elseif ($CommitMessage) {
    Write-Host ("[prepare] Commit message suggestion: {0}" -f $CommitMessage) -ForegroundColor Cyan
    } else {
      Write-Host ("[prepare] Suggested commit message: {0}" -f $suggestion.Message) -ForegroundColor Cyan
    }

    if (-not $stagedPaths -or (@($stagedPaths)).Count -eq 0) {
      $commitMessageState = 'no-staged-files'
      $commitMessageNeedsEdit = $false
      $commitMessageReasons = @()
    } elseif ($CommitMessage) {
      $commitMessageState = 'custom-message-supplied'
    } elseif ($AutoCommit) {
      $commitMessageState = if ($commitIssued) { 'auto-committed' } else { 'auto-commit-skipped' }
    } else {
      $commitMessageState = 'suggested'
    }

    $commitReasonList = @($commitMessageReasons)
    if ($commitMessageNeedsEdit) {
      $reasonText = if ($commitReasonList.Count -gt 0) { $commitReasonList -join ', ' } else { 'unspecified' }
      Write-Warning ("[prepare] Commit message flagged for manual review ({0})." -f $reasonText)
    }

    $testReasonList = @()
    if ($null -ne $testDecision.reasons) {
      $testReasonList = @($testDecision.reasons)
    }
    if ($testDecision.decision -eq 'required') {
      $testReason = if ($testReasonList.Count -gt 0) { $testReasonList -join ', ' } else { 'unspecified' }
      Write-Warning ("[prepare] Tests are required ({0})." -f $testReason)
    } elseif ($testDecision.decision -eq 'skip') {
      $testReason = if ($testReasonList.Count -gt 0) { $testReasonList -join ', ' } else { 'automated-decision' }
      Write-Host ("[prepare] Tests may be skipped ({0})." -f $testReason) -ForegroundColor DarkGray
    }

    if (-not $NoSummary) {
      $summaryPath = Join-Path $repoRoot 'tests/results/_agent/commit-plan.json'
      if (-not (Test-Path -LiteralPath (Split-Path -Parent $summaryPath))) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $summaryPath) -Force | Out-Null
      }
    $summary = [ordered]@{
      schema        = 'agent-commit-plan/v1'
      generatedAt   = (Get-Date).ToString('o')
      issue         = $issueNumber
        branch        = $branchName
      staged        = @($stagedPaths)
        autoSkipped   = @($skipped | Select-Object -ExpandProperty Path -Unique)
        suggestedMessage = if ($CommitMessage) { $CommitMessage } else { $suggestion.Message }
        commitType    = $suggestion.Type
        commitDescription = $suggestion.Description
        autoCommitted = $commitIssued
        labels        = @($commitLabels)
        tests         = $testDecision
        commitMessageStatus = [ordered]@{
          needsEdit = [bool]$commitMessageNeedsEdit
          reasons   = @($commitMessageReasons)
          state     = $commitMessageState
          docOnly   = if ($suggestion.PSObject.Properties['DocOnly']) { [bool]$suggestion.DocOnly } else { $false }
        }
      }
      $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $summaryPath -Encoding utf8
      Write-Host ("[prepare] Summary written to {0}" -f $summaryPath) -ForegroundColor Gray
    }
}
finally {
  if ($popLocation) { Pop-Location }
}


