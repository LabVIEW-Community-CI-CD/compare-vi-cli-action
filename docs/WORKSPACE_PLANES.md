# Three-Plane VS Code Workspace Model

> Provides plane-separated VS Code workspaces so operators never accidentally
> run fork tasks against the upstream clone (or vice-versa).

## Overview

The model defines three workspace files under `workspaces/`:

| Workspace file | Purpose | Status-bar colour |
|---|---|---|
| `upstream.code-workspace` | Upstream-only operations (policy, parity, sync) | Blue `#005a9e` |
| `fork.code-workspace` | Fork-only development (tests, diffs, smoke) | Green `#1a7f37` |
| `command-center.code-workspace` | Dual-plane command center (dispatch, watch, cross-plane) | Purple `#6f42c1` |

## Directory Layout Convention

Both clones must be siblings in the same parent directory.
Use the naming convention below so the workspace paths resolve correctly:

```text
dev/
├── compare-vi-cli-action-upstream/   # canonical upstream clone
│   ├── workspaces/
│   │   ├── upstream.code-workspace
│   │   ├── fork.code-workspace
│   │   └── command-center.code-workspace
│   └── …
└── compare-vi-cli-action-fork/       # your fork clone
    ├── workspaces/
    │   ├── upstream.code-workspace
    │   ├── fork.code-workspace
    │   └── command-center.code-workspace
    └── …
```

### Setup

```bash
mkdir dev && cd dev

# 1. Clone the canonical (upstream) repo
git clone https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git \
  compare-vi-cli-action-upstream

# 2. Clone your fork
git clone https://github.com/<you>/compare-vi-cli-action.git \
  compare-vi-cli-action-fork

# 3. Open the workspace you need
code compare-vi-cli-action-upstream/workspaces/upstream.code-workspace
code compare-vi-cli-action-fork/workspaces/fork.code-workspace
code compare-vi-cli-action-upstream/workspaces/command-center.code-workspace
```

## Workspace Details

### Upstream Plane (`upstream.code-workspace`)

Open this workspace when you need to inspect or validate the canonical
repository without risk of modifying fork-specific state.

**Folder label:** `upstream — compare-vi-cli-action`

**Included tasks:**

- `Upstream: PrePush (actionlint)` — run actionlint across workflows
- `Upstream: Parity check` — report origin/upstream alignment
- `Upstream: Priority bootstrap` — refresh standing-priority snapshot
- `Upstream: Priority sync` — sync standing-priority issue data
- `Upstream: Pester (unit)` — run unit test suite
- `Upstream: Non-LV checks (docker)` — containerised lint/build gate

### Fork Plane (`fork.code-workspace`)

Open this workspace for day-to-day development on your fork.
All development tasks (tests, local diff sessions, smoke tests,
VI history) run against the fork root.

**Folder label:** `fork — compare-vi-cli-action`

**Included tasks:**

- `Fork: PrePush (actionlint)`
- `Fork: Pester (unit)` / `Fork: Pester (integration + leak sweep)`
- `Fork: Non-LV checks (docker)`
- `Fork: Priority handoff tests`
- `Fork: Verify diff session (real, stateless)` / `(stub)` / `(real)` / `(legacy noise)`
- `Fork: Smoke — VI staging label`
- `Fork: VI History — Run local suite` / `Dispatch workflow`

All tasks set `cwd` to `${workspaceFolder}` which resolves to the fork root.

### Command Center (`command-center.code-workspace`)

Open this workspace when you need both planes visible simultaneously —
for example, dispatching CI from the fork while monitoring upstream policy.

**Folder labels:** `upstream` and `fork`

Tasks use `${workspaceFolder:upstream}` or `${workspaceFolder:fork}` to
target the correct plane:

- `Command Center: Parity check (upstream)`
- `Command Center: Priority bootstrap (upstream)` / `Priority sync (upstream)`
- `Command Center: CI Watch REST (fork)` — monitor a workflow run by ID
- `Command Center: Dispatch validate (fork)`
- `Command Center: Pester (unit, fork)`
- `Command Center: PrePush (actionlint, upstream)`
- `Command Center: Priority handoff tests (fork)`
- `Command Center: Non-LV checks docker (fork)`

## Plane Identification

Each workspace assigns a distinct status-bar colour so you always know which
plane is active, even when switching quickly between VS Code windows:

- **Blue** — upstream (read-mostly, policy validation)
- **Green** — fork (read-write, active development)
- **Purple** — command center (dual-plane orchestration)

## Relation to Existing Workspace

The legacy `compare-vi-cli-action.code-workspace` at the repository root is
retained for backward compatibility.
The three-plane workspace files supersede it for operators who maintain both
an upstream and a fork clone.

## Requirements Traceability

| Requirement | Coverage |
|---|---|
| R1 Plane Separation (#665) | Folder naming convention + per-plane tasks + status-bar colour |
| R2 Deterministic Health Snapshot (#665) | Parity check and priority bootstrap tasks wired into upstream and command-center planes |
