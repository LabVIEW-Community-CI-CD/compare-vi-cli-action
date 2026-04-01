# Release Notes v0.6.11

`v0.6.11` is a maintenance release that carries the `v0.6.10` stable line
forward and fixes the backend-side VI-history native-path seam exposed on the
Windows NI / LabVIEW Docker proof surface.

## Highlights

- The released backend now preserves repository-relative VI-history targets
  across ref extraction, compare staging, and report rendering on the Windows
  NI proof surface.
- The stable release continues to use the Windows NI image-backed proof path as
  the authoritative hosted CI truth for VI-binary handling.
- The release is cut from the `v0.6.10` stable line, so it keeps the promoted
  Windows proof authority, local-proof autonomy packet, and repaired
  release-control-plane policy instead of regressing to the older `develop`
  release surfaces.

## Included maintenance slice

- `#2089` fix: normalize VI-history paths on Windows proof surfaces
- carry forward the `v0.6.10` release-line policy and Windows NI proof work

## Validation highlights

- `#2089` is green on the authoritative Windows NI proof lane and the hosted
  VI-history scenario lane before release preparation.
- The release branch is prepared from `release/v0.6.10` and merged with the
  post-`#2089` `develop` tip, preserving the already-published release-line
  fixes while adding the VI-history backend repair.
- Release helper docs, changelog, and version surfaces align on `0.6.11`.

## Consumer impact

- Stable consumers should move from `@v0.6.10` to `@v0.6.11` to pick up the
  Windows-proofed VI-history backend repair.
- `comparevi-history` should repin `comparevi-backend-ref.txt` to `v0.6.11`
  before rerunning the clone-backed `ni/labview-icon-editor` proof on the
  released backend.
