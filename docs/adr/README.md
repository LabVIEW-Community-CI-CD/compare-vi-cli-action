<!-- markdownlint-disable-next-line MD041 -->
# Architecture Decision Records

Index of ADRs. Use `tools/New-Adr.ps1` to scaffold new entries and update the table below.

- **[0003](0003-test-decision.md)** – Test Decision (Draft, 2025-10-08) – related requirements: _TBD_.
- **[0001](0001-single-invoker-step-module.md)** – Step-Based Pester Invoker Module (Accepted, 2025-10-08) – related
  requirements: [`PESTER_SINGLE_INVOKER`](../requirements/PESTER_SINGLE_INVOKER.md),
  [`SINGLE_INVOKER_SYSTEM_DEFINITION`](../requirements/SINGLE_INVOKER_SYSTEM_DEFINITION.md).

## Validation

```powershell
pwsh -File tools/Validate-AdrLinks.ps1
```

## Create a new ADR

```powershell
pwsh -File tools/New-Adr.ps1 -Title 'Decision Title' -Status Draft -Requirements PESTER_SINGLE_INVOKER
```

After scaffolding, fill in context/decision/consquences sections and update linked requirements.
