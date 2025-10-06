Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Compatibility shim: import the CompareVI module so existing dot-source patterns keep working.
try {
  Import-Module (Join-Path $PSScriptRoot 'CompareVI.psm1') -Force
} catch {
  throw "Failed to import CompareVI.psm1: $($_.Exception.Message)"
}

