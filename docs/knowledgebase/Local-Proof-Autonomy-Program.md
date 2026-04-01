# CompareVI Local Proof Autonomy Program

The local proof program is the shared control plane above the packet-local
loops. Its job is to keep packet authority local while giving an LLM one
machine-readable next step across sibling proof surfaces.

## Packet Inputs

- `Pester Service Model`
  - `priority:pester:local-ci`
  - `tests/results/_agent/pester-service-model/local-ci/pester-service-model-next-step.json`
- `VI History Local Proof`
  - `priority:vi-history:local-ci`
  - `tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-next-step.json`
- `Windows Docker Shared Surface`
  - `priority:windows-surface:local-ci`
  - `tests/results/_agent/windows-docker-shared-surface/local-ci/windows-docker-shared-surface-next-step.json`

## Selection Rules

- Requirement work outranks escalation work.
- Active or regressed packet work outranks passive packet work.
- Shared escalations to the same external surface are merged into one handoff.
- The first shared external surface to merge today is the shared `windows-docker-desktop-ni-image` surface.
- The shared Windows surface may also be selected directly as requirement work instead of only appearing as a merged escalation.
- When all tracked packet-local work is complete, the program should emit a
  machine-readable post-local promotion escalation instead of `null`.
- Packet-local CI surfaces should use run-scoped audit bundle roots so a packet
  CI and the shared selector can overlap without deleting each other’s
  `surface-bundle` workspace.

## Program Commands

- `npm run priority:program:local-ci`
- `npm run priority:program:next-step`

## Canonical Artifacts

- `tests/results/_agent/local-proof-program/local-ci/comparevi-local-program-ci-report.json`
- `tests/results/_agent/local-proof-program/local-ci/comparevi-local-program-next-step.json`
- `tests/results/_agent/local-proof-program/local-ci/comparevi-local-program-ci-summary.md`

## Shared Windows Surface Rule

When both the Pester packet and the VI History packet require the shared
`windows-docker-desktop-ni-image` surface, the program selector should emit one
merged escalation packet instead of two competing advisories. That merged packet
should preserve:

- packet identities
- governing requirements
- blocked requirements
- proof-check identifiers
- receipt paths
- exact next commands

This keeps the next truthful local step bounded even when more than one packet
is waiting on the same Windows Docker Desktop + NI image proof surface.

Now that the shared Windows surface is its own packet, the program selector
should also be able to choose `Windows Docker Shared Surface` requirement work
explicitly when the next gap belongs to the shared surface itself rather than to
Pester or VI History.

## Post-Local Promotion Rule

When every tracked packet reports `next step: none`, the program should not end
with a silent `null`. It should emit one bounded promotion escalation that
states:

- local packet work is complete
- the next truthful surface is integration or hosted proof
- the governing program requirement for that transition
- the packet set whose local evidence is ready
- the stop conditions for returning from hosted proof to local packet work
