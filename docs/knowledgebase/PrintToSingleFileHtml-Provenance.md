<!-- markdownlint-disable-next-line MD041 -->
# PrintToSingleFileHtml Provenance

`PrintToSingleFileHtml` is currently a support-lane surface, not a baseline
pre-push requirement.

The reason is provenance, not usefulness.

## Current findings

- The clearest explicit public `PrintToSingleFileHtml` proof we have today is
  still `aphill93/linuxContainerDemo#7`.

  That proof uses a custom `AdditionalOperationDirectory` payload under
  `VICompareTooling/PrintToSingleFileHtml`. The sample is technically useful,
  but the repository does not currently declare a license, so the payload
  cannot be treated as promotable certification input.

- A licensed added-VI sample candidate now exists on
  `LabVIEW-Community-CI-CD/labview-icon-editor-demo#29`.

  That PR added `Tooling/comparevi-history-canary/CanaryProbe.vi` on an
  MIT-licensed public consumer repository, and public CompareVI History
  diagnostics succeeded on the pinned PR head commit
  `91516373bf6c95e1d3cee2ee97452bc9d08f4ed7`. This is the best licensed
  added-VI corpus seed we have, but the published receipts are still
  history-surface artifacts rather than a standalone `PrintToSingleFileHtml`
  proof against the replacement payload.
  `91516373bf6c95e1d3cee2ee97452bc9d08f4ed7`. The public artifact for that run
  is `comparevi-history-pr-diagnostics-23225926010`. This is the best licensed
  added-VI corpus seed we have, but the published receipts are still
  history-surface artifacts rather than a standalone `PrintToSingleFileHtml`
  proof against the replacement payload.

This repository now carries a repo-owned BSD-3 licensed source bundle for the
replacement payload under:

- `fixtures/headless-corpus/operation-payloads/PrintToSingleFileHtml/`

That source bundle fixes the payload-license gap, but it does not by itself
promote the payload to `accepted`. Public proof is still required before any
sample target should claim `operationPayload.provenanceState = accepted`.

As of March 21, 2026, the bundle is still explicitly `source-only`:

- the expected runnable files remain `GetHelp.vi` and `RunOperation.vi`
- those files must inspect as real LabVIEW binaries before the bundle can
  transition from `source-only` to `runnable`; placeholder text files do not
  satisfy the executable-state contract
- `#1619` bootstraps disposable authoring workspaces from installed official
  CLI operation directories
- `#1621` tracks the repo-owned authoring step that must land before public
  proof can be attempted
- `#1726` tracks the remaining public standalone proof gap for the licensed
  added-VI candidate
- `tools/Inspect-OperationPayloadSourceBundle.ps1` now emits the fail-closed
  executable-state receipt for the checked-in bundle
- `tools/Invoke-HeadlessSampleVICorpusPrintProof.ps1` now turns the current
  `source-only` payload state into a deterministic blocked proof receipt for the
  sample-corpus print lane instead of relying on human interpretation; when the
  payload becomes runnable, the same wrapper now executes the Linux proof lane
  through `tools/Run-NILinuxContainerCustomOperation.ps1`
- When a finalization contract is available, the proof receipt now records the
  referenced contract path so future payload finalization helpers can be tied to
  the same deterministic proof lane without inventing a new receipt shape
- `tools/New-PrintToSingleFileHtmlAuthoringWorkspace.ps1` now wraps the generic
  scaffold so this payload has a dedicated disposable authoring bootstrap
- `tools/New-PrintToSingleFileHtmlAuthoringPacket.ps1` now turns the remaining
  gap into an explicit native-authoring packet with the installed
  `Operations.lvproj`, `Toolkit-Operations.lvproj`, LabVIEW 2026 x86 path, an
  authoring checklist, and a launch helper
- `tools/Finalize-OperationPayloadSourceBundle.ps1` now gives the native
  authoring handoff a deterministic completion step: once repo-owned LabVIEW
  binary files are checked in, the helper updates `checkedInOperationFiles`,
  flips the declared executable state to `runnable`, and leaves public proof as
  the remaining blocker instead of requiring manual manifest editing

## Repo policy

- Do not vendor or mirror unlicensed `AdditionalOperationDirectory` payloads.
- Do not promote a `print-single-file` target to `accepted` unless both of
  these provenance planes are clean:
  - the sample VI repository
  - the custom operation payload repository
- Keep unlicensed or otherwise ambiguous custom payloads in `research-only`
  status.

## Promotion ladder

1. `research-only`
- public run exists
- rendering behavior is informative
- payload license or reuse rights are not yet promotable

2. `accepted`
- sample repository is public and licensed
- payload provenance is public and licensed
- repo-owned payload source or binaries are checked in with explicit license
- payload metadata is tracked in the sample corpus catalog
- at least one successful public workflow run exists

## Why this is separate from sample provenance

A sample repository can be clean while the rendering payload is not.

That distinction matters for added/deleted VI rendering because the current
`PrintToSingleFileHtml` proof depends on a custom operation surface rather than
the default compare path.

The headless sample corpus therefore tracks `operationPayload` separately from
the target repository metadata, and `#1467` now carries both remaining blocker
shapes explicitly:

- licensed sample still missing explicit print proof
- repo-owned payload still missing runnable public proof
