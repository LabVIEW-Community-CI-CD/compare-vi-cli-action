#Requires -Version 7.0
[CmdletBinding()]
param(
  [switch]$Push = $true,
  [switch]$CreatePR = $true,
  [string]$RepositoryRoot,
  [string]$Remote = 'origin',
  [string]$BaseBranch = 'develop',
  [string]$PushTarget = 'standing',
  [switch]$CloseIssue,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
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
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [Alias('Args')]
    [string[]]$GitArgs
  )
  $result = Invoke-Git @GitArgs
  if ($result.ExitCode -ne 0) { return $null }
  ($result.Output -join "`n").Trim()
}

function Should-SkipPath {
  param([string]$Path)
  $patterns = @(
    '^\.agent_priority_cache\.json$',
    '^\.agent_push_config\.json$',
    '^tests/results/',
    '^tests\\results\\',
    '^tests/$',
    '^tests\\$',
    '^tmp/',
    '^tmp\\',
    '^\.tmp/'
  )
  foreach ($pattern in $patterns) {
    if ($Path -match $pattern) { return $true }
  }
  return $false
}

function Invoke-GhCommand {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Args,
    [System.Management.Automation.CommandInfo]$GhCommand
  )
  if ($GhCommand -and $GhCommand.CommandType -eq [System.Management.Automation.CommandTypes]::Application) {
    & $GhCommand.Source @Args
  } else {
    & gh @Args
  }
}

function Convert-OutputToText {
  param([object[]]$Output)
  if (-not $Output) { return '' }
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($item in $Output) {
    if ($null -eq $item) { continue }
    if ($item -is [string]) {
      $lines.Add($item.TrimEnd()) | Out-Null
    } elseif ($item -is [System.Management.Automation.ErrorRecord]) {
      $lines.Add(($item.Exception.Message).TrimEnd()) | Out-Null
    } else {
      $lines.Add(($item | Out-String).Trim()) | Out-Null
    }
  }
  return ($lines | Where-Object { $_ -ne $null }) -join "`n"
}

function Get-OutputExcerpt {
  param(
    [string]$Text,
    [int]$MaxLines = 12
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  $lines = $Text -split '\r?\n'
  return @($lines | Where-Object { $_ -ne $null } | Select-Object -First $MaxLines)
}

function Analyze-PushResult {
  param(
    [psobject]$PushResult,
    [string]$Branch,
    [string]$Remote,
    [switch]$Executed
  )

  $analysis = [ordered]@{
    action     = if ($Executed) { 'ok' } else { 'skipped' }
    reasons    = @()
    suggestions= @()
    outputExcerpt = @()
  }

  if (-not $Executed) {
    return [pscustomobject]$analysis
  }

  if (-not $PushResult) {
    $analysis.action = 'unknown'
    $analysis.reasons = @('missing-result')
    return [pscustomobject]$analysis
  }

  $text = Convert-OutputToText -Output $PushResult.Output
  $analysis.outputExcerpt = @(Get-OutputExcerpt -Text $text)

  if ($PushResult.ExitCode -eq 0) {
    if ($text -match 'Everything up-to-date') {
      $analysis.action = 'noop'
      $analysis.reasons = @('remote-up-to-date')
    } else {
      $analysis.action = 'ok'
    }
    return [pscustomobject]$analysis
  }

  $analysis.action = 'review'
  $reasons = New-Object System.Collections.Generic.List[string]
  $reasons.Add('push-failed') | Out-Null
  $suggestions = New-Object System.Collections.Generic.List[string]

  if ($text -match 'non-fast-forward' -or $text -match 'fetch first' -or $text -match 'rejected') {
    $reasons.Add('non-fast-forward') | Out-Null
    if ($Remote -and $Branch) {
      $suggestions.Add(("Run 'git pull --rebase {0} {1}' then rerun After-CommitActions." -f $Remote,$Branch)) | Out-Null
    } else {
      $suggestions.Add("Run 'git pull --rebase' then rerun After-CommitActions.") | Out-Null
    }
  }

  if ($text -match 'Authentication failed' -or $text -match 'could not read from remote repository') {
    $reasons.Add('auth') | Out-Null
    $suggestions.Add('Verify Git remote authentication (credentials, PAT, or SSH key).') | Out-Null
  }

  if ($suggestions.Count -eq 0) {
    $suggestions.Add('Inspect the push output, resolve the issue, and rerun After-CommitActions.') | Out-Null
  }

  $analysis.reasons = @($reasons.ToArray())
  $analysis.suggestions = @($suggestions.ToArray())
  return [pscustomobject]$analysis
}

function Analyze-PrResult {
  param(
    [object]$PrResult,
    [switch]$Requested
  )

  $analysis = [ordered]@{
    action     = if ($Requested) { 'ok' } else { 'skipped' }
    reasons    = @()
    suggestions= @()
  }

  if (-not $Requested) {
    return [pscustomobject]$analysis
  }

  if (-not $PrResult) {
    $analysis.action = 'blocked'
    $analysis.reasons = @('pr-not-attempted')
    return [pscustomobject]$analysis
  }

  if ($PrResult.PSObject.Properties['created'] -and $PrResult.created) {
    $analysis.action = 'ok'
    return [pscustomobject]$analysis
  }

  if ($PrResult.PSObject.Properties['existing'] -and $PrResult.existing) {
    $analysis.action = 'noop'
    $analysis.reasons = @("existing-pr-#{0}" -f $PrResult.existing)
    return [pscustomobject]$analysis
  }

  if ($PrResult.PSObject.Properties['reason']) {
    $analysis.action = 'review'
    $analysis.reasons = @($PrResult.reason)
    switch ($PrResult.reason) {
      'gh-missing'     { $analysis.suggestions = @('Install GitHub CLI (gh) or ensure it is on PATH.'); break }
      'gh-auth-failed' { $analysis.suggestions = @('Run `gh auth login` to refresh authentication.'); break }
      default { }
    }
    return [pscustomobject]$analysis
  }

  $analysis.action = 'review'
  $reasons = New-Object System.Collections.Generic.List[string]
  $reasons.Add('pr-failed') | Out-Null
  if ($PrResult.PSObject.Properties['error']) {
    $reasons.Add("exit-{0}" -f $PrResult.error) | Out-Null
  }
  $analysis.reasons = @($reasons.ToArray())
  return [pscustomobject]$analysis
}

$repoRoot = $null
$popLocation = $false
if ($RepositoryRoot) {
  $repoRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
  Push-Location $repoRoot
  $popLocation = $true
} else {
  $repoRoot = Get-GitSingleLine @('rev-parse','--show-toplevel')
  if (-not $repoRoot) { throw 'Not inside a git repository.' }
  Push-Location $repoRoot
  $popLocation = $true
}

$summaryPath = Join-Path $repoRoot 'tests/results/_agent/post-commit.json'
$summaryDir = Split-Path -Parent $summaryPath
if (-not (Test-Path -LiteralPath $summaryDir)) {
  New-Item -ItemType Directory -Path $summaryDir -Force | Out-Null
}

$pushResult = $null
$prResult = $null
$commitMessage = $null
$branch = $null
$issueNumber = $null
$issueClosed = $false
$issueClosureResult = $null
$commitSha = $null
$pushFollowup = $null
$prFollowup = $null
$ghCommand = $null

if ($CreatePR -or $CloseIssue) {
  try {
    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
  } catch {
    $ghCommand = $null
  }
}

if ($env:COMPAREVI_SKIP_GH) {
  $ghCommand = $null
}

try {
  $status = Invoke-Git @('status','--porcelain')
  $rawEntries = @()
  if ($status.ExitCode -eq 0) {
    foreach ($line in ($status.Output | Where-Object { $_ })) {
      if (-not $line) { continue }
      $path = $line.Substring(3)
      $rawEntries += [pscustomobject]@{
        Raw  = $line
        Path = $path
      }
    }
  } else {
    $rawEntries = @([pscustomobject]@{ Raw = 'unknown'; Path = 'unknown' })
  }
  $dirtyEntries = @($rawEntries | Where-Object { -not (Should-SkipPath -Path $_.Path) })
  $folderEntries = @($dirtyEntries | Where-Object { $_.Path -eq 'tests/' })
  if ($folderEntries) {
    $otherTests = @($dirtyEntries | Where-Object { $_.Path -like 'tests/*' -and $_.Path -notmatch '^tests/results/_agent/' })
    if ($otherTests.Count -eq 0) {
      $dirtyEntries = @($dirtyEntries | Where-Object { $_.Path -ne 'tests/' })
    }
  }
  if ($dirtyEntries.Count -gt 0 -and -not $Force) {
    $paths = $dirtyEntries | ForEach-Object { $_.Path }
    throw ("Working tree is dirty; aborting post-commit automation. Offending paths: {0}. Use -Force to override." -f ($paths -join ', '))
  }

  $branch = Get-GitSingleLine @('rev-parse','--abbrev-ref','HEAD')
  if (-not $branch -or $branch -eq 'HEAD') { throw 'Cannot determine branch (detached HEAD).' }

  $commitMessage = Get-GitSingleLine @('log','-1','--pretty=%s')
  $commitSha = Get-GitSingleLine @('rev-parse','HEAD')
  $planPath = Join-Path $repoRoot 'tests/results/_agent/commit-plan.json'
  if (Test-Path -LiteralPath $planPath) {
    try {
      $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($plan.issue) { $issueNumber = [int]$plan.issue }
      if ($plan.target) { $PushTarget = $plan.target }
    } catch {}
  }
  if (-not $issueNumber) {
    $cachePath = Join-Path $repoRoot '.agent_priority_cache.json'
    if (Test-Path -LiteralPath $cachePath) {
      try {
        $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($cache.number) { $issueNumber = [int]$cache.number }
      } catch {}
    }
  }

  if ($Push) {
    $ensureArgs = @(
      '-NoLogo','-NoProfile',
      '-File', (Join-Path $repoRoot 'tools' 'Ensure-AgentPushTarget.ps1'),
      '-RepositoryRoot', $repoRoot,
      '-SkipTrackingCheck',
      '-SkipCleanCheck'
    )
    if ($PushTarget) { $ensureArgs += @('-Target',$PushTarget) }
    & pwsh @ensureArgs
    if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (pre-push).' }

    $upstreamResult = Invoke-Git @('rev-parse','--abbrev-ref','--symbolic-full-name','@{u}')
    $hasUpstream = $upstreamResult.ExitCode -eq 0

    if ($hasUpstream) {
      $pushResult = Invoke-Git @('push',$Remote)
    } else {
      $pushResult = Invoke-Git @('push','--set-upstream',$Remote,$branch)
    }
    if ($pushResult.ExitCode -ne 0) {
      throw ("git push failed:`n{0}" -f ($pushResult.Output -join "`n"))
    }

    & pwsh @ensureArgs
    if ($LASTEXITCODE -ne 0) { throw 'Push target contract failed (post-push).' }
  }

  if ($CreatePR) {
    if (-not $ghCommand) {
      $prResult = @{
        created = $false
        reason  = 'gh-missing'
      }
    } else {
      Invoke-GhCommand -Args @('auth','status') -GhCommand $ghCommand 2>$null
      $authExit = $LASTEXITCODE
      $LASTEXITCODE = 0
      if ($authExit -eq 0) {
        $existing = Invoke-GhCommand -Args @('pr','view','--json','number','--head',$branch) -GhCommand $ghCommand 2>$null
        $existingExit = $LASTEXITCODE
        $LASTEXITCODE = 0
        if ($existingExit -ne 0 -or -not $existing) {
          $title = if ($commitMessage) { $commitMessage } else { "Standing priority update #$issueNumber" }
          $args = @('pr','create','--base',$BaseBranch,'--head',$branch,'--title',$title,'--fill')
          if ($issueNumber) { $args += @('--body',("Automated updates for #{0}." -f $issueNumber)) }
          $prOutput = Invoke-GhCommand -Args $args -GhCommand $ghCommand
          $createExit = $LASTEXITCODE
          $LASTEXITCODE = 0
          if ($createExit -eq 0) {
            $prResult = @{
              created = $true
              output  = $prOutput
            }
          } else {
            $prResult = @{
              created = $false
              error   = $createExit
            }
          }
        } else {
          $data = $existing | ConvertFrom-Json
          $prResult = @{
            created  = $false
            existing = $data.number
          }
        }
      } else {
        $prResult = @{
          created = $false
          reason  = 'gh-auth-failed'
        }
      }
    }
  }

  if ($CloseIssue) {
    if (-not $issueNumber) {
      $issueClosureResult = @{
        status = 'skipped'
        reason = 'issue-number-missing'
      }
    } elseif ($Push -and $pushResult -and $pushResult.ExitCode -ne 0) {
      $issueClosureResult = @{
        status = 'skipped'
        reason = 'push-failed'
      }
    } elseif (-not $ghCommand) {
      $issueClosureResult = @{
        status = 'skipped'
        reason = 'gh-missing'
        suggestions = @('Install GitHub CLI (gh) or ensure it is available on PATH.')
      }
    } else {
      Invoke-GhCommand -Args @('auth','status') -GhCommand $ghCommand 2>$null
      $authExit = $LASTEXITCODE
      $LASTEXITCODE = 0
      if ($authExit -ne 0) {
        $issueClosureResult = @{
          status = 'skipped'
          reason = 'gh-auth-failed'
          suggestions = @('Run `gh auth login` to refresh authentication.')
        }
      } else {
        $removeLabel = Invoke-GhCommand -Args @('issue','edit',$issueNumber,'--remove-label','standing-priority') -GhCommand $ghCommand 2>&1
        $removeExit = $LASTEXITCODE
        $LASTEXITCODE = 0
        if ($removeExit -ne 0) {
          $issueClosureResult = @{
            status = 'failed-remove-label'
            output = $removeLabel
          }
        } else {
          $commentText = if ($commitSha) {
            "Automated closure via After-CommitActions.ps1 (`$commitSha`)."
          } else {
            'Automated closure via After-CommitActions.ps1.'
          }
          $closeOutput = Invoke-GhCommand -Args @('issue','close',$issueNumber,'--comment',$commentText) -GhCommand $ghCommand 2>&1
          $closeExit = $LASTEXITCODE
          $LASTEXITCODE = 0
          if ($closeExit -eq 0) {
            $issueClosed = $true
            $issueClosureResult = @{
              status = 'closed'
              output = $closeOutput
            }
          } else {
            $issueClosureResult = @{
              status = 'failed-close'
              output = $closeOutput
            }
          }
        }
      }
    }
  }
} finally {
  if ($popLocation) { Pop-Location }
  $pushFollowup = Analyze-PushResult -PushResult $pushResult -Branch $branch -Remote $Remote -Executed:$Push
  $prFollowup = Analyze-PrResult -PrResult $prResult -Requested:$CreatePR
  $summary = [ordered]@{
    schema        = 'post-commit/actions@v1'
    generatedAt   = (Get-Date).ToString('o')
    repoRoot      = $repoRoot
    branch        = $branch
    commitMessage = $commitMessage
    commitSha     = $commitSha
    pushExecuted  = [bool]$Push
    pushResult    = if ($pushResult) { $pushResult } else { $null }
    pushFollowup  = $pushFollowup
    createPR      = [bool]$CreatePR
    prResult      = $prResult
    prFollowup    = $prFollowup
    issue         = $issueNumber
    issueClosed   = $issueClosed
    issueCloseResult = $issueClosureResult
  }
  $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $summaryPath -Encoding utf8
}

$global:LASTEXITCODE = 0
