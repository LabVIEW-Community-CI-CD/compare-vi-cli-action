<!-- markdownlint-disable-next-line MD041 -->
# REQ-DOTNET_CLI_RELEASE_ASSET

## Status

- Owner: CI/CD maintainers
- Tracking issue: [#167](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/167)
- Phase: requirements baseline
- Last updated: 2026-03-03

## Goal

Define requirements for a `.NET CLI` distributed as a GitHub release asset to orchestrate native LabVIEW 2026 compare
loops and VI History report generation on Windows hosts.

## Scope

- In scope:
  - Host-native LabVIEW 2026 orchestration (no container dependency required for core flow).
  - Single-pair compare loop execution.
  - Multi-pair VI History execution across a commit range.
  - Consolidated report outputs (JSON, Markdown, HTML, extracted image index).
  - Deterministic exit classification and timing telemetry.
  - Release asset packaging contract.
- Out of scope:
  - Replacing current PowerShell toolchain in one step.
  - LabVIEW project editing semantics.
  - Linux-native host execution for this initial CLI scope.

## Host Contract

- Operating system: Windows Server 2022 LTSC or Windows 11 compatible with LabVIEW 2026.
- Installed tools:
  - LabVIEW 2026 (native installation).
  - LVCompare available at canonical NI path.
  - .NET runtime required by published CLI.
- Runtime policy:
  - Non-interactive by default.
  - Headless execution is mandatory in automation mode.

## Command Surface

The CLI must expose stable commands:

- `compare single`
  - Compare one base/head pair and generate a single report unit.
- `history run`
  - Execute commit-to-commit history compares from a requested base/head ref range.
- `report consolidate`
  - Build consolidated PR-facing outputs from prior compare captures.
- `contracts validate`
  - Validate output schemas and fail fast on contract drift.

## Input Contract

All commands must support deterministic machine input via JSON files and explicit flags:

- Required identity fields:
  - `repositoryRoot`
  - `baseRef`
  - `headRef`
  - `targetViPath` or `targetViPaths[]`
- Compare controls:
  - `compareModes[]`
  - `maxPairs`
  - `includeMergeParents`
  - `requireDiffOnly` (history scenario filtering)
- Output controls:
  - `resultsRoot`
  - `emitHtml`
  - `extractImages`

## Output Contract

The CLI must emit additive, schema-versioned artifacts:

- `vi-history-summary.json`
  - Includes per-target status, per-pair metrics, and totals.
- `vi-history-summary.md`
  - Reviewer-facing markdown summary.
- `vi-history-report.html`
  - Consolidated HTML report for local/open-in-browser review.
- `vi-history-image-index.json`
  - Extracted report image metadata for PR/mobile preview flows.
- `toolchain-contract.json`
  - Captures runtime/toolchain identity and policy checks.

All output paths must be emitted to stdout as structured JSON and optional GitHub output key/value pairs.

## Exit Classification Contract

The CLI must preserve current gating semantics:

- `success-no-diff`
  - Operation succeeded, no diff evidence.
- `success-diff`
  - Operation succeeded, diff evidence present.
- `failure-runtime`
  - Host/runtime determinism or infrastructure failure.
- `failure-tool`
  - LVCompare/LabVIEWCLI invocation failure.
- `failure-timeout`
  - Operation timed out.
- `failure-preflight`
  - Input or policy preflight failure.

Rules:

- Diff detection is pass-class (`gateOutcome=pass`).
- Runtime/tool/timeout/preflight classes are fail-class (`gateOutcome=fail`).
- Determinism mismatch is hard-stop eligible.

## Timing and KPI Telemetry Contract

The CLI must emit per-item timing metadata to support KPI baselining:

- Per compare item:
  - `startUtc`
  - `endUtc`
  - `durationMs`
  - `resultClass`
- Aggregate:
  - `count`
  - `totalDurationMs`
  - `p50DurationMs`
  - `p95DurationMs`
  - `slowestItems[]`

Timing data must be available in both machine-readable JSON and reviewer-facing summary surfaces.

## PowerShell-to-CLI Mapping

The first implementation must map current script contracts without breakage:

| Existing PowerShell surface | CLI equivalent |
| --- | --- |
| `Invoke-PRVIHistory.ps1` | `history run` |
| `Run-NIWindowsContainerCompare.ps1` exit classifier fields | `compare single` result envelope |
| `Render-VIHistoryReport.ps1` | `report consolidate` |
| `Write-DockerFastLoopReadiness.ps1` summary envelope | `contracts validate` + readiness output |

Mapping must remain additive. Existing JSON keys consumed by workflows cannot be removed.

## Release Asset Contract

Each GitHub release must provide:

- `compare-vi-history-cli-win-x64.zip`
- `compare-vi-history-cli-win-x64.sha256`
- `sbom.spdx.json`
- `provenance.intoto.jsonl` (or equivalent attestation format)
- Release notes section:
  - Supported LabVIEW versions.
  - Contract/schema changes.
  - Upgrade and rollback instructions.

## Acceptance Criteria

- This requirement document is approved and linked from `docs/requirements/index.md`.
- Follow-up implementation issues exist for:
  - CLI skeleton and command surface.
  - Schema contract adapters.
  - Release pipeline and signing/provenance.
  - Host-native validation harness.
- A release readiness checklist is defined before first public CLI asset publication.
