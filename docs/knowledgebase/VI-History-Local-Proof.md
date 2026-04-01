# VI History Local Proof

VI History should be treated as an explicit sibling proof surface beside the
Pester service model, not as an incidental side effect of Pester work.

## Local Proof Surfaces

- `priority:workflow:replay:windows:vi-history`
  - governed Windows workflow replay for `vi-history-scenarios-windows`
- `history:local:proof`
  - canonical proof profile for local VI History refinement
- `history:local:refine`
  - `dev-fast` local refinement profile
- `history:local:operator:review`
  - operator wrapper for `dev-fast`
- `history:local:operator:warm`
  - operator wrapper for `warm-dev`
- `history:local:operator:windows-mirror:proof`
  - operator wrapper for `windows-mirror-proof`

## Design Rules

- VI History local proof should use declared profiles instead of ad hoc Docker
  commands.
- `windows-mirror-proof` is pinned to the canonical NI Windows image and should
  remain proof-oriented, not become an unmanaged acceleration shortcut.
- Workflow replay, local refinement, operator session, and workflow-readiness
  should remain separate contracts.
- When the next truthful proof surface is unavailable from the current host,
  local autonomy should emit a machine-readable escalation step instead of a
  prose-only advisory.
- The VI History packet should reuse the shared `windows-docker-desktop-ni-image` proof surface with Pester rather than inventing a second unmanaged Windows proof lane.
- When a reachable Windows Desktop is available behind WSL or another Unix coordinator, the VI History packet should consume that bridge before emitting a `windows-docker-desktop-ni-image` escalation.
- Local VI History CI should not launch the live Windows workflow replay lane merely to decide what comes next.
- Once the shared Windows surface and clone-backed live-history candidate are ready, the next step should be an explicit `vi-history-windows-workflow-replay` handoff that points at `priority:workflow:replay:windows:vi-history`.
- The governed Windows workflow replay lane should terminate or fail closed within bounded helper-process timeouts, and it should still emit a workflow receipt when a timeout occurs.
- When the replay lane runs from a UNC-backed WSL checkout through the shared
  Windows Docker surface, container-bound inputs and output targets should be
  staged into a Windows-local mount root and synchronized back to the
  requested repo paths instead of being passed straight to Docker bind mounts.
- The local VI History packet should govern one explicit clone-backed
  live-history candidate instead of leaving candidate choice implicit
  in maintainer memory.
- The current governed live-history candidate is
  `ni/labview-icon-editor` at
  `Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi`.
- Public accepted corpus targets and local live-history iteration candidates
  are allowed to differ; the corpus remains the public evidence catalog, while
  the governed live-history candidate exists to drive truthful local iteration
  against real git history.

## Canonical Artifacts

- `windows-workflow-replay-lane@v1`
- `comparevi/local-refinement@v1`
- `comparevi/local-operator-session@v1`
- `vi-history/workflow-readiness@v1`
- `vi-history-live-candidate.json`
- `vi-history/live-candidate-readiness@v1`
- `vi-history-local-next-step.json`

## Local Commands

- `npm run priority:workflow:replay:windows:vi-history`
- `npm run history:local:proof`
- `npm run history:local:refine`
- `npm run history:local:operator:review`
- `npm run history:local:operator:warm`
- `npm run history:local:operator:windows-mirror:proof`
- `npm run priority:vi-history:local-ci`
- `npm run priority:vi-history:next-step`
- `npm run priority:program:local-ci`
- `npm run priority:program:next-step`

## Shared Escalation Surface

When the current host cannot satisfy the Windows replay lane, the next truthful
step should be the shared `windows-docker-desktop-ni-image` surface. The
expected handoff packet is `vi-history-local-next-step.json`, and it should name:

- the blocked requirement
- the governing escalation requirement
- the receipt path
- the current host state
- the exact next commands to run on the Windows host

When more than one local proof packet exists, the shared selector should emit
`comparevi-local-program-next-step.json` and merge the shared
`windows-docker-desktop-ni-image` handoff across VI History and Pester instead
of leaving two independent advisories for a human to reconcile.

When the shared Windows surface and governed live-history candidate are already
ready, the VI History packet should instead emit
`vi-history-local-next-step.json` with required surface
`vi-history-windows-workflow-replay` and command:

- `npm run priority:workflow:replay:windows:vi-history`

Once that governed replay lane emits a passing
`vi-history-scenarios-windows-receipt.json`, local VI History CI should consume
that receipt as satisfied replay proof instead of continuing to re-select the
same replay step.

## Governed Live-History Candidate

The current clone-backed iteration target is governed explicitly in
`tools/priority/vi-history-live-candidate.json`:

- repo: `ni/labview-icon-editor`
- default branch: `develop`
- target VI:
  `Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi`
- expected clone root: `/tmp/labview-icon-editor`

That target was chosen because the downstream repo contains the VI on disk and
its git history is live and non-trivial. The local packet should verify the
clone, target path, and history before asking for Windows replay or hosted
proof.
