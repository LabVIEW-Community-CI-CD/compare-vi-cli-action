#Requires -Version 7.0
param([string]$PipeName = 'lvci.invoker')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mod = Join-Path $PSScriptRoot 'RunnerInvoker.psm1'
Import-Module $mod -Force
Start-RunnerInvokerServer -PipeName $PipeName

