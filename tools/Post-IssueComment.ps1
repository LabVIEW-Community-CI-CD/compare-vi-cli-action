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
    $args = $issueArg + @('--body-file', $resolved.Path)
    if (-not $Quiet) {
      Write-Host ("Posting comment from file '{0}' to issue #{1}..." -f $resolved.Path, $Issue)
    }
    Invoke-GhIssueComment -Arguments $args
  }
  'Body' {
    $temp = [System.IO.Path]::GetTempFileName()
    try {
      Set-Content -LiteralPath $temp -Value $Body -Encoding utf8
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
