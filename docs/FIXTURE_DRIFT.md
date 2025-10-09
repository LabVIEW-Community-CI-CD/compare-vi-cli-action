# Fixture Drift and Manifest Refresh

This repository tracks canonical fixtures (`VI1.vi`, `VI2.vi`) and a JSON manifest (`fixtures.manifest.json`) that records their `bytes` and `sha256`.

## Validator Behavior

- Run locally: `pwsh -File tools/Validate-Fixtures.ps1 -Json`

- Exit codes (subset):
  - `0` ok
  - `4` size issues (bytes mismatch or below fallback)
  - `6` hash mismatch
  - `5` multiple issues (combined)

- JSON fields include `summaryCounts` and an `autoManifest` block:
  - `autoManifest.written`: `true` when both fixtures changed (`hashMismatch >= 2`) and the manifest was automatically refreshed
  - `autoManifest.reason`: `hashMismatch>=2`
  - `autoManifest.path`: path to the written manifest

## Deterministic Flag

When both fixtures change together, the validator treats this as a deterministic drift signal and writes a new `fixtures.manifest.json`.

CI can gate on either:

- Non‑zero validator `exitCode`, or

- `autoManifest.written == true`

## CI Integration

The `Fixture Drift` composite action:

- Runs the validator in strict and override modes (`strict.json`, `override.json`).

- Appends a “Fixture Manifest Refresh” note to the job summary when `autoManifest.written` is true.

- Uploads the refreshed `fixtures.manifest.json` as an artifact for review.

## Updating the Manifest Intentionally

For intentional fixture updates (outside auto‑refresh):

- Regenerate locally: `pwsh -File tools/Update-FixtureManifest.ps1 -Allow`

- Commit with message containing `[fixture-update]` to acknowledge the change.

## Notes

- The manifest uses `bytes` (exact size) and `sha256` for integrity.

- CI retains the non-zero exit to keep drift visible; the summary and artifact help reviewers confirm expectations.

## Pair Digest & Expected Outcome (Optional)

The manifest can include a deterministic `pair` block (schema `fixture-pair/v1`) derived from the first `base` and `head` items. It helps detect stale manifests and verify that drift runs match the intended result.

- Fields: `basePath`, `headPath`, `algorithm=sha256`, `canonical`, `digest`, optional `expectedOutcome` (`identical|diff|any`), `enforce` (`notice|warn|fail`).
- Inject/refresh locally:

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow -InjectPair `
  -SetExpectedOutcome diff `
  -SetEnforce warn
```

- Validate in CI with drift evidence:

```powershell
pwsh -File tools/Validate-Fixtures.ps1 -Json -RequirePair -FailOnExpectedMismatch `
  -EvidencePath results/fixture-drift/compare-exec.json
```

Evidence resolution order (if `-EvidencePath` is omitted):

1. `results/fixture-drift/compare-exec.json`
2. Newest `tests/results/**/(compare-exec.json|lvcompare-capture.json)`

Outcome mapping: LVCompare exitCode `0 → identical`, `1 → diff`; otherwise `unknown` (or use the `diff` boolean when present).

