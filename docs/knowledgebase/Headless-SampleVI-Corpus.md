<!-- markdownlint-disable-next-line MD041 -->
# Headless Sample VI Corpus

This note defines the checked-in admission contract for public sample VIs used
as a higher certification layer above the repo's minimal local fixtures.

## Purpose

Use externally evidenced sample VIs when you need stronger proof that headless
compare or history rendering still works on realistic public files.

This corpus is not the pre-push gate.

- Pre-push stays deterministic and fixture-backed.
- The sample corpus is a certification and research layer.
- Admission state keeps licensed, public, reproducible seeds separate from
  useful-but-not-yet-promotable samples.

## Checked-in inputs

- Target catalog: `fixtures/headless-corpus/sample-vi-corpus.targets.json`
- Catalog schema:
  `docs/schemas/headless-sample-vi-corpus-targets-v1.schema.json`
- Evaluation schema:
  `docs/schemas/headless-sample-vi-corpus-evaluation-v1.schema.json`
- Evaluator:
  `tools/Invoke-HeadlessSampleVICorpusEvaluation.ps1`
- Print proof wrapper:
  `tools/Invoke-HeadlessSampleVICorpusPrintProof.ps1`
- Linux print runner:
  `tools/Run-NILinuxContainerCustomOperation.ps1`

## Admission states

- `accepted`
  - requires public GitHub evidence
  - requires a declared license
  - requires a pinned commit SHA
  - can be promoted into broader certification lanes
- `provisional`
  - useful for research and future replacement
  - must stay non-blocking
  - captures why the seed is not yet promotable
- `rejected`
  - recorded only when the catalog needs to remember why a prior seed cannot be
    used anymore

## Current seeds

### Accepted

1. `icon-editor-settings-init-history`
- Repo: `LabVIEW-Community-CI-CD/labview-icon-editor`
- License: `MIT`
- Surface: `vi-history`
- Plane: `windows-mirror`
- Local lineage: `fixtures/cross-repo/labview-icon-editor/settings-init/`
- Public evidence: PR VI History workflow success on the public upstream repo

2. `icon-editor-demo-vip-preinstall-history`
- Repo: `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
- License: `MIT`
- Surface: `vi-history`
- Plane: `linux-proof`
- Public evidence: PR `#31` plus successful diagnostics, publish, and canary
  runs on the real modified VI

### Provisional

1. `linuxcontainerdemo-newthing-print`
- Repo: `aphill93/linuxContainerDemo`
- Surface: `print-single-file`
- Plane: `linux-proof`
- Change kind: `added`
- Public evidence: PR `#7` plus successful Linux compare/headless runs
- Blocking gap: the repository currently declares no license

2. `icon-editor-demo-canaryprobe-print`
- Repo: `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
- License: `MIT`
- Surface: `print-single-file`
- Plane: `linux-proof`
- Change kind: `added`
- Public evidence: PR `#29`
  (`LabVIEW-Community-CI-CD/labview-icon-editor-demo@91516373bf6c95e1d3cee2ee97452bc9d08f4ed7`)
  plus successful CompareVI History diagnostics on the added-VI PR head
- Blocking gap: the public run published history-surface evidence, not a
  standalone `PrintToSingleFileHtml` proof against the repo-owned BSD-3
  replacement payload

These provisional seeds now separate the two remaining blockers:

- `linuxcontainerdemo-newthing-print` still shows the clearest explicit public
  print proof, but it remains license-ambiguous.
- `icon-editor-demo-canaryprobe-print` gives us a licensed added-VI sample on a
  public consumer repo and points at a repo-owned payload source bundle, but it
  still lacks explicit print-single-file publication evidence. Track that gap in
  `#1726`.

## Render strategy rules

The corpus keeps change kind and rendering intent explicit.

- `modified` VIs:
  - `vi-history` -> `Compare-VIHistory`
  - `compare-report` -> `CreateComparisonReport`
- `added` or `deleted` VIs:
  - `print-single-file` -> `PrintToSingleFileHtml`

This keeps the sample corpus aligned with the change-kind-aware rendering work
tracked in `#1406` and `#1408`.

## Operation payload provenance

For `print-single-file` targets, sample provenance alone is not enough.

The catalog now tracks `operationPayload` separately so the evaluator can
distinguish:

- a licensed public sample repository
- from an unlicensed or research-only custom rendering payload

See `docs/knowledgebase/PrintToSingleFileHtml-Provenance.md`.

## Evaluation

Run the evaluator locally:

```powershell
node tools/npm/run-script.mjs history:corpus:samples:evaluate
```

Outputs land under:

- `tests/results/_agent/headless-sample-corpus/headless-sample-vi-corpus-evaluation.json`
- `tests/results/_agent/headless-sample-corpus/headless-sample-vi-corpus-evaluation.md`

The evaluator fails closed when an `accepted` target loses:

- public GitHub evidence
- declared license
- pinned commit
- coherent change-kind/render strategy
- declared local fixture lineage paths when present

`provisional` targets can warn without failing the overall report.

## Intentional boundary

Do not let this corpus replace:

- the local fixture-backed pre-push gate
- the rendered reviewer semantic assertions
- the broad NI Linux certification lane

It exists to strengthen those surfaces with public, realistic, machine-tracked
sample provenance.

## Print proof lane

For `print-single-file` targets, the checked-in wrapper now has two explicit
states:

- `blocked`
  - the repo-owned payload still inspects as `source-only`
  - no execution is attempted
- `succeeded` / `failed`
  - the payload inspects as runnable
  - the wrapper materializes the pinned public sample repo (or uses an explicit
    local checkout override)
  - the Linux proof lane runs `PrintToSingleFileHtml` through
    `tools/Run-NILinuxContainerCustomOperation.ps1`

That keeps the wrapper fail-closed while still giving the repo a real Linux
execution plane as soon as the repo-owned payload becomes runnable.
