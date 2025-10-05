# Fixtures and Validator

This repository ships two canonical LabVIEW VIs at the root and a manifest that records their size and hash. Use these fixtures for smoke, examples, and local validation.

## Canonical VIs

- `VI1.vi` — base fixture
- `VI2.vi` — head fixture

Guidelines:

- Keep both files tracked in git and non‑trivial in size.
- Use only these canonical names; avoid legacy `Base.vi`/`Head.vi`.
- Document intentional changes in commit messages and regenerate the manifest.

## Manifest and Policy

- `fixtures.manifest.json` records `bytes` and `sha256` per VI.
- Update the manifest after intentional changes:

```powershell
pwsh -File tools/Update-FixtureManifest.ps1 -Allow
```

## Validator (tools/Validate‑Fixtures.ps1)

- Supports human and `-Json` output.
- Key exit codes:
  - `0` OK
  - `2` missing fixture
  - `3` untracked (not in git index)
  - `4` size mismatch
  - `5` multiple issue categories
  - `6` hash mismatch
  - `7` manifest error
  - `8` duplicate manifest entry

Examples:

```powershell
# Human summary
pwsh -NonInteractive -File tools/Validate-Fixtures.ps1 -MinBytes 32

# JSON (preferred for CI)
pwsh -NonInteractive -File tools/Validate-Fixtures.ps1 -Json -MinBytes 32 > fixture-validation.json
```

## CI Integration

- Fixture Drift workflow uses LVCompare to render a report when drift is detected.
- Required check suggestion: add “Fixture Drift (Windows)” as a protected check.
- See workflows overview for triggers and artifacts.

See also: `docs/WORKFLOWS_OVERVIEW.md`.
