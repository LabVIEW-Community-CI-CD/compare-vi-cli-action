<!-- markdownlint-disable-next-line MD041 -->
# Release v0.5.2 - PR Notes Helper (Do Not Ship With Final Tag)

Reference sheet for refining the v0.5.2 release PR/description. Summarizes the major themes, validation expectations,
and follow-ups captured in #273.

## 1. Summary

Release v0.5.2 focuses on four pillars:

- **History suite & telemetry** — `tools/Compare-VIHistory.ps1` now emits aggregate/per-mode manifests, expanded Pester
  coverage validates the suite, and the Dev Dashboard CLI renders history data alongside session/wait telemetry.
- **Branch-policy guard & release automation** — Priority helpers under `tools/priority/*` enforce required checks,
  manage release/feature branch lifecycles, and capture metadata for standing-priority flows.
- **Validate auto-publish & parity** — `vi-compare-refs.yml` auto-uploads comparison refs; Validate runs mergeability
  probes + branch policy guard; Docker parity workflow and knowledge base keep non-LV checks consistent across planes.
- **Rogue cleanup & handoff hygiene** — Improved LabVIEW/LVCompare detection, buffer calibration, and richer handoff
  summaries keep self-hosted environments clean between runs.

## 2. History Suite Highlights

- New suite manifests (`vi-compare/history-suite@v1`) plus per-mode manifests recorded under
  `tools/dashboard/samples/ref-compare/history/`.
- `tests/CompareVIHistory.Tests.ps1` and `tests/CompareVI.History.Tests.ps1` exercise manifest production, diff handling,
  and Dev Dashboard ingestion.
- Dev Dashboard CLI (`tools/Dev-Dashboard.ps1`, `tools/Dev-Dashboard.psm1`) surfaces history suite telemetry in
  terminal/HTML/JSON outputs.
- Docs: `docs/DEV_DASHBOARD_PLAN.md`, `docs/test-requirements/vi-history-reporting.md`, and knowledge base notes cover
  expectations for history data consumers.

## 3. Branch-Policy Guard & Release Automation

- `tools/priority/policy.json` encodes required statuses; Validate job enforces guard via new step wiring.
- Release utilities (`release:branch`, `release:finalize`, `feature:*`, `priority:dispatch`) manage version bumps,
  metadata capture, and upstream pushes.
- Supporting tests (`tools/priority/__tests__/*`) keep release helpers deterministic.
- Docs refreshed: `docs/knowledgebase/FEATURE_BRANCH_POLICY.md`, `docs/plans/VALIDATION_MATRIX.md`, `AGENT_HANDOFF.txt`.

## 4. Validate Auto-Publish & Parity Workflows

- `vi-compare-refs.yml` publishes comparison refs on green builds; `node tools/npm/run-script.mjs priority:validate`
  dispatches Validate with guard checks.
- Mergeability probe (`tools/Check-PRMergeable.ps1`) runs before lint to fail conflicted PRs quickly.
- `tools/Run-NonLVChecksInDocker.ps1` and `.github/workflows/tools-parity.yml` provide Docker parity coverage (documented
  in `docs/knowledgebase/DOCKER_TOOLS_PARITY.md`).
- `docs/knowledgebase/VICompare-Refs-Workflow.md` explains the ref autopublish path and expectations.

## 5. Rogue Cleanup & Handoff Enhancements

- `tools/Detect-RogueLV.ps1` captures process command lines, timestamps, and kill attempts; new calibration helpers
  (`tools/Calibrate-LabVIEWBuffer.ps1`, `tools/Run-LocalBackbone.ps1`) tune cleanup windows.
- Handoff script updates (`tools/Print-AgentHandoff.ps1`, `AGENT_HANDOFF.txt`) ensure telemetry capsules and watcher data
  stay current.
- Session capsules, watcher summaries, and rogue detection results feed the Dev Dashboard for quick triage.

## 6. Upgrade Notes & Compatibility

- Downstream consumers should ingest the new history manifests (aggregate + per-mode) and adjust dashboards accordingly.
- Release automation scripts expect `GH_TOKEN`/`GITHUB_TOKEN` to be available and rely on branch-policy guard parity.
- `vi-compare-refs` autopublish workflow assumes hosted runners have LVCompare artifacts accessible; local parity helpers
  document prerequisites.
- Action inputs/outputs unchanged; additional telemetry and manifests are additive.

## 7. Validation Snapshot (goal = all checked before merge/tag)

- [ ] Validate workflow (mergeability probe, branch-policy guard, markdown/docs checks).
- [ ] `./Invoke-PesterTests.ps1` (unit surface) — expect PASS, session index uploaded.
- [ ] Self-hosted integration run (`./Invoke-PesterTests.ps1 -IntegrationMode include`) — ensure guard cleanup stays
      green and history suite tests pass.
- [ ] Fixture drift jobs (Windows + Ubuntu) — confirm size/bytes alignment and provenance comments.
- [ ] `vi-compare-refs` auto-publish workflow — artifacts uploaded and history suite manifests attached.
- [ ] Dev Dashboard CLI smoke (`pwsh -File tools/Dev-Dashboard.ps1 -Html`) — verify history telemetry renders.

## 7a. History Suite Validation Notes

- Confirm `tests/results/_agent/release/release-v0.5.2-*.json` capture branch/finalize metadata.
- Inspect generated history manifests under `tests/results/ref-compare-history/` for schema compliance and diff coverage.
- Exercise `tools/Compare-VIHistory.ps1` against sample refs and confirm exit codes/diff counts align.
- Ensure Dev Dashboard HTML/JSON outputs include history summary rows with actionable hints.

## 8. Risks & Mitigations

- **Risk:** Branch-policy guard misaligned with GitHub protection.
  - **Mitigation:** Keep `tools/policy/branch-required-checks.json` synced; rerun Validate guard after configuration
    changes.
- **Risk:** History manifests not ingested by dashboards.
  - **Mitigation:** Use sample fixtures + Dev Dashboard CLI to confirm format before tagging; update downstream parsers.
- **Risk:** Rogue cleanup regression on self-hosted runners.
  - **Mitigation:** Run calibration helpers when environment changes; monitor `Detect-RogueLV` summaries.
- **Risk:** Docker parity workflow lacks credentials.
  - **Mitigation:** Document GH token requirements; use tools image fallback when needed.

## 9. Follow-Up Work After v0.5.2

1. Extend history suite ingestion to production dashboards/metrics.
2. Broaden Docker parity coverage (macOS + additional containers).
3. Wire release automation into CI (auto-create release/feature branches on standing issues).
4. Continue refining Dev Dashboard rendering (interactive filtering, watcher aggregation).

## 10. Reviewer Notes

- Focus reviews on history suite manifest correctness, Dev Dashboard telemetry, branch-policy guard wiring, and release
  automation scripts.
- Verify `CHANGELOG.md`, `../archive/releases/RELEASE_NOTES_v0.5.2.md`, and README/docs align with shipped features.
- Double-check `docs/documentation-manifest.json` includes the new release docs.
- Ensure auto-publish workflows (`vi-compare-refs`) and Docker parity job stay green alongside traditional gates.

---

Updated: 2025-10-23 (aligns with the v0.5.2 release candidate).
