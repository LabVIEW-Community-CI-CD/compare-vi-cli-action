<!-- markdownlint-disable-next-line MD041 -->
# LVCompare Capture HTML Integration Plan

Originally scoped under issue **#88** and now rolled into the standing priority (#127),
this plan tracks everything needed to make `lvcompare-capture.json` a first-class source
for the HTML report rendered by `scripts/Render-CompareReport.ps1`.

## Status snapshot

| Phase | Focus | Status | Notes |
| ----- | ----- | ------ | ----- |
| 1 | Capture pipeline + artefact inventory | ✅ Complete | Capture JSON emitted alongside compare logs; wiring documented here. |
| 2 | Report ingestion + schema coverage | 🚧 In progress | Schema generation in place, report still consumes `compare-exec.json` until capture parsing lands. |
| 3 | UX polish + provenance automation | ⏳ Planned | Depends on Phase&nbsp;2 telemetry hooks and backlog items below. |

## Current data flow

- **Entry points** – `tools/TestStand-CompareHarness.ps1` and `tools/Invoke-LVCompare.ps1`
  stage artefacts beneath `<OutputRoot>/compare/` before handing off to the capture script.
- **Capture stage (`scripts/Capture-LVCompare.ps1`)** – launches `LVCompare.exe`, records
  stdout/stderr/exit code, and writes `lvcompare-capture.json` (schema `lvcompare-capture-v1`)
  alongside the optional HTML report and ancillary breadcrumbs (`lvcompare-path.txt`,
  stopwatch timing). Embedded CLI artefacts (for example, base64 diff images) are decoded into
  `cli-images/`, and the capture summary now records image counts, byte size, and export paths to
  support downstream enrichment.
- **Report stage (`scripts/Render-CompareReport.ps1`)** – today relies on command metadata,
  `compare-exec.json`, anomaly summaries, and process snapshots. It enumerates capture artefacts
  but does not yet hydrate the HTML from their payload.
- **Telemetry / downstream consumption** – `tools/Invoke-LVCompare.ps1` emits NDJSON events
  (`prime-lvcompare-v1`), optional leak summaries, and pushes exit-code/duration metadata into the
  summary pipeline. `tools/Parse-CompareExec.ps1` now bubbles the `environment.cli.artifacts`
  summary into `compare-outcome.json`, and both the OneButton summary and the dev dashboard surface
  the report size, image count, and export directory so downstream tooling can link directly to the
  decoded assets.

## Target HTML experience

**Outcome panel**
- Primary data source: `lvcompare-capture.json`. Fallback to `compare-exec.json` must set an
  explicit `source=fallback` badge.
- Required fields: exit code, diff flag, elapsed seconds, capture timestamp, compare policy in
  effect, and capture schema version.
- Highlight non-{0,1} exit codes with an inline warning banner plus a contextual link to remediation
  guidance (`docs/TROUBLESHOOTING.md` anchor).
- Acceptance: renders even when capture is missing (fallback copy), hides nothing when values are
  zero/empty, and never duplicates content across rerenders.

**Execution context**
- Display the resolved LVCompare/LabVIEW executables, normalised flags, and the final command line
  in a structured layout (definition list or table) that reads well in screen readers.
- Offer copy actions on every field (buttons + keyboard shortcuts) and suppress them when the value
  is empty or redacted.
- Surface environment inputs that shaped the invocation (for example, `LABVIEW_EXE`,
  `LVCI_COMPARE_MODE`, `LVCI_COMPARE_POLICY`) and note whether each came from workflow defaults or
  local overrides.
- When the CLI report embeds artefacts (for example, diff images), export them to a deterministic
  `cli-images/` directory, surface the image count and per-image metadata in the summary KV block,
  and provide quick copy targets for downstream tooling to rehydrate attachments.
- Hyperlink artefact paths to their published locations when available; degrade gracefully with
  tooltips that explain why a path cannot be opened (missing upload, trimmed log, etc.).
- Include provenance breadcrumbs—commit SHA, workflow/run identifier, branch—to make it easy to line
  up multiple reports.
- Warn when the context had to fall back to `compare-exec.json` (capture missing or invalid) and
  encourage regenerating the capture for complete metadata.
- Summarise the hardware/runner context (OS version, bitness, runner label) and the LVCompare
  binary’s bitness so reviewers can assess environment parity quickly.
- Surface the effective compare policy (LV vs CLI preference) and highlight when automation toggled
  it mid-run due to fallback behaviour.
- Expose the locations of secondary artefacts (partial logs, watcher telemetry) when they feed into
  the compare outcome, and mark when retention policies trimmed them.
- Acceptance: every row is testable via DOM selectors (data attributes) so automated tests can
  verify values; link targets validated by `tools/Schema-Lint.ps1` or schema-lite when available.

**Stdout/stderr previews**
- Display the first _N_ lines/bytes with explicit truncation badges, byte counts, and download links.
- Use syntax highlighting or monospace blocks for readability; colour stderr when non-empty.
- Provide a “show more” affordance gated by a configurable truncation threshold.
- Acceptance: previews must round-trip in tests by comparing the rendered excerpt with the capture
  payload; truncation state exposed via `data-truncated` attribute for e2e assertions.

**Artefact manifest**
- List capture JSON, `compare-exec.json`, HTML report, LVCompare CLI logs, and compare diffs.
- Include per-item status badges: available, missing (with reason), validation failed, or stale.
- Surface schema validation results inline when available; link to raw JSON.
- Acceptance: manifest rows derive from a single artefact registry so automation can unit-test the
  mapping; missing artefacts trigger a `notice` in summaries and a red badge in UI.

**Diagnostics strip**
- Summarise anomaly badges (loop warnings, fixture drift clues), diff statistics, and capture/report
  mismatches.
- Raise explicit banners when metadata disagrees (diff flag vs. artefact presence, exit code vs.
  workflow outcome).
- Provide quick links to troubleshooting docs or rerun commands.
- Acceptance: every banner includes a machine-readable code (for example,
  `data-code="capture-mismatch"`) used by watcher automation and Pester integration tests; strip
  must render even when there are zero anomalies (show “All signals nominal”).

## Constraints & guardrails

- Keep HTML generation deterministic and non-interactive for CI; no live fetches or JS-driven
  hydration.
- Capture payloads may embed large logs—enforce inline size limits (example: 16&nbsp;KB) and
  expose the remainder via downloads.
- Extend provenance emitters so run metadata identifies the capture artefact path and the source of
  the exit code shown in summaries.
- Confirm orchestrated workflows upload capture JSON, HTML reports, and raw logs so hyperlinks
  never point at missing artefacts.
- Ensure schema coverage exists (`lvcompare-capture-v1` via the generator) so schema-lite validation
  can gate future changes.

## Work completed to date

- Capture artefacts staged consistently by the harness and invoked scripts (Phase&nbsp;1 deliverable).
- Schema definition for `lvcompare-capture-v1` included in the generator; validation wired through
  `tests/ParseCompareExec.Tests.ps1`.
- `tools/Parse-CompareExec.ps1` prefers capture metadata and emits stdout/stderr byte counts,
  propagating paths into `compare-outcome.json` and step summaries when available.
- `tools/Invoke-LVCompare.ps1 -Summary` surfaced capture hints, byte totals, and artefact locations
  to align with summary acceptance expectations.

## Remaining backlog

- Teach `scripts/Render-CompareReport.ps1` to consume the capture payload and populate the Compare
  Outcome card.
- Add provenance glue so the session index and `compare-outcome.json` explicitly cite capture as the
  source of truth when available.
- Provide an opt-in truncation policy (CLI flag or environment variable) for operators who need
  larger stdout/stderr excerpts inside the report.
- Extend orchestration workflows to publish schema validation results for capture artefacts in CI.
- Ship UX polish: diff badges, missing-file callouts, and copy-to-clipboard affordances.

### Manual CLI capture checklist

1. **Prep fixtures** – ensure `fixtures/VI1.vi` and `fixtures/VI2.vi` (or your custom pair) are available in the workspace.
2. **Point at the LabVIEW CLI** – on 64-bit Windows hosts, set `LABVIEW_CLI_PATH` to `C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe` (adjust only if your NI install lives elsewhere).
3. **Choose compare mode/policy** – export `LVCI_COMPARE_MODE=labview-cli` and `LVCI_COMPARE_POLICY=cli-only` (or `cli-first`) so the harness prefers the CLI path.
4. **Run the harness** - execute `pwsh -File tools/TestStand-CompareHarness.ps1 -BaseVi fixtures/VI1.vi -HeadVi fixtures/VI2.vi -OutputRoot tests/results/teststand-cli -Warmup detect -RenderReport` (use `-Warmup skip` to reuse an existing LabVIEW instance).
5. **Inspect outputs** - open `tests/results/teststand-cli/compare/lvcompare-capture.json` and confirm the `environment.cli` block (path, version, reportType, status, message) along with LVCompare/LabVIEW versions, compare mode/policy, bitness, OS/arch, runner labels/hash. The companion `session-index.json` now records the warmup mode, compare policy/mode, CLI command, CLI metadata, and decoded artefact summary under `compare.cli`.
6. **Validate schema** - optional: `node tools/npm/run-script.mjs schema:validate -- --schema docs/schema/generated/lvcompare-capture.schema.json --data tests/results/teststand-cli/compare/lvcompare-capture.json` to ensure the capture passes the new schema.
7. **Review stdout/stderr** - check `lvcompare-stdout.txt` / `lvcompare-stderr.txt` to confirm the parsed CLI message matches the raw output; the last non-empty line is mirrored in `environment.cli.message`.
8. **Copy execution context** - verify the Execution context panel (once rendered) shows CLI details and fallback badges; record screenshots or notes for UX feedback.

y

- Persist LabVIEW/LVCompare version, effective bitness, and OS/runner context inside `lvcompare-capture.json`.
- Privacy: avoid raw hostnames and usernames; emit a salted, ephemeral `identityHash` and runner labels only.
- Fields (proposed):
  - `lvcompareVersion` (string), `labviewVersion` (string, optional)
  - `bitness` ("x86"|"x64"), `osVersion` (string), `arch` (string)
  - `runner` (labels: string[], identityHash: string)
- Implementation: update `scripts/Capture-LVCompare.ps1` to populate fields; extend Zod schema and generator; add schema-lite validation.
- Acceptance: fields present when discoverable; omitted otherwise; HTML Execution context displays versions/bitness.

## Open questions

1. Do we need configurable truncation thresholds, or are fixed caps sufficient for both CI and local runs?
2. How should we surface exit codes >1—distinct badge, summary banner, or both?
3. Can anomaly detection reuse capture data instead of re-running hash comparisons?
2. Do we need configurable truncation thresholds, or are fixed caps sufficient for both CI and local
   runs?
3. How should we surface exit codes >1—distinct badge, summary banner, or both?
4. Can anomaly detection reuse capture data instead of re-running hash comparisons?



