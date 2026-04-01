# CompareVI Local Proof Autonomy Program Control Plane

## Scope

This control plane covers the shared selector above the packet-local loops. Its
job is to aggregate packet-local next-step artifacts, rank the next truthful
local requirement, merge shared escalations, and emit a bounded post-local
promotion escalation when local packet work is complete.

## Surface View

| Surface | Responsibility | Technology |
| --- | --- | --- |
| Packet aggregation surface | Consume sibling packet reports and next-step artifacts | Node.js |
| Ranking surface | Rank requirement work ahead of escalation work across packets | Node.js |
| Shared escalation merge surface | Collapse duplicate escalations to the same external surface into one bounded handoff | Node.js |
| Post-local promotion surface | Emit the next truthful integration or hosted proof escalation once local packet work is complete | Node.js |
| Bundle workspace safety surface | Keep packet-local audit bundles run-scoped so concurrent invocations do not delete each other’s evidence | Node.js |

## Component View

| Component | Surface | Responsibility |
| --- | --- | --- |
| `comparevi-local-program-ci.mjs` | Packet aggregation surface | Run packet-local CI entrypoints and collect their reports |
| `comparevi-local-program-ci.mjs` | Ranking surface | Rank requirement candidates across packets and select the next local requirement |
| `comparevi-local-program-ci.mjs` | Shared escalation merge surface | Merge shared `windows-docker-desktop-ni-image` escalations and preserve packet metadata |
| `comparevi-local-program-ci.mjs` | Post-local promotion surface | Emit `integration-or-hosted-proof` escalation instead of `null` when local packet work is complete |
| Packet-local `*-local-ci.mjs` scripts | Bundle workspace safety surface | Materialize audit surfaces in run-scoped `surface-bundle/run-*` roots instead of deleting a shared mutable workspace |

## Design Constraints

- Requirement work should outrank escalation work.
- Shared escalations to the same external proof surface should merge into one
  packet rather than competing advisories.
- The program should not terminate at `null` once local packet work is
  complete; it should emit a bounded proof-promotion escalation.
- Packet-local local-CI surfaces should never share one mutable audit-bundle
  root across concurrent invocations.
