# Release Asset Verification

This document defines the verification flow for host-native `.NET` CLI release assets.

## Published Files

The release workflow publishes the following under `artifacts/cli` and attaches them to the GitHub release:

- `comparevi-cli-*.zip` / `comparevi-cli-*.tar.gz`
- `SHA256SUMS.txt`
- `sbom.spdx.json`
- `provenance.json`

## Verify Checksums

### Windows (PowerShell)

```powershell
$asset = 'comparevi-cli-v<version>-win-x64-selfcontained.zip'
$expected = (Get-Content SHA256SUMS.txt | Where-Object { $_ -match [regex]::Escape($asset) }).Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)[0].ToLowerInvariant()
$actual = (Get-FileHash -Algorithm SHA256 $asset).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "SHA256 mismatch for $asset" }
```

### Linux/macOS (bash)

```bash
asset='comparevi-cli-v<version>-linux-x64-selfcontained.tar.gz'
expected=$(awk -v file="$asset" '$2 ~ file {print tolower($1)}' SHA256SUMS.txt)
actual=$(sha256sum "$asset" | awk '{print tolower($1)}')
[ "$actual" = "$expected" ]
```

## Verify SBOM Presence

`sbom.spdx.json` is generated in SPDX 2.3 JSON format and should include:

- `spdxVersion = SPDX-2.3`
- package node for `comparevi-cli-release-assets`
- file-level SHA-256 checksums for published artifacts

## Verify Provenance Metadata

`provenance.json` uses schema `run-provenance/v1` and includes run identity (`runId`, `runAttempt`, `headSha`) plus
asset-level SHA-256 entries.

## Verify GitHub Artifact Attestation

The release workflow emits build provenance attestations with `actions/attest-build-provenance@v2`.
Use GitHub CLI to verify an artifact against the workflow identity:

```bash
gh attestation verify <asset-file> \
  --repo LabVIEW-Community-CI-CD/compare-vi-cli-action \
  --signer-workflow .github/workflows/release.yml
```

The verification must pass before promoting release artifacts.

## Automated trust gate

`Release on tag` enforces these checks through:

- `node tools/priority/supply-chain-trust-gate.mjs`
- report artifact: `tests/results/_agent/supply-chain/release-trust-gate.json`

The release fails closed if this gate reports any failure class.
