# Release VI History Review Contract

This document defines the Phase 1 contract for release-time VI history review outputs.

## Schemas

- Scenario summary: `docs/schemas/release-vi-history-review-scenario-v1.schema.json`
- Review index: `docs/schemas/release-vi-history-review-index-v1.schema.json`

## Scenario Summary (`scenario-summary.json`)

Each OS/scenario lane publishes one summary file with:

- `schema`: constant `release-vi-history-review/scenario@v1`
- `generatedAt`: UTC timestamp (`date-time`)
- `tag`: release tag
- `os`: `linux` or `windows`
- `scenario`: scenario id (`baseline`, `noattr`, `layout-and-position`, or future ids)
- `flags`: CLI flags string used for this scenario
- `image`: NI container image used for execution
- `compareExit`: compare script process exit code
- `captureExit`: capture payload exit code
- `gateOutcome`: lane policy outcome (`pass`, `warn`, `fail`, or empty when unavailable)
- `resultClass`: result class reported by capture payload
- `status`: lane status string from capture payload
- `message`: lane status message from capture payload
- `reportPath`: local report path produced in job workspace
- `reportExists`: whether the report file exists
- `capturePath`: capture JSON path produced in job workspace

### Scenario Summary Field Contract

| Field | Type | Required | Source | Notes |
| --- | --- | --- | --- | --- |
| `schema` | string | yes | scenario schema | Constant `release-vi-history-review/scenario@v1`. |
| `generatedAt` | string (`date-time`) | yes | scenario schema | UTC generation timestamp. |
| `tag` | string | yes | release workflow input | Release tag under evaluation. |
| `os` | string | yes | scenario schema | `linux` or `windows`. |
| `scenario` | string | yes | scenario profile manifest | Scenario id (`baseline`, `noattr`, `layout-and-position`, future ids). |
| `flags` | string | yes | scenario runner | Effective compare flags string. |
| `image` | string | yes | lane runtime | NI image identifier used for execution. |
| `compareExit` | integer | yes | compare execution | Compare script process exit code. |
| `captureExit` | integer | yes | capture execution | Capture payload process exit code. |
| `gateOutcome` | string | no | policy evaluator | `pass`, `warn`, `fail`, or empty when unavailable. |
| `resultClass` | string | no | capture payload | Result class from capture payload. |
| `status` | string | no | capture payload | Lane status string. |
| `message` | string | no | capture payload | Lane status message. |
| `reportPath` | string | yes | lane artifact writer | Workspace-local report path. |
| `reportExists` | boolean | yes | lane artifact writer | Whether report file exists at `reportPath`. |
| `capturePath` | string | yes | lane artifact writer | Workspace-local capture JSON path. |

## Review Index (`release-vi-history-review.json`)

The index job publishes a JSON array where each item corresponds to one discovered scenario summary.

Each row includes:

- `os`
- `scenario`
- `flags`
- `status`
- `gateOutcome`
- `resultClass`
- `compareExit`
- `reportExists`
- `artifactPath`

### Review Index Row Field Contract

| Field | Type | Required | Source | Notes |
| --- | --- | --- | --- | --- |
| `os` | string | yes | normalized scenario summary | Lane OS value. |
| `scenario` | string | yes | normalized scenario summary | Scenario id. |
| `flags` | string | yes | normalized scenario summary | Effective scenario flags. |
| `status` | string | no | normalized scenario summary | Lane status from capture payload. |
| `gateOutcome` | string | no | policy/capture synthesis | Used by policy gate evaluation. |
| `resultClass` | string | no | normalized scenario summary | Capture result class. |
| `compareExit` | integer | yes | normalized scenario summary | Compare process exit code. |
| `reportExists` | boolean | yes | normalized scenario summary | Report presence signal. |
| `artifactPath` | string | yes | index job | Artifact-relative pointer to scenario summary. |

## Validation Hooks

- CI: release workflow validates both schemas in the `release-vi-history-review-index` job.
- Local/pre-push: `tools/PrePush-Checks.ps1` runs `release:vi-history:schema` using the repo npm wrapper.

## Migration Compatibility (Phase 8)

The release index job runs `tools/Normalize-ReleaseVIHistorySummaries.ps1` before index/policy evaluation.

- Purpose: adapt older summary payload aliases to canonical contract fields.
- Behavior: normalization is additive (missing canonical fields are backfilled; existing canonical values are preserved).
- Scope: release artifact processing only; source fixtures and harness outputs are unchanged.
