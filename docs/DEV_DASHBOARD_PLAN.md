# Local Telemetry Dashboard – Requirements & Test Plan

## Overview
A local developer dashboard will summarize telemetry from recent runs (session locks, Pester results, queue telemetry, logs) and surface stakeholder information so the right people can react quickly. The dashboard operates entirely from the workspace and produces terminal, HTML, or JSON output on demand.

> **Status (2025-10-07):** Phase 2 data loaders and the Phase 3 CLI/HTML/JSON outputs now live in `tools/Dev-Dashboard.psm1` and `tools/Dev-Dashboard.ps1`. Phase 5 added `tools/Invoke-DevDashboard.ps1`, workflow artifact uploads, queue-trend warnings (via `_agent/wait-log.ndjson`), and stakeholder DX links. Upcoming work focuses on HTML polish, richer watch-mode telemetry, and deeper action heuristics.

---

## Requirements

### Functional Requirements
1. **Data Collection**
   - Gather session-lock telemetry (`lock.json`, `status.md`) from `tests/results/_session_lock/<group>/`.
   - Read Pester results (`pester-summary.json`, `pester-results.xml`, `pester-dispatcher.log`) and report totals, failures, include patterns, and dispatcher exit code.
   - Parse Agent-Wait artefacts (e.g., `tests/results/_agent/wait-last.json`) to display queue durations and heartbeat information.
   - Parse queue-trend history from `_agent/wait-log.ndjson` (when present) to surface longest and tolerance-exceeded waits.
   - Parse Watch-Mode artefacts from `WATCH_RESULTS_DIR` (default `tests/results/_watch`):
     - `watch-last.json` with `timestamp`, `status`, `classification`, `stats.{tests,failed,skipped}`, `runSequence`, optional `flaky.recoveredAfter`.
     - `watch-log.ndjson` append-only history (blank-line separated JSON blocks).
   - Surface LabVIEW warm-up state by loading `tests/results/_warmup/labview-processes.json` (see [LabVIEW Runtime Gating](./LABVIEW_GATING.md)).
   - Support additional workflows (fixture drift, orchestrated) when lock artefacts exist, showing status if available.
   - Load stakeholder metadata from a configuration file (`tools/dashboard/stakeholders.json` or `.psd1`) mapping groups to primary/backup owners, communication channels, and DX issue numbers.
   - Provide per-section recommendations (e.g., how to inspect a lock or rerun tests) based on detected conditions (stale lock, TimeoutMinutes, etc.).

2. **Outputs**
   - Produce concise terminal output summarizing current branch/commit, session lock status, test results, queue telemetry, and recent logs with action items.
   - Optionally generate an HTML report (`tools/dashboard/dashboard.html`) mirroring the terminal sections with improved readability.
   - Optionally emit JSON (`-Json` flag) for automation or integration with other tools.

3. **Usage & Parameters**
   - CLI entry point `tools/Dev-Dashboard.ps1` accepting parameters:
     - `-Group <name>` (default `pester-selfhosted`).
     - `-Html` (generate HTML report).
     - `-Json` (output JSON data).
     - `-Watch <seconds>` (optional live-refresh loop).
   - Gracefully handle missing data files by reporting “not found” rather than failing.

4. **Stakeholder Surfacing**
   - Display primary and backup owners, optional communication channels, and link to DX issues for the selected session group in all outputs.
   - Fall back to “Stakeholders: not configured” when no mapping exists.

5. **Recommendations & Action Items**
   - Provide actionable hints per detected issue (e.g., inspect/takeover commands, rerun instructions).
   - Reference DX issue #99 or other relevant tracking items when requirements aren’t met.

### Non-Functional Requirements
- Operate fully offline using PowerShell 7 (no external dependencies).
- Run under StrictMode and fail fast on unexpected errors.
- Keep terminal output concise (< ~60 lines) with detailed information available via HTML.
- Execute quickly (< 2 seconds typical) by reading cached telemetry.
- Keep CI additions minimal (watch smoke is a single-run PASS test; typical < 3 seconds).
- Support both Windows and non-Windows environments (use `Join-Path`, no hard-coded separators).

### Stakeholder Configuration
- Configuration format (JSON/PSD1) must allow entries like:
  ```json
  {
    "pester-selfhosted": {
      "primaryOwner": "svelderrainruiz",
      "backup": "release-owner",
      "channels": ["slack://#ci-selfhosted"],
      "dxIssue": 99
    }
  }
  ```
- Dashboard must gracefully handle missing entries.

### Deliverables
1. Stakeholder configuration file (`tools/dashboard/stakeholders.json` or `.psd1`).
2. `tools/Dev-Dashboard.psm1` with data loaders and rendering helpers.
3. `tools/Dev-Dashboard.ps1` CLI script supporting terminal/HTML/JSON outputs.
4. HTML template or generator for the dashboard report.
5. Documentation updates (README, `SESSION_LOCK.md`) covering usage/examples.
6. Pester tests validating loader behaviour and rendering logic.

---

## Test Plan

### Scope
- **In scope:** session lock telemetry, Pester results, Agent-Wait data, stakeholder metadata, terminal/HTML/JSON rendering, CLI parameters, documentation alignment, DX issue references.
- **Out of scope:** remote telemetry aggregation, advanced visualization (charts).

### Test Environment
- PowerShell 7.x with access to repository workspace.
- Optional repo vars: `WATCH_SMOKE_ENABLE` gates orchestrated publish watch smoke; default off.

### Unit Tests (Pester)
- Session Lock Loader: status parse (queue wait, heartbeat age), takeover signals, missing files resilience.
- Stakeholder Mapping: renders DX issue links and channels; not configured path.
- Pester Summary Loader: totals, failures, dispatcher errors.
- Agent-Wait Loader: derives latest/longest waits and tolerance flags from `_agent/wait-log.ndjson`.
- Watch Loader: ingests `watch-last.json` and `watch-log.ndjson`; detects stalled loop (> 600s) and `worsened` trend.
- Action Items: assert presence of hints for stale/takeover, queue exceed/longest, watch stalled/worsened, DX link.

### CLI/Render Tests
- CLI JSON: snapshot includes `SessionLock`, `PesterTelemetry`, `AgentWait.History/Longest`, `WatchTelemetry.Last/History`.
- HTML: contains sections for Session Lock, Pester, Agent Wait, Watch Mode; renders watch summary and optional last-3 history rows.

### Workflow (CI) Tests
- Pester Reusable (self-hosted):
  - Executes watch single-run smoke with `WATCH_RESULTS_DIR=tests/results/_watch`.
  - Generates dev-dashboard HTML/JSON and uploads artifacts; step summary lists paths.
- Orchestrated (matrix/single) and Fixture Drift (Windows):
  - Generate and upload dev-dashboard artifacts per path; link from summaries.
- Optional: Orchestrated publish watch smoke guarded by `WATCH_SMOKE_ENABLE==1`.

### Acceptance Criteria
- Watch-mode outputs exist locally/CI when `WATCH_RESULTS_DIR` is set.
- Dashboard terminal/HTML/JSON display Watch Mode; action items appear for stalled/worsened/trend violations.
- Queue history parsed: tolerance-exceeded and longest>600s yield action items.
- All unit/CLI tests pass; actionlint remains green; additional CI time remains within bounds.
- Sample telemetry files under `tests/results/` (real or mocked).
- Stakeholder configuration populated with sample entries.

### Test Categories & Cases

#### 1. Unit Tests (Pester)
- **Session Lock Loader:** Validate parsed status (including queue wait, heartbeat age) and graceful handling when files missing.
- **Stakeholder Mapping:** Confirm correct merge of telemetry with owner/contact info.
- **Pester Summary Loader:** Ensure totals, include patterns, and dispatcher exit code extracted.
- **Agent-Wait Loader:** Verify queue duration and timestamps reported correctly.
- **Action Hint Generator:** Validate suggestions for stale lock takeover and TimeoutMinutes reruns.

#### 2. CLI Integration Tests
- **Terminal Output:** Run dashboard; confirm sections appear and stakeholders surfaced.
- **HTML Output:** Use `-Html`; confirm file created with all sections and owner info.
- **JSON Output:** Use `-Json`; validate schema/keys for downstream automation.
- **Missing Data Handling:** Remove files; ensure outputs show “not found” without crash.
- **Unknown Stakeholder:** Use group without config; expect fallback message.
- **Watch Mode (optional):** Run with `-Watch` to ensure periodic refresh works and can be terminated cleanly.

#### 3. Manual Validation
- **Standard Run:** After a successful local run, execute dashboard; capture terminal + HTML outputs showing `Status: released` and queue details.
- **Queued Run:** Simulate active lock before running; ensure dashboard shows queue wait and owner guidance.
- **Stale Lock:** Modify heartbeat to be stale; verify action hints referencing takeover/cleanup.
- **TimeoutMinutes Failure:** Inject known error into dispatcher log; confirm recommended rerun steps appear.
- **Fixture Drift Group:** Provide lock sample for fixture drift; ensure owner mapping displayed when run with `-Group fixture-drift`.
- **Stakeholder Coverage:** For each configured group, validate that owners, backup, channels, and DX issue references render correctly.
- **Documentation:** Ensure README/`SESSION_LOCK.md` instructions match actual CLI usage and outputs.

#### 4. Regression
- Verify existing scripts (session lock utility, workflows) still operate without invoking dashboard.
- Re-run `./Invoke-PesterTests.ps1` to ensure no broader pipeline regressions.

### Test Data
- Provide mock telemetry samples in `tools/dashboard/samples/` (lock.json, pester summary, stakeholders config) for reproducible tests.

### Reporting
- Record unit/integration results (Pester output) and attach manual validation evidence (screenshots or logs).  
- Note findings or follow-up tasks on GitHub issue #99.

### Exit Criteria
- All unit and integration tests pass.
- Manual scenarios (acquired, queued, stale, failure) verified.
- Documentation updated with accurate commands and screenshots if possible.
- DX issue #99 requirements satisfied (summary block, artifact exposure, inspect guidance, optional helper considered).

---

With these requirements, tests, and the implementation roadmap, the dashboard will deliver a consistent, stakeholder-aware view of local telemetry, reinforcing the developer experience improvements we’re tracking in issue #99.

---

## Implementation Plan

### Phase 1 – Foundations & Configuration
1. **Stakeholder Mapping**
   - Create `tools/dashboard/stakeholders.json` (or `.psd1`) with entries for each session group (e.g., `pester-selfhosted`, `fixture-drift`).
   - Include `primaryOwner`, `backup`, `channels`, and `dxIssue` fields.
   - Seed with sample contacts for testing.
2. **Sample Telemetry**
   - Under `tools/dashboard/samples/`, place representative files:
     - `lock.json` and `status.md` (with queue wait, heartbeat).
     - `pester-summary.json`, `pester-dispatcher.log`.
     - `wait-last.json` (Agent-Wait sample).
   - Document dataset so tests know where to load from.
3. **Module Skeleton (`Dev-Dashboard.psm1`)**
   - Define stub loader functions (`Get-SessionLockStatus`, `Get-PesterTelemetry`, etc.) returning empty placeholders.
   - Export functions via `Export-ModuleMember` to lock in structure.

### Phase 2 – Data Loaders & Logic
4. **Session Lock Loader**
   - Implement `Get-SessionLockStatus` to read lock files, compute queue wait/heartbeat age, handle missing data gracefully.
5. **Pester Telemetry Loader**
   - Implement `Get-PesterTelemetry` to parse summary, results XML (if needed), and dispatcher exit code.
6. **Agent Wait Loader**
   - Implement `Get-AgentWaitTelemetry` using Agent-Wait artefacts.
7. **Stakeholder Resolver**
   - Implement `Get-StakeholderInfo` to merge session group with stakeholder config (fallback when absent).
8. **Action Item Engine**
   - Implement `Get-ActionItems` to produce recommendations (inspect, takeover, rerun) based on telemetry and stakeholder info.

### Phase 3 – CLI & Rendering
9. **CLI Script (`Dev-Dashboard.ps1`)**
   - Parse parameters `-Group`, `-Html`, `-Json`, `-Watch`.
   - Invoke loaders; build dashboard object.
   - Render terminal summary with sections (header, session lock, tests, queue, logs, actions) highlighting stakeholders and DX issue.
10. **HTML Renderer**
   - Generate `tools/dashboard/dashboard.html` mirroring terminal sections with inline CSS.
11. **JSON Output**
   - Emit JSON when `-Json` flag set.
12. **Watch Mode (Optional)**
   - Implement `-Watch <seconds>` to refresh telemetry in loop with clean exit on Ctrl+C.

### Phase 4 – Testing
13. **Unit Tests**
   - Add `tests/DevDashboard.Tests.ps1` covering loaders, action items, and error handling with sample data.
14. **Integration Tests**
   - Execute CLI via Pester (mock data) verifying terminal/HTML/JSON outputs.
15. **Regression**
   - Run `./Invoke-PesterTests.ps1` to ensure new tests integrate without regressions.

### Phase 5 – Workflow Integration & Documentation
16. **Workflow Artefact Updates**
   - Ensure session-lock artefacts (`lock.json`, `status.md`) are included in workflow uploads or document where they reside.
   - Optionally reference dashboard command in summary output.
17. **Documentation**
   - Update README and `SESSION_LOCK.md` with dashboard usage, sample output, stakeholder config instructions, and references to DX issue #99.
18. **Manual Validation**
   - Run real scenarios (standard run, queued run, stale lock, TimeoutMinutes) capturing terminal + HTML outputs and verifying stakeholder surfacing.

### Phase 6 – Finalization
19. **Cleanup & Polish**
   - Ensure generated artefacts (HTML/JSON) are ignored or clearly documented.
   - Double-check StrictMode/PS7 compatibility.
   - Confirm this document (`docs/DEV_DASHBOARD_PLAN.md`) and `docs/SESSION_LOCK_HANDOFF.md` reflect latest information.
20. **Issue Tracking**
   - Update issue #99 with completion notes once requirements satisfied.
21. **Merge Preparation**
   - Run full test suite.
   - Prepare PR summarizing changes, requirements fulfilment, and test results.
   - Attach sample outputs (terminal/HTML) to PR for reviewer context.

---

**Related Documents**
- [Session Lock Handoff](./SESSION_LOCK_HANDOFF.md) – current implementation state and outstanding guard tasks.
- GitHub Issue [#99](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/99) – DX tracking for session lock visibility and inspection.

With the requirements, test plan, and implementation roadmap consolidated here, the dashboard can be developed methodically while aligning with our developer-experience goals.***
