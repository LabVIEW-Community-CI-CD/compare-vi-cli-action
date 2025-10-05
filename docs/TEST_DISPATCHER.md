# Pester Summary JSON

The local dispatcher (`Invoke-PesterTests.ps1`) emits a machine‑readable summary for every run. Use it in CI and tooling instead of scraping console output.

## Where to find it

- Unit runs: `tests/results/pester-summary.json`
- Category runs (matrix): `tests/results/<category>/pester-summary.json`

## What it contains

- Totals: `total`, `passed`, `failed`, `errors`, `skipped`, `duration_s`
- Context: `includeIntegration`, optional discovery/context blocks depending on config

## Schemas

Schema files live under `docs/schemas/` and evolve with optional fields:

- Baseline: `docs/schemas/pester-summary-v1_1.schema.json`
- Current/rolling: `docs/schemas/pester-summary-v1_7_1.schema.json`

Validate with the lite helper:

```powershell
pwsh -NonInteractive -File tools/Invoke-JsonSchemaLite.ps1 `
  -JsonPath tests/results/pester-summary.json `
  -SchemaPath docs/schemas/pester-summary-v1_7_1.schema.json
```

## Producing a summary locally

```powershell
# Unit-only (no Integration)
./Invoke-PesterTests.ps1

# Include Integration
./Invoke-PesterTests.ps1 -IncludeIntegration true

# Filter by patterns
./Invoke-PesterTests.ps1 -IncludePatterns 'CompareVI*Tests.ps1'
```

In CI, the workflows append a concise summary to the job summary and upload artifacts.
