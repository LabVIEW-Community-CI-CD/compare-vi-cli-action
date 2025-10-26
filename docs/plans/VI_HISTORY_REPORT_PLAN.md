# VI history compare report plan

This plan captures the requirements, data contract, and execution outline for issue
[#319](https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/319). The goal is to deliver a
single, consumable report for VI history comparisons that works locally and in CI without regressing the existing
automation.

## Goals

- Present commit-by-commit history comparisons in one document so reviewers avoid spelunking through JSON manifests.
- Highlight per-mode coverage (default, attributes, block-diagram, etc.), the diff counts, and quick links to LVCompare
  artifacts when differences exist.
- Stay lightweight enough for PR comments and CI step summaries while keeping a richer HTML version for local use.
- Preserve the existing `vi-compare/history-*` manifests as the source of truth; the report renderer consumes them
  without altering the capture pipeline.

## Current behaviour

- `tools/Compare-VIHistory.ps1` emits:
  - Aggregate suite manifest (`tests/results/ref-compare/history/manifest.json`, schema `vi-compare/history-suite@v1`).
  - Per-mode manifests under `.../history/<mode>/manifest.json` (`vi-compare/history@v1`).
  - `history-context.json` with commit metadata (`vi-compare/history-context@v1`).
- `scripts/Run-VIHistory.ps1` prints a terse preview in the console, emits `history-context.json`, and runs
  `tools/Publish-VICompareSummary.ps1` in dry-run mode.
- CI workflows surface mode counts, diff totals, and a pointer to artifacts via GitHub outputs and step summaries, but
  reviewers must open raw JSON or download artifacts to see commit details.

## Proposed report experience

- Emit two artefacts from the renderer:
  1. `history-report.md` – Markdown with tables suitable for PR comments and the CI step summary.
  2. Optional `history-report.html` – richer layout (collapsible commit sections, anchored links) for local browsing.
- Document structure:
  1. Header block summarising target VI, start ref, pair counts, and overall diff outcome.
  2. Mode summary table (processed/diffs/missing, active flags, manifest/dir references).
  3. Commit pair timeline table:
     - Mode, index, base -> head (short SHAs with subjects and authors).
     - Diff state and LVCompare report link (if available).
     - Duration seconds and exit codes for quick triage.
  4. Appendix with JSON pointers for debugging (aggregate manifest path, history-context path, artifact bundle names).
- Markdown version favours compact tables (one row per commit pair). HTML version may group by mode and use collapsible
  detail rows if diffs exceed a threshold (`>20` pairs triggers pagination/collapsible sections).

## Data contract

- Inputs:
  - Aggregate manifest (`vi-compare/history-suite@v1`).
  - `history-context.json` (`vi-compare/history-context@v1`).
  - Optional per-mode manifest data when present (reuses paths from the suite).
- Outputs:
  - Markdown file path surfaced via GitHub output key `history-report-md`.
  - Optional HTML file path via `history-report-html`.
  - Step summary enrichment: append a short section with totals/diff summary and link to the Markdown artefact.
  - JSON snippet for `mode-manifests-json` remains unchanged to preserve downstream consumers.
- Error handling:
  - If manifests lack modes or comparisons, renderer emits a warning and returns `empty` status instead of failing the
    job (aligns with current behaviour in `Compare-VIHistory.ps1`).
  - Missing LVCompare artifact paths are rendered as `_missing_` but do not block report creation.

## Delivery outline

1. Implement renderer helper (PowerShell to match existing tooling) that reads manifests, assembles view models, and
   writes Markdown/HTML outputs.
2. Plug renderer into `Compare-VIHistory.ps1` (behind `-RenderReport` flag) and `Run-VIHistory.ps1` so local runs see the
   new report path.
3. Update `Publish-VICompareSummary.ps1` to attach Markdown content to PR comments and CI summaries, honouring dry-run
   semantics.
4. Extend tests (`tests/CompareVI.History.Tests.ps1`) with fixture-based assertions to validate renderer output.
5. Refresh docs (`docs/knowledgebase/VICompare-Refs-Workflow.md`, README) to explain how to access the new report.

## Open questions and risks

- Large histories: consider truncation or paginated sections when commit pairs exceed ~30 to keep Markdown manageable.
- Artifact linking for forks: ensure report links remain relative or fall back to manifest paths when Actions artefacts
  are not yet published.
- Mode expansion: future modes (e.g. `front-panel`) should auto-populate tables without additional schema changes.
- HTML rendering: confirm whether we need assets (CSS) and keep file size modest to avoid GitHub artefact limits.

## Immediate next steps

1. Finalise renderer requirements (table schemas, link formats) with stakeholders.
2. Continue fleshing out the renderer helper (`tools/Render-VIHistoryReport.ps1`) and add regression tests.
3. Track integration tasks in the repo project for #319 to ensure automation flows and documentation land together.
