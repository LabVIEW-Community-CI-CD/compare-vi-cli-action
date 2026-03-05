# Dual-Plane VS Code Workspaces

This repository ships three primary committed VS Code workspace files for the
dual-plane operating model, plus a legacy compatibility alias:

- `compare-vi-cli-action.upstream-plane.code-workspace`
- `compare-vi-cli-action.fork-plane.code-workspace`
- `compare-vi-cli-action.command-center.code-workspace`
- `compare-vi-cli-action.code-workspace` (legacy alias; opens command-center)

## Plane naming convention

Workspace folders use explicit names to prevent repo confusion:

- `PLANE_UPSTREAM__compare-vi-cli-action`
- `PLANE_FORK__compare-vi-cli-action`

The command-center workspace uses both names at once and is intended for
issues/runs/dispatch tasks.

## Directory convention (Windows)

Recommended sibling checkout layout:

```text
D:\workspace\
  compare-vi-cli-action-upstream\compare-vi-cli-action
  compare-vi-cli-action-fork\compare-vi-cli-action
```

Open the upstream-plane workspace from the upstream checkout and the fork-plane
workspace from the fork checkout. Open the command-center workspace from the
fork checkout and set/update the upstream path entry as needed for your machine.

## WSL distro guardrail

When using WSL, open this repository from a normal Linux distro (for example
`Ubuntu`) instead of `docker-desktop`. The `docker-desktop` distro does not use
the standard `/mnt/<drive>/...` mount layout, which can break terminal cwd
resolution when workspace tasks launch.

## Task wiring contract

Each shipped workspace task sets `options.cwd` to a named workspace folder
(`\${workspaceFolder:...}`) so command execution is tied to an explicit plane.
No task should rely on the currently focused terminal cwd.
