Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compatibility shim: import the Ensure-LVCompareClean module so dot-sourcing keeps working
try {
  Import-Module (Join-Path $PSScriptRoot 'Ensure-LVCompareClean.psm1') -Force
} catch {
  throw "Failed to import Ensure-LVCompareClean.psm1: $($_.Exception.Message)"
}

