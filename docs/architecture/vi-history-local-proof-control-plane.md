# VI History Local Proof Control Plane

## Scope

This control plane covers the local-first VI History proof surfaces that should
be exercised before another hosted run is chosen.

## Surface View

| Surface | Responsibility | Technology |
| --- | --- | --- |
| Windows workflow replay surface | Reproduce `vi-history-scenarios-windows` locally with a workflow-grade receipt | Node.js + PowerShell + Docker Desktop |
| Clone-backed live-history candidate surface | Govern and validate the downstream repo clone and target VI that local VI History iteration should use | Node.js + Git |
| Local refinement surface | Run proof, `dev-fast`, `warm-dev`, and `windows-mirror-proof` profiles with canonical receipts | PowerShell + Docker |
| Local operator-session surface | Wrap local refinement into a stable operator-facing session contract | PowerShell |
| Workflow-readiness surface | Normalize lane state into a bounded verdict and recommendation | PowerShell |
| Local autonomy surface | Emit ranked local guidance and the next step for VI History work | Node.js + assurance packet |

## Component View

| Component | Container | Responsibility |
| --- | --- | --- |
| `vi-history-live-candidate.json` | Clone-backed live-history candidate surface | Name the governed downstream repo, clone-root contract, and target VI path for real-history local iteration |
| `windows-workflow-replay-lane.mjs` | Windows workflow replay surface | Govern `vi-history-scenarios-windows` local replay |
| `Invoke-VIHistoryLocalRefinement.ps1` | Local refinement surface | Emit profile-specific local refinement receipts, review-loop receipts, and benchmarks |
| `Invoke-VIHistoryLocalOperatorSession.ps1` | Local operator-session surface | Emit the canonical local operator-session contract for common profiles |
| `Write-VIHistoryWorkflowReadiness.ps1` | Workflow-readiness surface | Emit `vi-history/workflow-readiness@v1` with lifecycle and recommendation |
| `vi-history-local-ci.mjs` | Local autonomy surface | Validate clone-backed candidate readiness, emit report, ranked backlog, proof checks, and next-step escalation packets |

## Design Constraints

- VI History should stay packetized separately from the Pester service model.
- The governed live-history candidate should remain explicit and
  machine-readable instead of being implied by incidental docs or sample
  fixtures.
- The local VI History packet should reuse the shared
  `windows-docker-desktop-ni-image` proof surface when the current host cannot
  satisfy the Windows replay lane.
- The local VI History packet should keep live Windows workflow replay as an
  explicit next-step escalation once the shared Windows surface and clone-backed
  candidate are ready, rather than invoking the replay lane implicitly during
  packet selection.
- The governed Windows workflow replay lane should own bounded helper-process
  timeouts so the autonomy loop cannot be left hanging after a live replay
  attempt.
- A passing governed Windows workflow replay receipt should be consumable by
  the local autonomy surface so the loop advances instead of requesting the
  same replay step repeatedly.
- Local proof should prefer declared profiles and wrappers over free-form helper
  invocation.
