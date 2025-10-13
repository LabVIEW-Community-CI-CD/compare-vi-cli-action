<!-- markdownlint-disable-next-line MD041 -->
# Architecture Decision Records

Index of ADRs. Use `tools/New-Adr.ps1` to scaffold new entries and update the table below.

| ADR | Title | Status | Date | Related requirements |
| --- | ----- | ------ | ---- | -------------------- |
| [0004](0004-session-index-v2-requirements.md) | Session Index v2 Requirements for Local CI | Proposed | 2025-10-11 | session-index |
| [0003](0003-test-decision.md) | Test Decision | Draft | 2025-10-08 | _TBD_ |
| [0001](0001-single-invoker-step-module.md) | Step-Based Pester Invoker Module | Accepted | 2025-10-08 | [`PESTER_SINGLE_INVOKER`](../requirements/PESTER_SINGLE_INVOKER.md), [`SINGLE_INVOKER_SYSTEM_DEFINITION`](../requirements/SINGLE_INVOKER_SYSTEM_DEFINITION.md) |

## Validation

```powershell
pwsh -File tools/Validate-AdrLinks.ps1
```

## Create a new ADR

```powershell
pwsh -File tools/New-Adr.ps1 -Title 'Decision Title' -Status Draft -Requirements PESTER_SINGLE_INVOKER
```

After scaffolding, fill in context/decision/consquences sections and update linked requirements.
