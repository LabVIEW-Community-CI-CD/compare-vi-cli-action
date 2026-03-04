<!-- markdownlint-disable-next-line MD041 -->
# CLI Practical Milestone Tracker

This tracker defines the practical milestone for graduating the CLI from
early-stage to stable external consumption.

## Milestone definition

Practical milestone is met when all four lanes are verified in real mode and
dry-run mode, externally consumable with pinned releases, and stable across
consecutive tagged releases.

Required lanes:

- `compare single`
- `compare range`
- `history run`
- `report consolidate`

## Exit criteria

### 1) Contract and compatibility

- [ ] `v1` contract policy documented and linked from release checklist
- [ ] lane schemas include additive compatibility metadata
- [ ] compatibility guidance for downstream repos published

### 2) Lane behavior and artifacts

- [ ] each lane passes dry-run contract checks
- [ ] each lane passes real-mode invocation checks
- [ ] each real-mode invocation emits expected artifacts (`summary`, `report`,
      `image-index`, `log`)

### 3) CI gate coverage

- [ ] maturity gate runs in CI on Windows
- [ ] maturity gate runs in CI on Linux
- [ ] failing lane checks block merges to protected branches

### 4) External adoption proof

- [ ] pinned-release consumption template published for external repos
- [ ] pilot integration executed in at least one external repository
- [ ] two consecutive tagged releases validated by external consumption

## Current status snapshot (2026-03-04)

- `v1.0.2` release published successfully
- release matrix + assertions validated against published assets
- post-release consolidated report generated
- remaining maturity work:
  - formal CI gate for all four lanes across OS matrix
  - external repo pilot workflow
  - release-over-release compatibility tracking

## Operational commands

Run maturity gate locally:

```powershell
node tools/npm/run-script.mjs maturity:cli:check
```

Run release real-mode matrix + assertions + consolidated report:

```powershell
node tools/npm/run-script.mjs release:cli:matrix:all:real:consolidated
```
