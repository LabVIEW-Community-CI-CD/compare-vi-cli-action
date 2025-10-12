#Requires -Version 7.0
<#
.SYNOPSIS
  Run the orchestrated run watcher inside a PowerShell container.

.DESCRIPTION
  Convenience wrapper to execute tools/Watch-OrchestratedRun.ps1 in Docker. For authentication,
  pass a token via -Token or set GH_TOKEN/GITHUB_TOKEN in the host environment. The wrapper forwards
  those env vars without echoing the token value on the command line.

.PARAMETER RunId
  Workflow run id to inspect. Required in container (branch inference would require git in image).

.PARAMETER PollSeconds
  Poll interval for run status checks.

.PARAMETER Repo
  Optional owner/repo slug to aid REST calls when gh is unavailable.

.PARAMETER Token
  Optional GitHub token to forward as GH_TOKEN (preferred) if host env is not already set.

.EXAMPLE
  pwsh -File tools/Watch-InDocker.ps1 -RunId 18435836406 -Repo owner/repo -Token $env:GH_TOKEN
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$RunId,
  [int]$PollSeconds = 15,
  [string]$Repo,
  [string]$Token
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'docker' -ErrorAction SilentlyContinue)) {
  throw "Docker CLI not found. Install Docker to use this wrapper."
}

function Get-DockerHostPath {
  param([string]$Path = '.')
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  if ($IsWindows) {
    $drive = $resolved.Substring(0,1).ToLowerInvariant()
    $rest = $resolved.Substring(2)
    $rest = $rest.TrimStart('\')
    $rest = $rest -replace '\\','/'
    return "/$drive/$rest"
  }
  return $resolved
}

$hostPath = Get-DockerHostPath '.'
$volumeSpec = "${hostPath}:/work"

# Forward token via environment only (avoid showing in process args)
$restoreGh = $env:GH_TOKEN
$restoreGt = $env:GITHUB_TOKEN
try {
  function Resolve-TokenValue {
    param([string]$Explicit,[string]$EnvGh,[string]$EnvGithub,[string]$FilePath = 'C:\github_token.txt')
    if ($Explicit) { return $Explicit }
    if ($EnvGh) { return $EnvGh }
    if ($EnvGithub) { return $EnvGithub }
    if ($FilePath -and (Test-Path -LiteralPath $FilePath)) {
      try {
        $val = (Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop).Trim()
        if ($val) { return $val }
      } catch {
        Write-Verbose ("Failed to read token file {0}: {1}" -f $FilePath, $_.Exception.Message)
      }
    }
    return $null
  }

  $resolvedToken = Resolve-TokenValue -Explicit $Token -EnvGh $env:GH_TOKEN -EnvGithub $env:GITHUB_TOKEN
  if ($resolvedToken -and -not $env:GH_TOKEN) { $env:GH_TOKEN = $resolvedToken }

  $envArgs = @()
  if ($env:GH_TOKEN) { $envArgs += @('-e','GH_TOKEN') }
  if ($env:GITHUB_TOKEN) { $envArgs += @('-e','GITHUB_TOKEN') }

  $watchArgs = @('pwsh','-NoLogo','-NoProfile','-File','tools/Watch-OrchestratedRun.ps1','-RunId',"$RunId")
  if ($Repo) { $watchArgs += @('-Repo',"$Repo") }
  if ($PollSeconds -ne 15) { $watchArgs += @('-PollSeconds',"$PollSeconds") }
  if ($resolvedToken) { $watchArgs += @('-Token',$resolvedToken) }

  $cmd = @('docker','run','--rm','-v', $volumeSpec,'-w','/work') + $envArgs + @('mcr.microsoft.com/powershell:7.4-debian-12') + $watchArgs
  Write-Host ("[docker] watch-orchestrated`n`t{0}" -f ($cmd -join ' ')) -ForegroundColor Cyan
  & docker run --rm -v $volumeSpec -w /work @envArgs mcr.microsoft.com/powershell:7.4-debian-12 @watchArgs
  if ($LASTEXITCODE -ne 0) { throw "Watcher container exited with code $LASTEXITCODE" }
} finally {
  $env:GH_TOKEN = $restoreGh
  $env:GITHUB_TOKEN = $restoreGt
}

Write-Host 'Watcher run (in Docker) completed.' -ForegroundColor Green
