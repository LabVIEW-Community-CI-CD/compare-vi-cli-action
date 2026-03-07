<!-- markdownlint-disable-next-line MD041 -->
# DOTNET CLI Release Checklist

## Status

- Owner: CI/CD maintainers
- Tracking issue: [#854](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/854)
- Last updated: 2026-03-07

## Canonical release identity

- [ ] Release tag selected (`vX.Y.Z` or `vX.Y.Z-rc.N`).
- [ ] `package.json` version matches the release semver.
- [ ] `Directory.Build.props` `Version`, `AssemblyVersion`, and `FileVersion`
      match the release semver/core version.
- [ ] `CompareVI.Tools.psd1` `ModuleVersion` (and prerelease metadata, when
      used) matches the release semver.

## Stable backend surfaces

- [ ] `comparevi-cli` archives use the release tag as the stable pin.
- [ ] `comparevi-cli version` reports the same semver as the backend release.
- [ ] `CompareVi.Shared` package version matches the backend release semver.
- [ ] `CompareVI.Tools` bundle is published from the same source ref/tag as the
      CLI assets.
- [ ] Release notes call out stable versus rc expectations explicitly.

## Artifact packaging

- [ ] CLI assets are named with the current contract
      (`comparevi-cli-v<version>-<rid>-selfcontained.{zip|tar.gz}` and
      `comparevi-cli-v<version>-<rid>-fxdependent.{zip|tar.gz}`).
- [ ] `CompareVI.Tools-v<release-version>.zip` is published with
      `comparevi-tools-release.json`.
- [ ] No container runtime dependency is required for host-native CLI execution.
- [x] Summary JSON schema version is present and valid.
- [x] Image index JSON schema version is present and valid.

## Integrity and provenance

- [x] `SHA256SUMS.txt` is published for release assets.
- [x] SBOM (`spdx` or equivalent) is published.
- [x] Provenance attestation is published and references the source
      revision/workflow run.
- [x] Signing verification procedure is documented and reproducible.

## Contract compatibility

- [x] Output schema changes are additive for the current major version.
- [x] Legacy output keys required by workflows remain available.
- [x] Exit classification behavior matches the release asset contract.
- [ ] `CompareVI.Tools` metadata schema reflects any additive versioning fields.

## Validation evidence

- [ ] `tools/PrePush-Checks.ps1` passes on the release branch.
- [ ] `dotnet test src/CompareVi.Tools.Cli.Tests/CompareVi.Tools.Cli.Tests.csproj`
      passes on the release branch.
- [ ] `CompareVI.Tools` bundle certification records `default`, `attributes`,
      `front-panel`, and `block-diagram` without `Unspecified` category
      collapse.
- [ ] `compare range` real execution validation is recorded.
- [ ] `history run` real execution validation is recorded.
- [ ] `report consolidate` artifact-path validation is recorded.
- [ ] Release workflow/tag validation is recorded.

## Backend and facade coordination

- [ ] Release notes identify whether the backend release changes the facade
      contract consumed by `comparevi-history`.
- [ ] If the facade contract changed, the comparevi-history backend pin update is
      tracked and linked before calling the backend release complete.
- [ ] If a new stable facade release is required, that repo's smoke and release
      evidence are linked from the backend release plan.

## Release notes and plan

- [ ] Release notes describe the supported stable backend surfaces.
- [ ] Breaking or non-breaking contract changes are documented.
- [ ] Upgrade and rollback instructions are documented.
- [ ] The next stable backend release plan records the chosen coordination model
      for `comparevi-cli`, `CompareVi.Shared`, `CompareVI.Tools`, and the
      `comparevi-history` facade.

## Linked delivery issues

- [x] CompareVI.Tools immutable release artifact: [#845](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/845)
- [x] comparevi-cli real execution path: [#846](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/846)
- [ ] Backend release/version alignment: [#850](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/850)
