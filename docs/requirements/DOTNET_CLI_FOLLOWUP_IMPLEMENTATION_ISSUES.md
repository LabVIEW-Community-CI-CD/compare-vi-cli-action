<!-- markdownlint-disable-next-line MD041 -->
# DOTNET CLI Follow-up Implementation Issues (Local Draft)

## Status

- Owner: CI/CD maintainers
- Source requirement: [REQ-DOTNET_CLI_RELEASE_ASSET](./DOTNET_CLI_RELEASE_ASSET.md)
- Last updated: 2026-03-04
- Scope mode: local-only draft while push/PR flow is paused

## Purpose

Capture implementation issue scope now and convert each draft to a repository issue when remote push/PR workflow
resumes.

## Draft issue backlog

### CLI-IMPL-001: Command surface and option contract

- Scope:
  - Implement `preflight`, `compare single`, `compare range`, and `report` contracts.
  - Enforce stable option validation and unknown-option rejection behavior.
- Requirement coverage:
  - CLI-IF-001, CLI-IF-010, CLI-DC-001, CLI-DC-002, CLI-FR-001, CLI-FR-010, CLI-FR-020.

### CLI-IMPL-002: Output schema and artifact envelope

- Scope:
  - Emit summary JSON, report HTML, image index JSON, and logs for pass/fail outcomes.
  - Preserve additive schema evolution and compatibility mapping.
- Requirement coverage:
  - CLI-DC-010, CLI-DC-020, CLI-DC-021, CLI-FR-030, CLI-FR-031, CLI-FR-041, CLI-NFR-030.

### CLI-IMPL-003: Validation lane automation

- Scope:
  - Add repeatable local validation for Docker Desktop linux NI image lane.
  - Add repeatable local validation for Docker Desktop windows NI image lane.
  - Add repeatable local validation for host-native LabVIEW 2026 64-bit lane.
- Requirement coverage:
  - CLI-FR-070, CLI-FR-071, CLI-REL-011.

### CLI-IMPL-004: Release packaging, integrity, and provenance

- Scope:
  - Package host-native release zip and runtime dependencies.
  - Publish checksums, SBOM, provenance, and signing verification procedure.
- Requirement coverage:
  - CLI-REL-001, CLI-REL-002, CLI-REL-003, CLI-REL-004, CLI-REL-010, CLI-NFR-010.

## Conversion checklist (when push resumes)

- [ ] Create remote issue for each `CLI-IMPL-*` draft.
- [ ] Link each issue from tracking issue and release checklist.
- [ ] Replace local draft identifiers with real issue numbers.
