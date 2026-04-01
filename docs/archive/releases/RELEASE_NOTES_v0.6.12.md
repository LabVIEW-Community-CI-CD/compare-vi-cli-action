# Release Notes v0.6.12

`v0.6.12` is a maintenance release that carries the `v0.6.11` stable line
forward and fixes the Windows preflight process-capture seam exposed on the
Windows NI / LabVIEW Docker proof surface.

## Highlights

- The released backend now drains large Docker manifest output through a shared
  timeout-safe helper instead of risking a deadlock in the bounded preflight
  path.
- The stable release continues to use the Windows NI image-backed proof path as
  the authoritative hosted CI truth for VI-binary handling.
- The release is cut from the `v0.6.11` stable line, so it keeps the published
  VI-history Windows path repair, the Windows proof authority, and the repaired
  release-control-plane policy instead of regressing to the older `develop`
  release surfaces.

## Included maintenance slice

- `#2091` fix: repair Windows preflight process capture deadlock
- carry forward the `v0.6.11` stable-line Windows proof and release policy work

## Validation highlights

- `#2091` is green on the authoritative Windows NI proof lane before release
  preparation.
- The release branch is prepared from `release/v0.6.11` and carries only the
  Windows preflight helper repair plus the `0.6.12` release metadata update.
- Release helper docs, changelog, and version surfaces align on `0.6.12`.

## Consumer impact

- Stable consumers should move from `@v0.6.11` to `@v0.6.12` to pick up the
  Windows-proofed preflight repair.
- `comparevi-history` should repin `comparevi-backend-ref.txt` to `v0.6.12`
  before rerunning the clone-backed `ni/labview-icon-editor` proof on the
  released backend.
