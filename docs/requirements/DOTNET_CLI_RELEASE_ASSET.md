<!-- markdownlint-disable-next-line MD041 -->
# REQ-DOTNET_CLI_RELEASE_ASSET

## 1. Status

- Owner: CI/CD maintainers
- Tracking issue: [#171](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/171)
- Phase: requirements baseline (documentation)
- Last updated: 2026-03-03
- Source standard: ISO/IEC/IEEE 29148:2018 (published November 2018)

## 2. Objective

Provide a host-native Windows `.NET` command-line interface (CLI) that orchestrates LabVIEW 2026 compare loops and
consolidated VI History report generation with a stable, versioned contract suitable for GitHub release assets.

## 3. Business Rationale

- The repository shall provide a deterministic host-side orchestration surface while origin/upstream parity is
  maintained.
- The release asset shall remove container-runtime ambiguity for host-native compare and report orchestration.

## 4. Scope

### 4.1 In Scope

- Product requirements for the CLI contract.
- Target host: Windows with native LabVIEW 2026.
- Supported workloads:
  - single-pair VI compare.
  - sequential history compare across a base/head range.
  - consolidated VI History report rendering and image index metadata.
- Packaging and publishing as release assets (`.zip`, checksums, SBOM, provenance).

### 4.2 Out of Scope

- Container images, Dockerfiles, and container-runtime support.
- Non-Windows host support.
- Interactive desktop workflows except explicit local debug overrides.
- Changes to LabVIEW compare algorithms outside orchestration.

## 5. Definitions

- `base` / `head`: git refs identifying comparison start/end revisions.
- Compare item: one logical VI comparison unit.
- Pass-class outcome: outcome that does not fail gate policy by default.
- Fail-class outcome: outcome that fails gate policy by default.
- Headless: execution mode with no interactive UI dependency.

## 6. External Interface Requirements

### 6.1 Command Set

CLI-IF-001: The CLI shall provide command families listed below.

| Command | Purpose | Minimum inputs | Primary outputs |
| --- | --- | --- | --- |
| `preflight` | Validate environment and dependencies | `--repo` (optional) | summary JSON + diagnostics |
| `compare single` | Compare one VI pair at base/head | `--base --head --vi` | JSON + Markdown + HTML + image index |
| `compare range` | Compare changed VIs across base..head | `--base --head` (+ filters) | JSON + Markdown + HTML + image index |
| `report consolidate` | Render or merge consolidated history report | `--in --out` | HTML + image index + JSON |

Verification: Inspection

### 6.2 Common Option Contract

CLI-IF-010: The CLI shall support semantically stable common options once released.

| Option | Type | Required | Meaning |
| --- | --- | --- | --- |
| `--repo` | path | no | Repository root (default current directory) |
| `--base` | string | depends | Git base ref |
| `--head` | string | depends | Git head ref |
| `--vi` / `--vi-list` | path | depends | Target VI path(s) |
| `--mode` | enum | no | Compare mode(s) aligned to legacy scripts |
| `--max-pairs` | int | no | Hard cap on compare items |
| `--out-dir` | path | no | Output artifact directory |
| `--timeout` | duration | no | Per-item or run timeout |
| `--headless` | flag | depends | Explicit headless opt-in |
| `--non-interactive` | flag | no | Fail instead of prompting |
| `--log-level` | enum | no | Diagnostic verbosity |

Verification: Inspection

## 7. Data Contract Requirements

### 7.1 Deterministic Input Contract

CLI-DC-001: Each command shall define one authoritative input contract including required/optional parameters, defaults,
validation rules, and invalid-input handling.
Verification: Inspection/Test

CLI-DC-002: The CLI shall reject unrecognized options as invalid usage.
Verification: Test

### 7.2 Deterministic Output Artifact Set

CLI-DC-010: The CLI shall emit versioned JSON and report artifacts for pass-class and fail-class outcomes.
Verification: Test

| Artifact | Format | Required | Notes |
| --- | --- | --- | --- |
| machine-readable summary | JSON | yes | Stable schema |
| human-readable summary | Markdown | yes | Links to report/artifacts |
| consolidated report | HTML | yes | Path surfaced in JSON |
| image index | JSON | yes | Metadata for extracted report images |
| run log | text/structured | yes | Path surfaced in JSON |

### 7.3 Schema Versioning

CLI-DC-020: Summary JSON and image index JSON shall include `schemaVersion`.
Verification: Inspection

CLI-DC-021: Schema changes shall be additive within a major version. Breaking changes shall require a major increment.
Verification: Inspection

## 8. Functional Requirements

### 8.1 Preflight and Environment Validation

CLI-FR-001: The CLI shall provide `preflight` to validate host prerequisites for compare/report workloads.
Verification: Test

CLI-FR-002: On preflight failure, the CLI shall emit diagnostics in summary JSON identifying failed prerequisites.
Verification: Inspection/Test

### 8.2 Single-Pair Compare

CLI-FR-010: The CLI shall compare a single VI at base versus head.
Verification: Test

CLI-FR-011: The CLI shall support explicit compare mode selection aligned to legacy PowerShell behavior, with mapping
documented in [`DOTNET_CLI_POWERSHELL_MAPPING.md`](./DOTNET_CLI_POWERSHELL_MAPPING.md).
Verification: Inspection

### 8.3 Sequential History Compare Across Range

CLI-FR-020: The CLI shall support range-based compare item discovery using `base..head`.
Verification: Test

CLI-FR-021: The CLI shall process compare items sequentially by default and record order in summary JSON.
Verification: Inspection/Test

CLI-FR-022: The CLI shall treat `--max-pairs` as a hard cap and record truncation state in summary JSON.
Verification: Test

### 8.4 Report Rendering and Image Metadata

CLI-FR-030: The CLI shall produce or orchestrate a consolidated HTML report and emit its resolved path in summary JSON.
Verification: Test

CLI-FR-031: The CLI shall emit image index JSON with at least image path, compare item identifier, and media type.
Verification: Inspection/Test

### 8.5 Exit Code and Outcome Classification

CLI-FR-040: The CLI shall preserve current outcome classification semantics where diff-only outcomes are pass-class and
preflight/runtime/tool/timeout outcomes are fail-class.
Verification: Test

CLI-FR-041: The CLI shall record `outcome.class` and `outcome.kind` in summary JSON.
Verification: Inspection

CLI-FR-042: The CLI shall provide a documented legacy exit-code compatibility option without changing JSON outcome
classification.
Verification: Test/Inspection

### 8.6 Timing Telemetry

CLI-FR-050: The CLI shall record per-item timing (`start`, `end`, `duration`) for each compare item.
Verification: Inspection/Test

CLI-FR-051: The CLI shall compute aggregate timing metrics including total duration and percentiles `p50`, `p90`, and
`p95`.
Verification: Analysis/Test

### 8.7 Headless Policy Enforcement

CLI-FR-060: The CLI shall require explicit headless opt-in for CI or non-interactive automation contexts.
Verification: Test

CLI-FR-061: The CLI shall fail fast with fail-class diagnostics when headless policy prerequisites are violated.
Verification: Test

## 9. Non-Functional Requirements

CLI-NFR-001: Build inputs shall be reproducible using locked dependencies and pinned SDK/toolchain versions.
Verification: Inspection/Analysis

CLI-NFR-002: The CLI shall expose build metadata (`version`, `commit`, `build timestamp`) in `--version` and summary
JSON.
Verification: Inspection

CLI-NFR-010: Published release artifacts shall be cryptographically signed and verifiable.
Verification: Inspection/Test

CLI-NFR-020: In non-interactive mode, the CLI shall fail instead of prompting for input.
Verification: Test

CLI-NFR-030: Output schema evolution shall be additive within a major version.
Verification: Inspection

## 10. Release-Asset Packaging Requirements

CLI-REL-001: Each release shall publish a `.zip` containing the CLI executable and required runtime files for the
target host without container dependencies.
Verification: Inspection/Test

CLI-REL-002: Each release shall publish SHA-256 checksums for the `.zip` and standalone binaries.
Verification: Test

CLI-REL-003: Each release shall publish an SBOM for distributed contents.
Verification: Inspection

CLI-REL-004: Each release shall publish provenance metadata that traces artifacts to source revision and build workflow.
Verification: Inspection

CLI-REL-010: Release asset naming conventions shall be documented and versioned.
Verification: Inspection

## 11. Acceptance Criteria for This Requirement Baseline

AC-001: This requirements specification shall be committed under `docs/requirements/` and linked from index.

AC-002: A mapping document from legacy PowerShell surfaces to CLI contracts shall be committed as
[`DOTNET_CLI_POWERSHELL_MAPPING.md`](./DOTNET_CLI_POWERSHELL_MAPPING.md).

AC-003: A release-asset checklist shall be committed as
[`DOTNET_CLI_RELEASE_CHECKLIST.md`](./DOTNET_CLI_RELEASE_CHECKLIST.md).

AC-004: Follow-up implementation issues shall be created and linked from the tracking issue before implementation
closure.
