# CompareVi.Shared Library

![Build](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/dotnet-shared.yml/badge.svg)

A small .NET 8 class library providing shared helpers for LVCompare orchestration across repositories.

Contents
- ArgTokenizer: Tokenize quoted argument strings and normalize `-flag=value` pairs.
- PathUtils: Windows path normalization and safe quoting.
- ProcSnapshot: Capture LabVIEW/LVCompare process snapshots and close newly spawned LabVIEW PIDs.

Build
- Local: `pwsh -File tools/Build-Shared.ps1 -Pack`
- CI: `.github/workflows/dotnet-shared.yml` builds and uploads the `.nupkg` artifact when `src/**` changes.

GitHub Packages (after first publish)
- Add GitHub Packages source (requires a PAT with read:packages):
  ```bash
  dotnet nuget add source "https://nuget.pkg.github.com/LabVIEW-Community-CI-CD/index.json" \
    --name github --username YOUR_GH_USER --password YOUR_GH_PAT --store-password-in-clear-text
  ```
- Install:
  ```bash
  dotnet add package CompareVi.Shared --version 0.1.0
  ```

Usage (PowerShell)
- Load the compiled assembly for experiments:
  ```powershell
  $dll = Join-Path $PWD 'src/CompareVi.Shared/bin/Release/net8.0/CompareVi.Shared.dll'
  Add-Type -Path $dll
  [CompareVi.Shared.ArgTokenizer]::Tokenize('"-flag value" -x=1 a b')
  ```

Manual Consumer Test
- Run the ad-hoc verification workflow in Actions:
  - .NET Consumer Test (Manual) → provide version (e.g., 0.1.0) or leave blank for latest
  - Direct link: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/workflows/dotnet-consumer-test.yml

Roadmap
- Publish to GitHub Packages; add a PowerShell binary module wrapper for easy import.
- Gradual adoption in scripts (tokenization, path quoting, process cleanup) via thin adapters.
- Stabilize API, then consider NuGet release for broader reuse.
