<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.3

Highlights

- comparevi-cli advanced command graduation
  - `compare range`, `history run`, and `report consolidate` now execute the
    real CompareVI PowerShell backend instead of contract-only dry shims.
  - The CLI materializes versioned summary JSON, Markdown, HTML, image-index,
    and run-log artifacts in `--out-dir`, while preserving the existing
    pass-class/fail-class outcome envelope.
  - Backend parity coverage now lives in
    `src/CompareVi.Tools.Cli.Tests/RealExecutionParityTests.cs`, covering:
    - `compare range` against `Get-PRVIDiffManifest.ps1` +
      `Invoke-PRVIHistory.ps1`
    - `history run` against `Invoke-PRVIHistory.ps1`
    - `report consolidate` against wrapped `Compare-VIHistory.ps1` output

Upgrade Notes

- `--dry-run` still emits the contract-only lane payload and remains the safest
  way to exercise downstream JSON parsing without invoking LVCompare/history
  orchestration.
- Stable backend pin: release tag `v0.6.3` is the supported identity for the
  backend surfaces shipped from this repository:
  - `comparevi-cli` archives and `comparevi-cli version`
  - `CompareVi.Shared`
  - `CompareVI.Tools`
- Real execution now requires access to the CompareVI helper scripts. In a full
  repository checkout this resolves automatically; extracted/bundled layouts can
  set `COMPAREVI_CLI_SCRIPTS_ROOT` (or `COMPAREVI_SCRIPTS_ROOT`) to the helper
  root.
- Local validation and automated tests can override the compare invoker with
  `COMPAREVI_CLI_INVOKE_SCRIPT_PATH` while keeping the command contract stable.
- `comparevi-history` remains a separately versioned facade. Backend `v0.6.3`
  compatibility for that facade is established by its pinned backend ref and its
  own release process, not by assuming identical semver across repos.

Validation Checklist

- [x] `dotnet test src/CompareVi.Tools.Cli.Tests/CompareVi.Tools.Cli.Tests.csproj -c Debug --filter RealExecutionParityTests`
- [x] `dotnet test src/CompareVi.Tools.Cli.Tests/CompareVi.Tools.Cli.Tests.csproj -c Debug --filter PhaseOneCommandContractsTests`
- [ ] Full CLI + repository validation (`tools/PrePush-Checks.ps1`)
- [ ] Hosted workflow validation on release branch/tag
