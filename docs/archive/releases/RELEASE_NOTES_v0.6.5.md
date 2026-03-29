<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.5

Highlights

- Guarded native compare runtime
  - `Invoke-CompareVI` now supports a bounded wait path for real LVCompare
    execution, and the composite action exposes it as
    `compare-timeout-seconds`.
  - Timed-out compares now fail deterministically with exit code `124` instead
    of leaving self-hosted lanes unbounded.
- Proven specialized workflow budget
  - `.github/workflows/labview-cli-compare.yml` now uses a `1200` second
    compare budget derived from real successful LV32 native compare runs.
  - The tuned workflow still reaches `Runner Unblock Guard` after the native
    compare step succeeds.
- Stable maintenance packet alignment
  - Stable entry docs, usage examples, active release helpers, and the
    follow-up tracker now align on `v0.6.5`.

Upgrade Notes

- `v0.6.5` is the supported stable backend pin that supersedes `v0.6.4`.
- Consumers do not need to use `compare-timeout-seconds` unless they want a
  bounded wait for self-hosted native compare execution.
- Use `v0.6.x-rc` tags only when deliberately evaluating a future release
  candidate.

Validation Checklist

- [ ] Published GitHub Release `v0.6.5` with CLI distribution assets for
      released platforms
- [ ] Published `SHA256SUMS.txt`
- [ ] Published `sbom.spdx.json`
- [ ] Published `provenance.json`
- [x] Manual native wrapper proof on `develop` succeeded before the release cut:
  - baseline run:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23716842026`
  - tuned timeout run:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23717187193`
- [ ] Full release compare view:
      `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/compare/v0.6.4...v0.6.5`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.5`
