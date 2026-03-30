# Release Notes v0.6.9

`v0.6.9` is a maintenance release that repairs the published
`CompareVI.Tools` bundle so released VI-history downstreams can execute the
hosted NI Linux contract without a maintainer checkout.

## Highlights

- The published `CompareVI.Tools` archive now includes
  `tools/Get-LabVIEWContainerShellContract.ps1`, restoring the executable
  hosted NI Linux consumer contract in the released bundle.
- Release-time bundle certification now fails closed if the published archive
  omits the hosted NI Linux support scripts required by VI-history consumers.
- Maintainers now have a checked-in local Windows Docker replay for
  `vi-history-scenarios-windows`, keeping hosted-lane iteration faster without
  changing the meaning of the hosted certification proof.
- This cut is intentionally narrow. It repairs the released bundle contract and
  local replay ergonomics; it does not broaden the public VI-history product
  surface.

## Included maintenance slice

- `#2051` fix: ship complete NI Linux bundle contract
- `#2053` feat: replay vi-history Windows lane locally

## Validation highlights

- Release branch `release/v0.6.9` updates the stable backend version surfaces
  to `0.6.9`.
- Direct bundle proof validated the repair before publication:
  - extracted bundle contains both
    `tools/Run-NILinuxContainerCompare.ps1`
    and
    `tools/Get-LabVIEWContainerShellContract.ps1`
  - bundle certification summary reports `status: producer-native-ready`
- Post-publication coordination for this cut is explicit:
  - repin `comparevi-history` to `v0.6.9`
  - rerun the canonical `DrawIcon.vi` proof on the released backend
  - keep the public history surface constrained to characterization until the
    developer-decision proof is satisfied

## Consumer impact

- Stable consumers should move from `@v0.6.8` to `@v0.6.9` to pick up the
  repaired hosted NI Linux bundle contract.
- `comparevi-history` should treat `v0.6.9` as the minimum backend ref for the
  canonical `DrawIcon.vi` proof going forward.
