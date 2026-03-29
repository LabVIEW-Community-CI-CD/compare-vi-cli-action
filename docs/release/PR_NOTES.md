<!-- markdownlint-disable-next-line MD041 -->
# Release v0.6.5 - PR Notes Helper

Reference sheet for the `v0.6.5` maintenance release. This cut publishes the
compare timeout guard and the verified native LV32 wrapper proof without
reopening the broader `v0.6.4` trust-reset scope.

## 1. Summary

Release `v0.6.5` focuses on four themes:

- **Guarded native compare runtime**: `Invoke-CompareVI` and the composite
  action now support `compare-timeout-seconds`, so self-hosted native compares
  can fail closed with exit code `124` instead of waiting indefinitely.
- **Proven workflow budget**: the specialized
  `.github/workflows/labview-cli-compare.yml` lane now uses a `1200` second
  timeout budget derived from a real successful runtime, not a guessed ceiling.
- **Live wrapper proof**: manual `labview-cli-compare` runs on `develop`
  completed successfully before and after the guard tuning, and the tuned run
  still reached `Runner Unblock Guard`.
- **Release packet alignment**: changelog, usage docs, release helpers, and
  archived notes now treat `v0.6.5` as the current stable maintenance target.

## 2. Maintenance Highlights

- The compare runtime now has an explicit bounded-wait path in
  `scripts/CompareVI.psm1` plus a public action input in `action.yml`.
- The specialized native LV32 wrapper workflow now protects the self-hosted
  runner from indefinite compare waits while still allowing the observed
  successful runtime envelope.
- Stable usage surfaces now pin `@v0.6.5`, so the published maintenance line
  matches the documented action contract.
- The release helper packet no longer carries the stale `v0.5.0` planning
  backlog in `POST_RELEASE_FOLLOWUPS.md`.

## 3. Validation Snapshot

- [ ] Release PR required contexts are `COMPLETED/SUCCESS`:
  - `lint`
  - `pester / normalize`
  - `smoke-gate`
  - `Policy Guard (Upstream) / policy-guard`
  - `commit-integrity`
- [x] Manual native wrapper proof on `develop` succeeded:
  - baseline run:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23716842026`
  - tuned timeout run:
    `https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/23717187193`
- [ ] `node tools/npm/run-script.mjs release:finalize -- 0.6.5` completes from
      a clean helper lane and writes fresh finalize metadata under
      `tests/results/_agent/release/`
- [ ] Published release `v0.6.5` includes the signed distribution assets,
      `SHA256SUMS.txt`, `sbom.spdx.json`, and `provenance.json`

## 4. Reviewer Focus

- Confirm the maintenance release surfaces align across:
  - `package.json`
  - `package-lock.json`
  - `Directory.Build.props`
  - `tools/CompareVI.Tools/CompareVI.Tools.psd1`
- Check that public entry docs and examples now point to the stable
  `v0.6.5` line instead of `v0.6.4`.
- Verify that the timeout guard is opt-in at the action layer and only
  specialized workflows consume it by default.
- Review the release helper packet for consistency:
  - `CHANGELOG.md`
  - `docs/release/TAG_PREP_CHECKLIST.md`
  - `docs/archive/releases/RELEASE_NOTES_v0.6.5.md`
  - `docs/release/POST_RELEASE_FOLLOWUPS.md`

## 5. Follow-Up After Stable

1. Re-pin certified downstream consumers to `v0.6.5` if they need the new
   timeout guard or the refreshed stable baseline.
2. Watch the first maintenance cycle for timeout regressions or
   `Runner Unblock Guard` noise before extending the same control to other
   self-hosted compare workflows.
3. Reopen runtime hardening only if live evidence shows another native compare
   lane can still strand the runner beyond the bounded budget.

--- Updated: 2026-03-29 (prepared for the `v0.6.5` maintenance cut).
