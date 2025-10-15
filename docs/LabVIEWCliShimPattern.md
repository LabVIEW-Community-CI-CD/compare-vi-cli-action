# LabVIEW CLI Shim Pattern

**Version:** 1.0  
**Last updated:** 2025-10-14  
**Reference commit:** 9a3ee054e21157311443c134b9e7dece29f03ce4

This document defines the supported pattern for creating LabVIEW CLI shims that delegate to the shared abstraction shipped in `tools/LabVIEWCli.psm1`. Downstream tooling (including future SDKs) should implement shims by following this contract so behaviour remains consistent across repositories.

## Responsibilities

- Import `tools/LabVIEWCli.psm1` and rely on its provider resolution, parameter normalisation, and environment guards.
- Provider selection now includes both NI LabVIEW CLI (`labviewcli`) and g-cli (`gcli`). The abstraction chooses the first
  provider with a resolvable binary unless `LVCLI_PROVIDER` forces a specific implementation.
- Map legacy or convenience parameters to the canonical LabVIEW CLI operation schema rather than duplicating validation logic.
- Optionally override `LABVIEWCLI_PATH` for the duration of the call, restoring the original value afterwards.
- Invoke the appropriate exported function (`Invoke-LVOperation` or one of the typed helpers such as `Invoke-LVCreateComparisonReport`) and return its result.
- Surface warnings and errors emitted by the abstraction without rewriting diagnostic text.

## Reference Implementation

`tools/Close-LabVIEW.ps1` implements Shim Pattern v1.0. Key excerpts:

```powershell
Import-Module (Join-Path $PSScriptRoot 'LabVIEWCli.psm1') -Force

$params = @{}
if ($PSBoundParameters.ContainsKey('LabVIEWExePath')) { $params.labviewPath = $LabVIEWExePath }
if ($PSBoundParameters.ContainsKey('MinimumSupportedLVVersion')) { $params.labviewVersion = $MinimumSupportedLVVersion }
if ($PSBoundParameters.ContainsKey('SupportedBitness')) { $params.labviewBitness = $SupportedBitness }

$previousCliPath = $null
$cliPathOverride = $false
if ($PSBoundParameters.ContainsKey('LabVIEWCliPath') -and $LabVIEWCliPath) {
  $previousCliPath = [System.Environment]::GetEnvironmentVariable('LABVIEWCLI_PATH')
  [System.Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $LabVIEWCliPath)
  $cliPathOverride = $true
}

try {
  $result = Invoke-LVOperation -Operation 'CloseLabVIEW' -Params $params -Provider $Provider -Preview:$Preview
  # ...
} finally {
  if ($cliPathOverride) {
    [System.Environment]::SetEnvironmentVariable('LABVIEWCLI_PATH', $previousCliPath)
  }
}
```

Any new shim should adopt this structure: import the module, translate parameters, call the LabVIEW CLI abstraction, and clean up temporary overrides.

## Versioning

| Version | Date       | Commit                                  | Notes                            |
|---------|------------|-----------------------------------------|----------------------------------|
| 1.0     | 2025-10-14 | 9a3ee054e21157311443c134b9e7dece29f03ce4 | Initial definition and example.  |

When the pattern changes (for example, to support additional providers or expanded environment handling), increment the version, update this document, and annotate the affected shims with the new version number.
*** End Patch*** 
