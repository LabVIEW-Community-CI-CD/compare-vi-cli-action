# VI History Compare Test Requirements

This document tracks the atomic test requirements for `tools/Compare-VIHistory.ps1` and the
`Manual VI Compare (refs)` workflow.

## Helper (`tools/Compare-VIHistory.ps1`)

1. Manifest shall record `mode` equal to the requested value.
1. Each comparison entry shall record `mode` equal to the requested value.
1. `manifest.flags` shall contain the expected flag bundle per mode:
   - `default`: no ignore flags present.
   - `attributes`: includes `-noattr` only.
   - `front-panel`: includes `-nofp`, `-nofppos` only.
   - `block-diagram`: includes `-nobdcosm` only.
- `full`: no ignore flags present (all ignore flags disabled).
- `all`: legacy alias for `full` (the tooling rewrites it and warns).
   - `custom`: flag list matches explicit inputs.
1. `requestedStartRef` and `startRef` shall be written; `startRef` resolves to the nearest commit that touches the VI.
1. Helper shall pass `-RenderReport` for `html` format.
1. Helper shall pass `-Report` + `-RepFormat xml` for `xml` format.
1. Helper shall pass `-Report` + `-RepFormat text` for `text` format.
1. Manifest shall record `reportFormat` equal to the requested format.
1. Artifact directory shall contain the chosen report file extension when a diff occurs.
1. Artifact directory shall be removed when no diff occurs unless `-KeepArtifactsOnNoDiff` is set.
1. Summary JSON shall reference the artifact directory when it exists.
1. Helper shall create a dedicated output directory per mode when multiple modes are requested.
1. Unknown mode values shall raise an error before LVCompare is invoked.
1. If no touching commit exists, helper shall exit non-zero with "Unable to locate a commit".
1. Capture JSON, stdout, stderr, and manifest files shall be emitted for every run.

_Report format enrichment note: tests validating XML and text report contents shall be augmented once
real LVCompare artifacts are captured in CI. Current tests verify flag wiring via the stub driver._

## Workflow (`.github/workflows/vi-compare-refs.yml`)

<!-- Ensure ordered list numbering resets cleanly across sections -->

1. `modes` input shall accept comma/semicolon separated tokens (case-insensitive) and default to `default`.
1. Workflow shall invoke the helper once per mode, writing outputs to `tests/results/ref-compare/history/<mode>`.
1. `steps.history.outputs['manifest-path']` shall resolve to the aggregate history suite manifest.
1. `steps.history.outputs['mode-manifests-json']` shall emit a JSON array describing each requested mode (slug,
   manifest path, results directory, processed count, diff count, status).
1. `steps.history.outputs['results-dir']` shall equal the root history directory.
1. Step summary shall report target, requested/resolved start refs, processed pairs, stop reason, last diff, and active
   mode for each iteration, and render a per-mode Markdown table covering processed/diff/missing counts (including
   last diff details).
1. `vi-compare-manifests` artifact shall include the aggregate history suite manifest and each mode's `manifest.json`
   and `*-summary.json` files; execution traces (`*-exec.json`) remain local to keep the upload lean.
1. Single-mode (`default`) runs shall produce the same layout as the legacy workflow.
1. Workflow shall surface helper failures per mode and mark the job failed while preserving prior results.

## Documentation

1. `docs/knowledgebase/VICompare-Refs-Workflow.md` shall describe the `modes` input and multi-mode dispatch examples.
1. Documentation shall explain helper usage with `-Mode` and how manifest fields map to modes and flag bundles.
1. Documentation shall note that artifacts are partitioned per mode and that report-format tests will be enriched with
   real LVCompare outputs.

