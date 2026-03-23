#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='BodyFile')]
param(
  [Parameter(Mandatory=$true)]
  [int]$Issue,

  [Parameter(ParameterSetName='BodyFile', Mandatory=$true)]
  [string]$BodyFile,

  [Parameter(ParameterSetName='Body', Mandatory=$true)]
  [string]$Body,

  [switch]$EditLast,
  [switch]$SkipBudgetHook,
  [string]$BudgetHookMarkdownFile,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Gh {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required but was not found on PATH."
  }
}

Ensure-Gh

$script:CommentBudgetHookStartMarker = '<!-- priority:github-comment-budget-hook:start -->'
$script:CommentBudgetHookEndMarker = '<!-- priority:github-comment-budget-hook:end -->'
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Remove-CommentBudgetHook {
  param(
    [AllowNull()]
    [string]$BodyText
  )

  if ([string]::IsNullOrWhiteSpace($BodyText)) {
    return ''
  }

  $startIndex = $BodyText.IndexOf($script:CommentBudgetHookStartMarker, [System.StringComparison]::Ordinal)
  if ($startIndex -lt 0) {
    return $BodyText.TrimEnd("`r", "`n")
  }

  $endIndex = $BodyText.IndexOf($script:CommentBudgetHookEndMarker, $startIndex, [System.StringComparison]::Ordinal)
  if ($endIndex -lt 0) {
    return $BodyText.TrimEnd("`r", "`n")
  }

  $prefix = $BodyText.Substring(0, $startIndex).TrimEnd("`r", "`n")
  $suffix = $BodyText.Substring($endIndex + $script:CommentBudgetHookEndMarker.Length).TrimStart("`r", "`n")

  if (-not [string]::IsNullOrWhiteSpace($prefix) -and -not [string]::IsNullOrWhiteSpace($suffix)) {
    return ($prefix + "`n`n" + $suffix).TrimEnd("`r", "`n")
  }

  return ($prefix + $suffix).TrimEnd("`r", "`n")
}

function New-CommentBudgetHookFailureMarkdown {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Message
  )

  $sanitizedMessage = ($Message -replace '\s+', ' ').Trim()
  return @(
    $script:CommentBudgetHookStartMarker
    "_Budget hook_: unavailable (`comment-budget-hook-generation-failed`): $sanitizedMessage."
    $script:CommentBudgetHookEndMarker
  ) -join "`n"
}

function Get-CommentBudgetHookMarkdown {
  param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('issue', 'pr')]
    [string]$TargetKind,

    [Parameter(Mandatory=$true)]
    [int]$TargetNumber,

    [string]$Repo,

    [string]$MarkdownFile,

    [switch]$SkipHook
  )

  if ($SkipHook) {
    return ''
  }

  if (-not [string]::IsNullOrWhiteSpace($MarkdownFile)) {
    return (Get-Content -LiteralPath (Resolve-Path -LiteralPath $MarkdownFile -ErrorAction Stop).Path -Raw)
  }

  $hookScriptPath = Join-Path $script:RepoRoot 'tools' 'priority' 'github-comment-budget-hook.mjs'
  $hookMarkdownPath = Join-Path $script:RepoRoot 'tests' 'results' '_agent' 'cost' 'github-comment-budget-hook.md'
  $hookArgs = @(
    $hookScriptPath,
    '--repo-root', $script:RepoRoot,
    '--target-kind', $TargetKind,
    '--target-number', $TargetNumber.ToString(),
    '--markdown-output', $hookMarkdownPath
  )
  if (-not [string]::IsNullOrWhiteSpace($Repo)) {
    $hookArgs += @('--repo', $Repo.Trim())
  }

  try {
    & node @hookArgs | Out-Null
    if (-not $?) {
      $exitCode = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
      throw "github-comment-budget-hook exited with code $exitCode."
    }
    return (Get-Content -LiteralPath $hookMarkdownPath -Raw)
  } catch {
    return New-CommentBudgetHookFailureMarkdown -Message $_.Exception.Message
  }
}

function Merge-CommentBudgetHook {
  param(
    [AllowNull()]
    [string]$BodyText,

    [AllowNull()]
    [string]$HookMarkdown
  )

  $cleanBody = Remove-CommentBudgetHook -BodyText $BodyText
  if ([string]::IsNullOrWhiteSpace($HookMarkdown)) {
    return $cleanBody
  }
  $normalizedHook = $HookMarkdown.TrimEnd("`r", "`n")
  if ([string]::IsNullOrWhiteSpace($cleanBody)) {
    return $normalizedHook
  }
  return ($cleanBody.TrimEnd("`r", "`n") + "`n`n" + $normalizedHook).TrimEnd("`r", "`n")
}

function Invoke-GhIssueComment {
  param(
    [Parameter(Mandatory=$true)]
    [string[]]$Arguments
  )

  & gh @Arguments
  if (-not $?) {
    $exitCode = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
    if ($null -ne $exitCode) {
      throw "gh issue comment exited with code $exitCode."
    }
    throw 'gh issue comment failed.'
  }
}

$issueArg = @('issue','comment',$Issue.ToString())
if ($EditLast) {
  $issueArg = @('issue','comment',$Issue.ToString(),'--edit-last')
}

switch ($PSCmdlet.ParameterSetName) {
  'BodyFile' {
    $resolved = Resolve-Path -LiteralPath $BodyFile -ErrorAction Stop
    $bodyText = Get-Content -LiteralPath $resolved.Path -Raw
    $hookMarkdown = Get-CommentBudgetHookMarkdown -TargetKind issue -TargetNumber $Issue -MarkdownFile $BudgetHookMarkdownFile -SkipHook:$SkipBudgetHook
    $mergedBody = Merge-CommentBudgetHook -BodyText $bodyText -HookMarkdown $hookMarkdown
    $temp = [System.IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $temp -Value $mergedBody -Encoding utf8
    $args = $issueArg + @('--body-file', $temp)
    if (-not $Quiet) {
      Write-Host ("Posting comment from file '{0}' to issue #{1}..." -f $resolved.Path, $Issue)
    }
    try {
      Invoke-GhIssueComment -Arguments $args
    } finally {
      Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
  }
  'Body' {
    $temp = [System.IO.Path]::GetTempFileName()
    try {
      $hookMarkdown = Get-CommentBudgetHookMarkdown -TargetKind issue -TargetNumber $Issue -MarkdownFile $BudgetHookMarkdownFile -SkipHook:$SkipBudgetHook
      $mergedBody = Merge-CommentBudgetHook -BodyText $Body -HookMarkdown $hookMarkdown
      Set-Content -LiteralPath $temp -Value $mergedBody -Encoding utf8
      $args = $issueArg + @('--body-file', $temp)
      if (-not $Quiet) {
        Write-Host ("Posting comment to issue #{0} using temporary body file..." -f $Issue)
      }
      Invoke-GhIssueComment -Arguments $args
    } finally {
      Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
  }
  default {
    throw "Unsupported parameter set '$($PSCmdlet.ParameterSetName)'."
  }
}

if (-not $Quiet) {
  Write-Host "Issue comment posted successfully." -ForegroundColor Green
}
