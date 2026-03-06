<!-- markdownlint-disable-next-line MD041 -->
# Certification Matrix (LabVIEW-on-docker)

This document defines how the release certification matrix is maintained for issue #711.
The matrix certifies critical hosted and self-hosted LabVIEW-on-docker lanes before stable
promotion.

## Source of truth

- Policy: `tools/policy/certification-matrix.json`
- Report schema: `docs/schemas/certification-matrix-v1.schema.json`
- Evaluator: `tools/priority/certification-matrix.mjs`
- Workflow gate: `.github/workflows/release.yml` (`certification-matrix` job)

## Gate semantics

- Release tags run the certification evaluator before publishing release assets.
- Channel inference:
  - `vX.Y.Z-rc.N` => `rc`
  - `vX.Y.Z` => `stable`
- Enforcement mode is `stable`:
  - RC: artifact is produced; drift/staleness is reported but does not block.
  - Stable: stale/incomplete/failed required lanes block release promotion.

## Lane contract

Each lane entry in `tools/policy/certification-matrix.json` contains:

- `id` (stable identifier used in evidence reports)
- `workflow` (workflow file id, for example `fixture-drift.yml`)
- `job_name` (exact GitHub Actions job display name)
- optional `branch` (`*`/`any` for all branches, otherwise an explicit branch)
- optional `event` (for example `pull_request`, `workflow_dispatch`)
- `runner`, `os`, `image_tag`, `scenario` (matrix metadata for certification evidence)
- optional `max_age_hours` (defaults to `defaults.max_age_hours`)
- optional `required_for_stable` (defaults to `true`)

## Add or remove lanes

1. Edit `tools/policy/certification-matrix.json`.
2. Keep `job_name` exact; do not use aliases or partial names.
3. Add/update scenario metadata (`runner`, `os`, `image_tag`, `scenario`).
4. Run local checks:

   ```bash
   node --test tools/priority/__tests__/certification-matrix.test.mjs
   node tools/priority/certification-matrix.mjs --repo <owner/repo> --channel rc --enforce none
   pwsh -NoLogo -NoProfile -File tools/Invoke-JsonSchemaLite.ps1 \
     -JsonPath tests/results/_agent/certification/certification-matrix.json \
     -SchemaPath docs/schemas/certification-matrix-v1.schema.json
   ```

5. Update this document if the matrix intent or gate semantics change.

## Artifact contract

Release runs emit:

- `tests/results/_agent/certification/release-certification-matrix.json`

The artifact is uploaded by the `certification-matrix` job and included in the release-contract
evidence bundle for traceability.
