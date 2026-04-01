# Release Notes v0.6.10

`v0.6.10` is a maintenance release that promotes the Windows NI / LabVIEW
Docker proof authority path and the local-proof autonomy program onto the
stable line while carrying forward the release-control-plane repairs proven
during the `v0.6.9` publication.

## Highlights

- The hosted Windows NI image-backed proof is now the primary CI truth surface
  for VI-binary handling and workflow replay.
- The released baseline now includes the local-proof autonomy packets for
  Pester, VI History, and the shared Windows Docker surface, so maintainers can
  iterate locally against machine-readable next-step guidance before spending
  hosted CI.
- The layered Pester service-model control plane is now part of the released
  baseline: context, selection, readiness, execution, finalize, postprocess,
  and evidence are explicit receipts instead of one monolithic self-hosted
  transaction.
- The stable release control plane now matches the repaired policy:
  no green-dwell gate, queue health scoped to release-specific risk, protected
  replay after signed tag creation, and deferred exact-SHA downstream proving
  until `develop` realigns with the released source.

## Included maintenance slice

- `#2087` feat: promote local-proof autonomy packets and Windows staging contracts
- `#2088` ci: promote Windows NI proof authority and local proof autonomy
- release policy follow-on: carry stable release-conductor repairs and
  downstream-proof deferral onto `develop`

## Validation highlights

- Promoted `develop` tip includes both the integration-rail Windows proof work
  and the repaired release-control-plane logic.
- Windows proof, Pester service-model, release-conductor, and release workflow
  contract suites pass on the promoted release-cut surface.
- The `v0.6.9` replay on the repaired automation surface now finishes green
  end to end, proving the release scorecard no longer fails on impossible
  exact-SHA downstream selection during initial publication replay.

## Consumer impact

- Stable consumers should move from `@v0.6.9` to `@v0.6.10` to pick up the
  promoted Windows NI Docker proof authority and local-proof autonomy baseline.
- `comparevi-history` should treat `v0.6.10` as the minimum backend ref for
  the canonical released-backend proof going forward.
