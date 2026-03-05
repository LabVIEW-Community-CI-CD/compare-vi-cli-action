# VIPM Provider & Performance Comparison Plan

## Milestone 1 – Provider scaffolding
- [ ] Create `tools/providers/vipm/Provider.psm1` exposing a `New-VipmProvider` factory.
- [ ] Implement path resolution (environment overrides + configs) and a minimal `Supports()` set (`InstallVipc`, `BuildVip`).
- [ ] Add `tools/Vipm.psm1` hub (akin to `GCli.psm1`) with `Get-VipmInvocation` and provider registration.
- [ ] Unit tests for argument translation and path resolution.

## Milestone 2 – Integrate with existing flows
- [x] Refactor icon-editor build tooling (`Invoke-IconEditorBuild.ps1`, package scripts) to call the VIPM provider.
- [x] Replace remaining hard-coded VIPM launches in `.github/actions/*` with provider invocations.
- [x] Ensure provider gracefully falls back / surfaces actionable errors when VIPM is missing.
- [x] Extend targeted tests to exercise provider-backed install paths.

## Milestone 3 - Dual-provider comparison harness
- Scenario matrix:
  * **InstallVipc** on the canonical `runner_dependencies.vipc` (2021 x32/x64, 2025 x64) to exercise multi-version apply flows.
  * **BuildVip** against a small fixture `.vipb` (e.g., simulated icon-editor package) so we can diff package output and timing.
  * Optional future add-on: feed toggles or cache flush commands once base coverage is stable.
- Harness design:
  * New script `tools/Vipm/Invoke-ProviderComparison.ps1` accepts a JSON/hashtable matrix describing scenarios and provider list (`gcli`, `labviewcli`).
  * For each scenario/provider pair, call `Get-VipmInvocation`, execute the command, and capture telemetry (wall-clock duration, exit code, stdout/stderr warnings, artifact checksums).
  * Append results to `tests/results/_agent/vipm-provider-matrix.json` (append mode, schema: scenario, provider, metrics, timestamp, status); ensure sensitive env data is omitted.
  * Emit a compact summary table (stdout + optional Markdown) so CI and humans can spot regressions quickly.
- Metrics to record:
  * Duration (`Stopwatch`), exit code, warning count/messages, artifact SHA256, provider binary path.
- Safety/guardrails:
  * Honour `VIPM_PROVIDER_COMPARISON=skip` (or reuse `ICON_EDITOR_BUILD_MODE=simulate`) to bypass heavy scenarios locally.
  * Fail fast with helpful hints if a provider is unavailable and log fallback state in the telemetry file.
- [x] Define shared scenarios (apply `.vipc`, build `.vipb`, optional feed toggle) and parameter fixtures.
- [x] Implement comparison script (or Pester integration test) that runs each scenario through both g-cli and LabVIEWCLI backends, capturing duration, exit code, warnings, and artifact hashes.
- [ ] Emit results to `tests/results/_agent/vipm-provider-matrix.json` (append mode) with run metadata.
- [x] Add assertions that artifacts match and warn on provider capability gaps (validation script + Pester tests; integrate into CI pipeline).

## Milestone 4 - CI & telemetry and release cutover
- [ ] Wire an optional CI job (nightly / on-demand) to execute the comparison harness and publish metrics artifacts.
- [ ] Add README/docs entry describing provider selection, requirements, and how to trigger the comparison locally (`node tools/npm/run-script.mjs vipm:compare` or VS Code task).
- [ ] Monitor early runs; set simple thresholds (e.g., flag if provider B is >20% slower or fails).
- [ ] Tag and publish the next release once full validation (Validate / lint + Pester) passes with providers integrated.
- [ ] Port the provider stack to the upstream icon-editor repository and cut the matching release there once the action completes its rollout.

## Milestone 5 – Stretch goals
- [ ] Expand provider API for advanced VIPM operations (feed management, cache pruning).
- [ ] Consider caching/stubbing for offline tests to keep the suite fast.
- [ ] Optional: surface metrics in dashboards or summarize in session index for future agents.
