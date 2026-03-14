<!-- markdownlint-disable-next-line MD041 -->
# Public Linux Diagnostics Harness Contract

This contract defines the shared surface for the future public-repo Linux diagnostics harness tracked by `#1163` under
epic `#958`.

The goal is to keep the eventual local Docker Desktop entry point and the eventual manual GitHub workflow on one
artifact and approval contract.

## Scope

This contract is for a diagnostics harness that:

- targets a public repository
- targets a branch or ref derived from `develop`
- allows refs that are either equal to or ahead of `develop`
- exercises the future LabVIEW 2026 Q1 Linux lane
- produces a deterministic artifact bundle for operator review
- requires an explicit human go/no-go decision before the session is complete

## Canonical execution surfaces

- Local parity entry point:
  - `tools/Run-NonLVChecksInDocker.ps1 -UseToolsImage -NILinuxReviewSuite`
- Hosted manual workflow:
  - `.github/workflows/public-linux-diagnostics-harness.yml`
- Existing Docker/Desktop parity guidance:
  - [`knowledgebase/DOCKER_TOOLS_PARITY.md`](knowledgebase/DOCKER_TOOLS_PARITY.md)
- Human decision workflow:
  - `.github/workflows/human-go-no-go-feedback.yml`
- Human decision schema:
  - `docs/schemas/human-go-no-go-decision-v1.schema.json`

The shared contract now anchors both the local entry-point work and the hosted manual workflow surface. The human
go/no-go workflow remains a separate completion surface and must not be conflated with the hosted diagnostics workflow.

## Target contract

The harness must accept:

- `repositorySlug`
  - public `owner/repo`
- `reference`
  - branch or ref derived from `develop`
- `developRelationship`
  - `equal` or `ahead`
- Linux image/release lane selection

Private repositories and refs with unrelated lineage are out of scope for this first contract.

## Artifact bundle contract

The deterministic review bundle must expose:

- a top-level review-loop receipt
- VI history summary JSON
- VI history HTML report
- an operator-facing summary path under `_agent`
- a deterministic rendered review summary for operators

The checked-in schema for this contract is:

- `docs/schemas/public-linux-diagnostics-harness-contract-v1.schema.json`
- `docs/schemas/public-linux-diagnostics-review-summary-v1.schema.json`

The initial contract reuses the existing Docker/Desktop parity artifact layout so future harness entry points do not
invent a second bundle structure before the first one is proven.

The renderer surface for operator review is:

- `tools/priority/public-linux-diagnostics-review-summary.mjs`
- JSON: `tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.json`
- Markdown: `tests/results/_agent/diagnostics/public-linux-diagnostics-review-summary.md`

## Human go/no-go checkpoint

The diagnostics session is not complete when the machine run succeeds.

It is complete only after a human decision is recorded through the existing go/no-go surface:

- workflow: `.github/workflows/human-go-no-go-feedback.yml`
- schema: `docs/schemas/human-go-no-go-decision-v1.schema.json`
- artifact: `human-go-no-go-decision`
- decision path: `tests/results/_agent/handoff/human-go-no-go-decision.json`

Future harness implementations must point operators to that existing contract instead of inventing a parallel approval
format.
