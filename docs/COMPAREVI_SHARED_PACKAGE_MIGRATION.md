<!-- markdownlint-disable-next-line MD041 -->
# CompareVi.Shared Package-First Migration

This runbook defines the package-first cutover for `CompareVi.Shared` and the compatibility fallback behavior used by
`CompareVi.Tools.Cli`.

## Package-first contract

- Default source mode is `package-first` (`Directory.Build.props`).
- Compatibility fallback source is `project`.
- Resolution is deterministic in `Directory.Build.targets`:
  - use package when `CompareVi.Shared.<version>.nupkg` exists in `CompareViSharedPackageFeed`
  - otherwise fallback to `CompareViSharedFallbackSource`
- Effective mode can be inspected with:

```bash
dotnet msbuild src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj \
  -nologo -t:PrintCompareViSharedSource
```

## Downstream adoption (no source coupling)

Consumers that do not have `src/CompareVi.Shared` should pin package mode explicitly:

```bash
dotnet restore src/CompareVi.Tools.Cli/CompareVi.Tools.Cli.csproj \
  -p:CompareViSharedSource=package \
  -p:CompareViSharedPackageVersion=<x.y.z> \
  --source <nuget-feed-url>
```

Recommended settings:

- `CompareViSharedSource=package`
- `CompareViSharedPackageVersion=<published version>`
- `CompareViSharedPackageFeed=<optional local mirror>`

`package-first` remains available for repositories that keep both source and package lanes during migration.

## CI parity gate

`.github/workflows/dotnet-shared.yml` validates three lanes:

- `package-first` (expected resolved source: `package`)
- `package`
- `project`

All lanes run `version`, `tokenize`, and `procs` smoke checks to enforce behavior parity.

## Release cutover behavior

`tools/Publish-Cli.ps1` now:

- defaults to `CompareViSharedSource=package-first`
- prepares a local feed (`artifacts/shared-feed`) when needed
- emits `tests/results/_agent/release/shared-source-resolution.json`
- supports `-FailOnSharedFallback` to hard-fail if package resolution regresses to `project`

`release.yml` enforces this in the release job.

## Rollback playbook

If package resolution causes a blocking regression:

1. Switch source mode to `project` for the affected run:
   - local: `pwsh -File tools/Publish-Cli.ps1 -CompareViSharedSource project`
   - CI: set release invocation to project mode in workflow patch PR.
2. Re-run smoke checks and Validate.
3. Keep `package-first` default intact unless incident severity requires temporary policy rollback.
4. Open a remediation issue with:
   - `shared-source-resolution.json`
   - failing restore/build logs
   - package version + feed details.
