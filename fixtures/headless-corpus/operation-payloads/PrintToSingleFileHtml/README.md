# PrintToSingleFileHtml Payload Source Bundle

This directory is the repo-owned source bundle for the future
`PrintToSingleFileHtml` `AdditionalOperationDirectory` payload used by
added/deleted VI certification.

Current status:

- licensed
- repo-owned
- source-only
- not yet executable
- not yet promotable to corpus `operationPayload.provenanceState = accepted`

Why it exists:

- `aphill93/linuxContainerDemo#7` proved the pattern, but its payload provenance
  is not promotable here because that repository declares no license.
- This repo needs a public, explicitly licensed source bundle before the
  added/deleted certification lane can promote a replacement seed.

Implementation basis:

- official LabVIEW `Print:VI To HTML` capability
- `AdditionalOperationDirectory` payload shape expected by `LabVIEWCLI`

This bundle does not yet check in runnable LabVIEW operation binaries such as:

- `GetHelp.vi`
- `RunOperation.vi`

That is deliberate. This slice establishes:

- licensing
- provenance
- intended payload contract

It does not claim the payload is already proven end to end.

The supported authoring bootstrap for this payload is now:

- installed-operation scaffold from `#1619`
- repo-owned runnable payload authoring under `#1621`

Do not commit installed NI operation files verbatim from scaffold output.

Promotion remains blocked until both of these are true:

1. runnable operation files are authored and checked in under this bundle
2. at least one public workflow run proves the payload on an added or deleted VI

Machine-readable provenance for this bundle lives in `payload-provenance.json`.
Use `tools/Inspect-OperationPayloadSourceBundle.ps1` to project the current
executable-state inspection receipt for this bundle.
