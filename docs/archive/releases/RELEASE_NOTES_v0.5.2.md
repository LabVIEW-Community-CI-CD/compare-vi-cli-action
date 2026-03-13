<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.2

Highlights

- History suite & telemetry
  - `tools/Compare-VIHistory.ps1` emits aggregate/per-mode manifests (`vi-compare/history-suite@v1`) with expanded
    Pester coverage and sample fixtures under `tools/dashboard/samples/ref-compare/history/`.
  - Dev Dashboard CLI/HTML/JSON renders history runs alongside session, watcher, and wait telemetry for local triage.
- Branch-policy guard & release automation
  - Validate job enforces branch-policy guard using `tools/priority/policy.json`; mergeability probe now runs before lint.
  - Release/feature branch helpers (`tools/priority/*`) automate version bumps, metadata capture, dispatch, and standing
    workflow management.
- Validate auto-publish & parity
  - `vi-compare-refs.yml` auto-publishes reference compare artifacts on green builds.
  - Docker tools parity workflow + knowledge base (`docs/knowledgebase/DOCKER_TOOLS_PARITY.md`) keep non-LV checks
    consistent across planes.
- Rogue cleanup & handoff hygiene
  - `tools/Detect-RogueLV.ps1` records process metadata, buffer calibration, and kill outcomes; handoff scripts emit
    richer watcher/rogue telemetry.
  - Docs refreshed (`AGENT_HANDOFF.txt`, `docs/plans/VALIDATION_MATRIX.md`, `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`)
    to reflect the new automation flow.

Upgrade Notes

- Consumers of history manifests should ingest the new aggregate/per-mode JSON outputs; Dev Dashboard sample data is
  included for quick validation.
- Release automation scripts require `GH_TOKEN`/`GITHUB_TOKEN` when pushing or dispatching; ensure branch-policy guard
  parity before use.
- Action inputs/outputs unchanged; new telemetry, manifests, and docs are additive.

Validation Checklist

- [ ] Pester (hosted Windows) unit tests green
- [ ] Pester (self-hosted Windows, IntegrationMode include) green with rogue guard summary clean
- [ ] Fixture Drift (Windows/Ubuntu) green; provenance comments updated
- [ ] Validate workflow: mergeability probe OK, branch-policy guard OK, docs link check OK
- [ ] `vi-compare-refs` auto-publish workflow green; artifacts uploaded for tag commit
- [ ] Dev Dashboard CLI/HTML rendering verifies history telemetry locally

Post-Release

- Tag v0.5.2 on `main` once required checks complete
- Monitor release workflows (`Validate`, `vi-compare-refs`, Docker parity) and Dev Dashboard ingestion
- Back-merge the release branch into `develop` and update follow-up tracking for history ingestion and parity coverage
