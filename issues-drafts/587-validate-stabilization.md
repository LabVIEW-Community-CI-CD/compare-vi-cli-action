# Issue #587 – Validate / Icon-Editor Stabilization

## Context
- Hooks now preserve `tests/results/_agent/icon-editor/fixture-report.json` (Stage-BuildArtifacts copy + pre-push env flag).
- Markdown tidy-up + new unit coverage committed in `issue/575-vi-compare-report`.
- Validate run `19054554825` dispatched with a unique `sample_id`; earlier runs cancelled due to concurrency and lint failures.
- Repo variables currently force the icon-editor build job into simulation and limit the compare matrix to Windows.

## Task Backlog
- [ ] **Monitor run `19054554825`** – collect job results/logs, confirm hook parity + lint + simulated build succeed.
- [ ] **Capture regression log summary** – drop watcher/Validate notes under `tests/results/_agent/` once the run completes.
- [ ] **Assess simulation artifacts** – confirm `package-smoke-summary.json`, manifest, and diff requests match expectations.
- [ ] **Plan real-package handoff** – outline steps to stage fresh VIP/lvlibp artifacts and switch `ICON_EDITOR_BUILD_MODE` back to `build`.
- [ ] **Restore Linux lane** – once build mode is real again, expand `ICON_EDITOR_COMPARE_POOLS` to reintroduce the Linux self-hosted runner.
- [ ] **Update #575/#587** – comment on both issues once Validate is green, documenting the follow-through and any lingering risks.

## Notes / Open Questions
- Do we need additional automation to ensure fixture reports remain available when Stage-BuildArtifacts is extended?
- When real packages return, confirm `Test-IconEditorPackage.ps1` still runs before enabling the Linux lane.
