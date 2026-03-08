<!-- markdownlint-disable-next-line MD041 -->
# Offline Real-History Corpus

This note defines the phase-2 contract for the offline real-history corpus
seeded by issues `#894` and `#895`.

## Checked-in inputs

- Target catalog: `fixtures/real-history/offline-corpus.targets.json`
- Catalog schema:
  `docs/schemas/offline-real-history-corpus-targets-v1.schema.json`
- Normalized committed subset:
  `fixtures/real-history/offline-corpus.normalized.json`
- Normalized corpus schema:
  `docs/schemas/offline-real-history-corpus-v1.schema.json`
- Run envelope schema:
  `docs/schemas/offline-real-history-corpus-run-v1.schema.json`
- Seed target: `icon-editor-settings-init`
  - repo slug: `svelderrainruiz/labview-icon-editor`
  - target VI:
    `resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi`
  - requested modes: `default`, `attributes`

The checked-in catalog is intentionally small. It captures the seed slice and
the storage policy, not bulky raw reports.

The normalized corpus file is also checked in. It is derived from the seed
fixture manifests plus any tiny checked-in capture summaries and carries the
deterministic review labels used for local regression tests:

- outcome labels: `clean`, `signal-diff`, `noise-diff`, `error`, `missing`
- mode sensitivity labels:
  `none-observed`, `single-mode-observed`,
  `all-observed-modes-clean`, `all-observed-modes-diff`,
  `mixed-observed-modes`
- coverage labels:
  `catalog-aligned`, `catalog-partial`, `catalog-extra`,
  `catalog-mismatch`

## Generated outputs

Offline corpus runs write under:

- `tests/results/offline-real-history/<target-id>/<run-id>/`

Each run directory contains:

- `offline-real-history-run.json`
  - schema: `vi-history/offline-real-history-run@v1`
  - records repo/ref selection, requested and executed modes, compare policy,
    NI image identity, LabVIEW version hint, CLI path, and output paths
- `history/`
  - aggregate `Compare-VIHistory` manifest
  - per-mode manifests
  - rendered `history-report.md` and `history-report.html`
  - translated `lvcompare-capture.json` files
  - raw `ni-windows-container-capture.json` files

Raw artifacts stay local under `tests/results/`; they are not committed to git.

## Harness

Entry point:

```powershell
node tools/npm/run-script.mjs history:corpus:offline -- --PlanOnly
```

Normalization refresh entry point:

```powershell
node tools/npm/run-script.mjs history:corpus:normalize
```

The harness:

1. Loads the checked-in target catalog.
2. Resolves a local external repo path from `-RepoPath` or the catalog's local
   path hints.
3. Reuses `Compare-VIHistory.ps1`.
4. Routes pair execution through
   `tools/Invoke-NIWindowsContainerCompareBridge.ps1`.
5. Emits the run envelope plus standard VI history outputs.

The bridge calls `tools/Run-NIWindowsContainerCompare.ps1` so history capture
uses the existing NI Windows container lane instead of a parallel compare path.

## Local refresh flow

Prerequisites:

- a local checkout of the external repo already exists
- the NI Windows image already exists locally
- Docker Desktop is running in Windows container mode

Plan without running the corpus:

```powershell
node tools/npm/run-script.mjs history:corpus:offline -- --PlanOnly --RunId plan-only
```

Run the seeded slice against an existing checkout:

```powershell
node tools/npm/run-script.mjs history:corpus:offline -- `
  --TargetId icon-editor-settings-init `
  --RepoPath ..\labview-icon-editor `
  --RunId local-smoke
```

Useful overrides:

- `-WindowsImage <tag>` to pin a different local NI Windows image
- `-WindowsLabVIEWPath <path>` to record a different in-container LabVIEW path
- `-WindowsCliPath <path>` to record a different in-container CLI path
- `-ComparePolicy <policy>` to annotate the capture envelope
- `-CompareTimeoutSeconds <n>` to raise or lower pair timeout

The harness does not clone or pull the external repository. Refresh is
explicitly local/offline once the repo and image already exist on disk.

The normalizer does not run LabVIEW or Docker. It rebuilds the checked-in
normalized subset from the catalog's `seedFixture.historySuitePath` entries and
any checked-in capture JSON summaries found under the referenced fixture roots.

## Storage boundary

- Commit:
  - the seed catalog
  - the normalized corpus subset
  - schemas for the catalog, normalized subset, and run envelope
  - tiny seed capture summaries that are intentionally curated for fixture
    lineage and regression coverage
- Keep local-only:
  - raw HTML/XML/text reports from offline refresh runs
  - translated capture JSON from generated runs
  - raw NI-container capture JSON from generated runs
  - stdout/stderr and per-run history bundles

That boundary keeps the repository deterministic while still preserving real
execution evidence on the operator machine.
