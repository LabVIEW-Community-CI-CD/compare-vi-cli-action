<!-- markdownlint-disable-next-line MD041 -->
# DOTNET CLI Release Checklist

## Status

- Owner: CI/CD maintainers
- Tracking issue: [#171](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/171)
- Last updated: 2026-03-03

## Checklist

### Release identity

- [ ] SemVer tag selected and documented.
- [ ] Asset naming verified (`compare-vi-history-cli-win-x64-<version>.zip`).
- [ ] Build metadata (`version`, `commit`, `build timestamp`) validated in `--version` output.

### Artifact packaging

- [ ] CLI executable and required runtime files are included in the `.zip`.
- [ ] No container runtime dependency is required for host-native execution.
- [x] Summary JSON schema version is present and valid.
- [x] Image index JSON schema version is present and valid.

### Integrity and provenance

- [x] SHA-256 checksum file published for each release asset.
- [x] SBOM (`spdx` or equivalent) is published.
- [x] Provenance attestation is published and references source revision/workflow run.
- [x] Signing verification procedure is documented and reproducible.

### Contract compatibility

- [x] Output schema changes are additive for current major version.
- [x] Legacy output keys required by workflows remain available.
- [x] Exit classification behavior matches `REQ-DOTNET_CLI_RELEASE_ASSET` contract.

### Validation evidence

- [ ] `preflight` passes on a Windows host with LabVIEW 2026 installed.
- [ ] `compare single` pass-class and fail-class cases validated.
- [ ] `compare range` with `--max-pairs` truncation telemetry validated.
- [x] `report consolidate` artifact paths validated.
- [ ] `contracts validate` detects schema drift.

### Release notes

- [ ] Supported LabVIEW versions documented.
- [ ] Breaking/non-breaking contract changes documented.
- [ ] Upgrade and rollback instructions documented.

## Follow-up issue links

- [x] CLI skeleton and command adapters: [#173](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/173)
- [x] Schema/output contract adapters: [#174](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/174)
- [x] Release pipeline/signing/provenance:
  [#175](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/175)
- [x] Host-native validation harness: [#176](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/176)
