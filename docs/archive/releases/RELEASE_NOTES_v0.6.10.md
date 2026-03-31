# Release Notes v0.6.10

`v0.6.10` is the first stable cut that carries the post-`v0.6.9` VI-history
product work: chronology-aware decision guidance, the self-hosted Windows proof
split, and the Docker-override/runtime fixes that keep the canonical proof
reproducible on this machine.

## Highlights

- The VI-history report now preserves touch-history chronology and tells the
  developer which pair to inspect first instead of hiding the newest meaningful
  change behind collapsed report noise.
- Windows proofing now uses the intended split architecture:
  `vi-history-scenarios-windows` proves the 64-bit Windows Docker lane on the
  ingress host, while `vi-history-scenarios-windows-lv32` runs in parallel as
  the native 32-bit reference.
- The NI Linux proof tooling and local fast loop now honor
  `DOCKER_COMMAND_OVERRIDE`, keeping WSL-hosted `docker.exe` and wrapper-based
  runtimes deterministic during canonical proof replay.
- This cut supersedes the unpublished `v0.6.9` draft. It is the first stable
  release that combines the bundle-contract recovery work with the merged
  product-semantic history improvements.

## Included maintenance slice

- `#2056` feat: use touch-history semantics in VI history proofs
- `#2057` fix: preserve VI history category specificity
- `#2058` feat: reveal collapsed VI history pairs
- `#2059` docs: clarify VI history decision guidance
- `#2060` fix: make LV32 shadow proof non-blocking
- `#2061` feat: identify latest VI history signal pair
- `#2062` feat: add VI history review sequence guidance
- `#2063` feat: expose VI history decision chronology
- `#2065` feat: run Windows VI history proof on self-hosted ingress
- `#2066` fix: honor docker override across NI Linux proof tooling

## Validation highlights

- Release branch `release/v0.6.10` updates the stable backend version surfaces
  to `0.6.10`.
- The merged-state canonical proof succeeded for:
  - target:
    `Tooling/deployment/VIP_Pre-Install Custom Action.vi`
  - outcome:
    3 comparisons, 2 signal diffs, 1 collapsed noise
  - decision statement:
    newest VI touch is metadata-only; review starts at pair 2 for the newest
    meaningful functional change
- The self-hosted Windows planner contract was re-proved after the split:
  - the 64-bit Docker lane resolves through the self-hosted ingress inventory
  - the LV32 lane resolves in parallel as the native reference
  - planner regressions for the empty health-receipt binding path now fail
    closed in focused tests

## Consumer impact

- Stable consumers should move from `@v0.6.8` to `@v0.6.10`.
- `comparevi-history` should treat `v0.6.10` as the minimum backend ref for the
  canonical `VIP_Pre-Install Custom Action.vi` proof going forward.
- The GitLab benchmark should only refresh after the canonical proof is rerun on
  the published `v0.6.10` backend ref, not on the merged-state maintainer
  override.
