<!-- markdownlint-disable-next-line MD041 -->
# PrintToSingleFileHtml Provenance

`PrintToSingleFileHtml` is currently a support-lane surface, not a baseline
pre-push requirement.

The reason is provenance, not usefulness.

## Current finding

The best public added/deleted VI example we have today is
`aphill93/linuxContainerDemo#7`.

That proof uses a custom `AdditionalOperationDirectory` payload under
`VICompareTooling/PrintToSingleFileHtml`. The sample is technically useful, but
the repository does not currently declare a license, so the payload cannot be
treated as promotable certification input.

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
- payload metadata is tracked in the sample corpus catalog
- at least one successful public workflow run exists

## Why this is separate from sample provenance

A sample repository can be clean while the rendering payload is not.

That distinction matters for added/deleted VI rendering because the current
`PrintToSingleFileHtml` proof depends on a custom operation surface rather than
the default compare path.

The headless sample corpus therefore tracks `operationPayload` separately from
the target repository metadata.
