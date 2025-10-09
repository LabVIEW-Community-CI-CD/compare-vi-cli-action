# Architecture Decision Records

This index tracks all ADRs in the repository. Add new entries at the top of the
table when decisions are recorded. See `/docs/requirements` for requirement
documents linked to each ADR.

| ADR | Title                                   | Status   | Date       | Related Requirements |
|-----|-----------------------------------------|----------|------------|----------------------|
| [0003](0003-test-decision.md) | Test Decision | Draft | 2025-10-08 | _TBD_ |
| [0001](0001-single-invoker-step-module.md) | Adopt Step-Based Pester Invoker Module | Accepted | 2025-10-08 | [`PESTER_SINGLE_INVOKER`](../requirements/PESTER_SINGLE_INVOKER.md), [`SINGLE_INVOKER_SYSTEM_DEFINITION`](../requirements/SINGLE_INVOKER_SYSTEM_DEFINITION.md) |

## Validation

Run `pwsh -File tools/Validate-AdrLinks.ps1` to ensure each requirement file
references an existing ADR.

## Creating a New ADR

Use the helper script to scaffold a new decision record and update this index:

```powershell
pwsh -File tools/New-Adr.ps1 -Title 'My Decision Title' -Status Draft -Requirements PESTER_SINGLE_INVOKER
```

Then fill in the context/decision sections, update the requirements’ traceability
entries, and run the validation script.
