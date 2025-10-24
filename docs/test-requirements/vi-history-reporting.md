# VI History Compare Test Requirements

This document tracks the atomic test requirements for `tools/Compare-VIHistory.ps1` and the
`Manual VI Compare (refs)` workflow.

## Helper (`tools/Compare-VIHistory.ps1`)

1. Manifest shall record `mode` equal to the requested value.
2. Each comparison entry shall record `mode` equal to the requested value.
3. `manifest.flags` shall contain the expected flag bundle per mode:
   - `default`: includes `-nobd`, `-noattr`, `-nofp`, `-nofppos`, `-nobdcosm`.
   - `attributes`: includes `-nobd`, `-nofp`, `-nofppos`, `-nobdcosm`, omits `-noattr`.
   - `front-panel`: includes `-nobd`, `-noattr`, `-nobdcosm`, omits `-nofp`, `-nofppos`.
   - `block-diagram`: includes `-nobd`, `-noattr`, `-nofp`, `-nofppos`, omits `-nobdcosm`.
   - `all`: no ignore flags present.
   - `custom`: flag list matches explicit inputs.
4. `requestedStartRef` and `startRef` shall be written; `startRef` resolves to the nearest commit that touches the VI.
5. Helper shall pass `-RenderReport` for `html` format.
6. Helper shall pass `-Report` + `-RepFormat xml` for `xml` format.
7. Helper shall pass `-Report` + `-RepFormat text` for `text` format.
8. Manifest shall record `reportFormat` equal to the requested format.
9. Artifact directory shall contain the chosen report file extension when a diff occurs.
10. Artifact directory shall be removed when no diff occurs unless `-KeepArtifactsOnNoDiff` is set.
11. Summary JSON shall reference the artifact directory when it exists.
12. Helper shall create a dedicated output directory per mode when multiple modes are requested.
13. Unknown mode values shall raise an error before LVCompare is invoked.
14. If no touching commit exists, helper shall exit non-zero with "Unable to locate a commit".
15. Capture JSON, stdout, stderr, and manifest files shall be emitted for every run.

*Report format enrichment note: tests validating XML and text report contents shall be augmented once
real LVCompare artifacts are captured in CI. Current tests verify flag wiring via the stub driver.*

## Workflow (`.github/workflows/vi-compare-refs.yml`)
<!-- markdownlint-disable MD029 -->
16. `modes` input shall accept comma/semicolon separated tokens (case-insensitive) and default to `default`.
17. Workflow shall invoke the helper once per mode, writing outputs to `tests/results/ref-compare/history/<mode>`.
18. `steps.history.outputs['manifest-path']` shall resolve to the aggregate history suite manifest.
19. `steps.history.outputs['mode-manifests-json']` shall emit a JSON array describing each requested mode (slug,
   manifest path, results directory, processed count, diff count, status).
20. `steps.history.outputs['results-dir']` shall equal the root history directory.
21. Step summary shall report target, requested/resolved start refs, processed pairs, stop reason, last diff, and active
   mode for each iteration.
22. `vi-compare-results` artifact shall include every manifest plus all `*-summary.json` and `*-exec.json` files.
23. Single-mode (`default`) runs shall produce the same layout as the legacy workflow.
24. Workflow shall surface helper failures per mode and mark the job failed while preserving prior results.

## Documentation

25. `docs/knowledgebase/VICompare-Refs-Workflow.md` shall describe the `modes` input and multi-mode dispatch examples.
26. Documentation shall explain helper usage with `-Mode` and how manifest fields map to modes and flag bundles.
27. Documentation shall note that artifacts are partitioned per mode and that report-format tests will be enriched with
   real LVCompare outputs.

<!-- markdownlint-enable MD029 -->

