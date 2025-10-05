#Requires -Version 7.0
<#!
.SYNOPSIS
  Install a Scheduled Task to run the Runner Invoker at user logon.
.DESCRIPTION
  Copies invoker scripts to C:\actions-runner\invoker and registers a task
  named 'RunnerInvoker' that launches the invoker pipe server at logon.
.PARAMETER PipeName
  Named pipe to bind. Default: lvci.invoker.
#>
[CmdletBinding()] param(
  [string] $PipeName = 'lvci.invoker'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dest = 'C:\actions-runner\invoker'
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }

$srcRoot = Join-Path $PSScriptRoot '.'
Copy-Item -LiteralPath (Join-Path $srcRoot 'RunnerInvoker.psm1') -Destination $dest -Force
Copy-Item -LiteralPath (Join-Path $srcRoot 'Start-RunnerInvoker.ps1') -Destination $dest -Force

$ps = (Get-Command pwsh).Source
$start = Join-Path $dest 'Start-RunnerInvoker.ps1'
$args = "-NoLogo -NoProfile -File `"$start`" -PipeName $PipeName"

$action   = New-ScheduledTaskAction -Execute $ps -Argument $args
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'RunnerInvoker' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Installed RunnerInvoker scheduled task (pipe '$PipeName')."

