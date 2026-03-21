#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='BodyFile')]
param(
  [Parameter(Mandatory = $true)]
  [int]$PullRequest,

  [Parameter()]
  [string]$Repo,

  [Parameter(ParameterSetName = 'BodyFile', Mandatory = $true)]
  [string]$BodyFile,

  [Parameter(ParameterSetName = 'Body', Mandatory = $true)]
  [string]$Body,

  [switch]$EditLast,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Gh {
  if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required but was not found on PATH."
  }
}

function Invoke-GhPullRequestComment {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & gh @Arguments
  if (-not $?) {
    $exitCode = if (Test-Path variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
    if ($null -ne $exitCode) {
      throw "gh pr comment exited with code $exitCode."
    }
    throw 'gh pr comment failed.'
  }
}

Ensure-Gh

$commentArgs = @('pr', 'comment', $PullRequest.ToString())
if (-not [string]::IsNullOrWhiteSpace($Repo)) {
  $commentArgs += @('--repo', $Repo.Trim())
}
if ($EditLast) {
  $commentArgs += '--edit-last'
}

switch ($PSCmdlet.ParameterSetName) {
  'BodyFile' {
    $resolved = Resolve-Path -LiteralPath $BodyFile -ErrorAction Stop
    $args = $commentArgs + @('--body-file', $resolved.Path)
    if (-not $Quiet) {
      Write-Host ("Posting comment from file '{0}' to PR #{1}..." -f $resolved.Path, $PullRequest)
    }
    Invoke-GhPullRequestComment -Arguments $args
  }
  'Body' {
    $temp = [System.IO.Path]::GetTempFileName()
    try {
      Set-Content -LiteralPath $temp -Value $Body -Encoding utf8
      $args = $commentArgs + @('--body-file', $temp)
      if (-not $Quiet) {
        Write-Host ("Posting comment to PR #{0} using temporary body file..." -f $PullRequest)
      }
      Invoke-GhPullRequestComment -Arguments $args
    } finally {
      Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue
    }
  }
  default {
    throw "Unsupported parameter set '$($PSCmdlet.ParameterSetName)'."
  }
}

if (-not $Quiet) {
  Write-Host 'Pull request comment posted successfully.' -ForegroundColor Green
}
