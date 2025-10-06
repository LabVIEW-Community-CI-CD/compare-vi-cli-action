Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { Import-Module (Join-Path $PSScriptRoot 'ConsoleWatch.psm1') -Force } catch { throw "Failed to import ConsoleWatch.psm1: $($_.Exception.Message)" }
