<!-- markdownlint-disable-next-line MD041 -->
# Shared Library Notes

Reference for shared PowerShell modules used across scripts.

## Key modules

| Module | Purpose |
| ------ | ------- |
| `CompareVi.Shared` | Common helpers (path resolution, error handling) |
| `Pester-Invoker` | Step-based Pester execution (see ADR 0001) |
| `Dev-Dashboard` | Telemetry loaders/renderers |

## Usage

Import modules from `scripts/` or `tools/` using `Import-Module` (avoid dot-sourcing). Example:

```powershell
Import-Module ./scripts/CompareVI.Shared.psm1 -Force
```

## Packaging notes

- Modules target PowerShell 7.
- Run `node tools/npm/run-script.mjs build` to rebuild TypeScript utilities that produce shared outputs.
- Keep exported functions documented via comment-based help for discoverability.

Related docs: [`docs/DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md), [`docs/USAGE_GUIDE.md`](./USAGE_GUIDE.md).
