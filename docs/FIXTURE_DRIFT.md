<!-- markdownlint-disable-next-line MD041 -->
# Fixture Drift & Manifest Refresh

Canonical fixtures (`VI1.vi`, `VI2.vi`) are tracked by `fixtures.manifest.json` (bytes + sha256).
The validator keeps fixtures deterministic and records auto-refresh events for review.

## Validator overview

- Run locally: `pwsh -File tools/Validate-Fixtures.ps1 -Json`
- Key exit codes: `0` ok, `4` size issue, `6` hash mismatch, `5` multiple issues
- JSON output includes `summaryCounts` and `autoManifest` block (`written`, `reason`, `path`)

When both fixtures change, the validator treats it as deterministic drift and writes a new
manifest (`autoManifest.written=true`).

## CI usage

The Fixture Drift workflow:

- Runs strict and override validations (`strict.json`, `override.json`)
- Notes manifest refreshes in the job summary when `autoManifest.written` is true
- Uploads the refreshed manifest as an artifact

CI can gate on non-zero exit code or inspect `autoManifest.written` to flag drift.

## Docker runtime manager contract

Fixture Drift now uses hosted Linux lanes only. The workflow keeps two Linux jobs:

- `Fixture Drift (Ubuntu)` for fixture validator drift checks.
- `NI Linux Container Compare (Hosted)` for NI Linux image parity evidence.

Linux container evidence is written under:

- `results/fixture-drift/ni-linux-container/**`
- Includes the review suite outputs (`history-report.md`, `history-report.html`,
  `history-summary.json`, and related inspection artifacts).

Quick local Linux bootstrap command:

```powershell
node tools/npm/run-script.mjs docker:ni:linux:bootstrap
```

## Manual manifest updates

For intentional fixture updates (outside automation):

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow
```

Include `[fixture-update]` in the commit message to acknowledge the change.

## Optional pair digest block

`fixtures.manifest.json` can include a deterministic `pair` block (schema `fixture-pair/v1`). It
captures the combined base/head digest and expected outcome.

Fields:

- `basePath`, `headPath`, `algorithm` (sha256)
- `canonical`, `digest`
- `expectedOutcome` (`identical`, `diff`, `any`)
- `enforce` (`notice`, `warn`, `fail`)

Inject locally:

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow -InjectPair `
  -SetExpectedOutcome diff `
  -SetEnforce warn
```

Validate with evidence:

```powershell
pwsh -File tools/Validate-Fixtures.ps1 -Json -RequirePair -FailOnExpectedMismatch `
  -EvidencePath results/fixture-drift/compare-exec.json
```

Evidence search order (when `-EvidencePath` omitted):

1. `results/fixture-drift/compare-exec.json`
2. Latest `tests/results/**/(compare-exec.json|lvcompare-capture.json)`

Outcome mapping: LVCompare exit code `0` → identical, `1` → diff, else `unknown` (or use the
`diff` boolean when available).
