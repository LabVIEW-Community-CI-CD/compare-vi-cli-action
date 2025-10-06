<#
.SYNOPSIS
  Emit a small interactivity/console probe to the job Step Summary and stdout.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Line([string]$s){ $s | Out-Host }

$data = [ordered]@{}
$data.schema = 'interactivity-probe/v1'
$data.timestamp = (Get-Date).ToUniversalTime().ToString('o')
$data.os = [System.Environment]::OSVersion.VersionString
$data.userInteractive = [bool][System.Environment]::UserInteractive
$p = [System.Diagnostics.Process]::GetCurrentProcess()
$data.sessionId = $p.SessionId

try { $data.isInputRedirected  = [Console]::IsInputRedirected }  catch { $data.isInputRedirected  = $null }
try { $data.isOutputRedirected = [Console]::IsOutputRedirected } catch { $data.isOutputRedirected = $null }
try { $data.isErrorRedirected  = [Console]::IsErrorRedirected }  catch { $data.isErrorRedirected  = $null }

$likelyInteractive = $false
if ($data.userInteractive -and -not $data.isInputRedirected) { $likelyInteractive = $true }
$data.likelyInteractive = $likelyInteractive

$json = $data | ConvertTo-Json -Depth 4
Write-Line $json

if ($env:GITHUB_STEP_SUMMARY) {
  $lines = @('### Interactivity Probe','')
  $lines += ('- OS: {0}' -f $data.os)
  $lines += ('- SessionId: {0}' -f $data.sessionId)
  $lines += ('- UserInteractive: {0}' -f $data.userInteractive)
  $lines += ('- In/Out/Err redirected: {0}/{1}/{2}' -f $data.isInputRedirected,$data.isOutputRedirected,$data.isErrorRedirected)
  $lines += ('- LikelyInteractive: {0}' -f $data.likelyInteractive)
  $lines -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

