# CompareVi.Shared Library

A small .NET 8 class library providing shared helpers for LVCompare orchestration across repositories.

Contents

- ArgTokenizer: Tokenize quoted argument strings and normalize `-flag=value` pairs.
- PathUtils: Windows path normalization and safe quoting.
- ProcSnapshot: Capture LabVIEW/LVCompare process snapshots and close newly spawned LabVIEW PIDs.

Build

- Local: `pwsh -File tools/Build-Shared.ps1 -Pack`
- CI: `.github/workflows/dotnet-shared.yml` builds and uploads the `.nupkg` artifact when `src/**` changes.

Usage (PowerShell)

- Load the compiled assembly for experiments:

  ```powershell
  $dll = Join-Path $PWD 'src/CompareVi.Shared/bin/Release/net8.0/CompareVi.Shared.dll'
  Add-Type -Path $dll
  [CompareVi.Shared.ArgTokenizer]::Tokenize('"-flag value" -x=1 a b')
  ```

Roadmap

- Publish to GitHub Packages; add a PowerShell binary module wrapper for easy import.
- Gradual adoption in scripts (tokenization, path quoting, process cleanup) via thin adapters.
- Stabilize API, then consider NuGet release for broader reuse.

