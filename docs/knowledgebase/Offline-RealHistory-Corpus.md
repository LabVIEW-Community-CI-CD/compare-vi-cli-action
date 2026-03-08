<!-- markdownlint-disable-next-line MD041 -->
# Offline Real-History Corpus

This note defines the phase-1 contract for the offline real-history corpus
seeded by issue `#894`.

## Checked-in inputs

- Target catalog: `fixtures/real-history/offline-corpus.targets.json`
- Catalog schema:
  `docs/schemas/offline-real-history-corpus-targets-v1.schema.json`
- Run envelope schema:
  `docs/schemas/offline-real-history-corpus-run-v1.schema.json`
- Seed target: `icon-editor-settings-init`
  - repo slug: `svelderrainruiz/labview-icon-editor`
  - target VI:
    `resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi`
  - requested modes: `default`, `attributes`

The checked-in catalog is intentionally small. It captures the seed slice and
the storage policy, not bulky raw reports.

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

## Storage boundary

- Commit: the seed catalog and schemas
- Keep local-only: raw HTML/XML/text reports, translated capture JSON, raw
  NI-container capture JSON, stdout/stderr, and per-run history bundles

That boundary keeps the repository deterministic while still preserving real
execution evidence on the operator machine.
