<!-- markdownlint-disable-next-line MD041 -->
# Downstream Develop Promotion Contract

`downstream/develop` is the consumer proving rail between internal integration and release.
It is not a second feature-development branch.

## Contract source of truth

- Policy file: `tools/policy/downstream-promotion-contract.json`
- Workflow: `.github/workflows/downstream-promotion.yml`
- Required check context: `Downstream Promotion / downstream-promotion`
- Manifest generator: `tools/priority/downstream-promotion-manifest.mjs`
- Manifest schema: `docs/schemas/downstream-promotion-manifest-v1.schema.json`
- Default output: `tests/results/_agent/promotion/downstream-develop-promotion-manifest.json`
- Proving scorecard generator: `tools/priority/downstream-promotion-scorecard.mjs`
- Proving scorecard schema: `docs/schemas/downstream-promotion-scorecard-v1.schema.json`
- Proving scorecard output: `tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json`
- Template-agent verification lane report: `tests/results/_agent/promotion/template-agent-verification-report.json`
- Authoritative template verification overlay: `tests/results/_agent/promotion/template-agent-verification-report.local.json`, projected during bootstrap from the latest matching downstream proving artifact for the current `develop` source SHA
- Supported template-proof authority synthesis: `tests/results/_agent/promotion/template-agent-verification-report.supported.json`, projected from the latest supported `template-smoke` `workflow_dispatch` proof on a supported consumer fork when that proof is aligned to the current canonical template head
- Selection resolver: `tools/priority/resolve-downstream-proving-artifact.mjs`
- Selection schema: `docs/schemas/downstream-proving-selection-v1.schema.json`
- Selection output: `tests/results/_agent/release/downstream-proving-selection.json`

## Branch contract

- Source ref: `upstream/develop`
- Target branch: `downstream/develop`
- Target branch class: `downstream-consumer-proving-rail`
- Direct feature development on `downstream/develop`: unsupported

Every promotion into `downstream/develop` must be explainable from immutable inputs.
At minimum that means:

- exact `upstream/develop` commit SHA
- CompareVI.Tools release identity
- `comparevi-history` release identity
- scenario-pack or corpus identity
- cookiecutter/template identity
- pinned `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate@v0.1.1` release
- pinned `cookiecutter==2.7.1` runtime for hosted conveyor proofs
- proving scorecard reference
- actor and timestamp

## Post-iteration template verification lane

One logical delivery lane is reserved for post-iteration verification against
`LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`.
The broader fabric may scale up to eight logical lanes, but the effective lane
cap is derived from the host RAM budget instead of being treated as a fixed
always-on count.

- policy source: `tools/priority/delivery-agent.policy.json`
- reservation contract:
  - `reservedSlotCount = 1`
  - `minimumImplementationSlots = 3`
  - `executionMode = hosted-first`
  - `capitalFabric.capacityMode = host-ram-adaptive`
  - `capitalFabric.maxLogicalLaneCount = 8`
- machine-readable report:
  - `tests/results/_agent/promotion/template-agent-verification-report.json`
  - local authoritative overlay:
    - `tests/results/_agent/promotion/template-agent-verification-report.local.json`
  - authority sync receipt:
    - `tests/results/_agent/promotion/template-agent-verification-sync.json`

The reserved lane renders the pinned template dependency through the hosted
tools-image container on Ubuntu, then verifies the same pinned release on
Windows as the mirrored consumer-proof plane. The released template
dependency is treated as a conveyor-belt input, not a floating branch:

- template repository: `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`
- template ref: `v0.1.1`
- cookiecutter runtime: `2.7.1`
- Ubuntu execution plane: `ghcr.io/labview-community-ci-cd/comparevi-tools:latest`
- consumer render root:
  - `tests/results/_agent/cookiecutter-bootstrap/<platform>/pinned-template-render`
- dependency receipt:
  - `tests/results/_agent/cookiecutter-bootstrap/<platform>/pinned-template-dependency.json`

The goal is to keep a continuous template-consumer feedback loop alive without
starving standing-priority implementation work. The reserved lane must emit
iteration-level metrics, timing, provenance, and a follow-up recommendation so
future agents can decide whether template verification is improving, regressing,
or stalling.

The checked-in capital-fabric policy also declares `Jarvis` as a Windows Docker
specialty lane family. The same policy now seeds `20` logical-lane identities
through `capitalFabric.logicalLaneCatalog`, while `logicalLaneActivation`
reports which identities are active versus merely seeded on the current host.
`Jarvis` can grow to multiple instances when the host RAM budget leaves
headroom, while the first recorded responsibility stays attached to a named
agent for stakeholder-facing traceability.

The checked-in report is expected to capture the landed iteration label,
iteration ref, and landed iteration head SHA so the evidence can be tied back
to one immutable turn.

After each landed iteration, the runtime supervisor refreshes the report path
with a machine-readable `pending` snapshot for the iteration. The hosted
verification run or a manual rerun can then overwrite the same file with the
final `pass`/`fail` result.

The canonical hosted overwrite path is `.github/workflows/downstream-onboarding-feedback.yml`.
When that workflow evaluates the policy target repository and policy consumer rail
branch, it refreshes the same report with the hosted run URL, status, and
duration so the reserved lane does not remain stale between local delivery turns.

Fresh standing worktrees should not treat the checked-in `pending` seed as the
latest authority by default. `tools/priority/project-template-agent-verification-authority.mjs`
has been replaced by `tools/priority/sync-template-agent-verification-report.mjs`,
which resolves the current hosted downstream-proving artifact for `develop` and,
when needed, synthesizes authority from the latest supported template proof
aligned to the canonical template head before projecting the local `.local.json`
overlay. Local consumers such as
`tools/priority/template-pivot-gate.mjs` must prefer that overlay when it is
present.

Generate the report with:

```powershell
node tools/npm/run-script.mjs priority:template:agent:verify -- `
  --iteration-label "post-merge #1635" `
  --iteration-head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa `
  --verification-status pass `
  --duration-seconds 240 `
  --run-url https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/actions/runs/123456789
```

## Replay and rollback

- `promote`
  - first-class move from `upstream/develop` into `downstream/develop`
- `replay`
  - reruns the same immutable proving inputs and emits a fresh manifest
- `rollback`
  - references a prior manifest and re-establishes a previously proven downstream state

Rollback and replay should reference a prior manifest instead of relying on ad hoc branch edits.

## CLI

Generate a manifest:

```powershell
node tools/npm/run-script.mjs priority:promote:downstream:manifest -- `
  --source-sha 2e058f794595649c2beeb1b531ca8f5401d1ead5 `
  --comparevi-tools-release v0.6.3-tools.14 `
  --comparevi-history-release v1.3.24 `
  --scenario-pack-id scenario-pack@v1 `
  --cookiecutter-template-id LabviewGitHubCiTemplate@v0.1.1 `
  --proving-scorecard-ref tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json `
  --actor SergioVelderrain
```

Then generate the downstream proving scorecard using that manifest report:

```powershell
node tools/npm/run-script.mjs priority:promote:downstream:scorecard -- `
  --success-report tests/results/_agent/onboarding/downstream-onboarding-success.json `
  --feedback-report tests/results/_agent/onboarding/downstream-onboarding-feedback.json `
  --template-agent-verification-report tests/results/_agent/promotion/template-agent-verification-report.json `
  --manifest-report tests/results/_agent/promotion/downstream-develop-promotion-manifest.json `
  --output tests/results/_agent/promotion/downstream-develop-promotion-scorecard.json
```

The command fails closed when the required immutable inputs are missing or when the local
`upstream/develop` ref resolves to a different commit than the requested source SHA.
It also fails closed when the latest template-agent verification report is missing,
unreadable, non-pass, or drifted away from
`LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate` on `downstream/develop`.

## Hosted promotion workflow

Use `.github/workflows/downstream-promotion.yml` when the proving rail should be advanced from
checked-in automation instead of ad hoc local git mutation.

The workflow:

- verifies that the requested `source_sha` still matches `upstream/develop`
- runs downstream onboarding feedback against the requested consumer repository
- records the pinned template dependency receipt for the conveyor belt
- emits `downstream-develop-promotion-manifest.json`
- emits `downstream-develop-promotion-scorecard.json`
- advances `downstream/develop` only when the downstream promotion scorecard passes

## Release consumption

Release promotion should consume the downstream proving rail through the
`Downstream Promotion` workflow artifact, not from the onboarding-only feedback
workflow.

That means release should select a successful `downstream-promotion.yml` run
whose `downstream-develop-promotion-scorecard.json`:

- reports `summary.status = pass`
- proves `targetBranch = downstream/develop`
- records `summary.provenance.sourceCommitSha` matching the release source commit

Release evidence should retain the machine-readable selection report that points
back to the exact downstream promotion run and scorecard artifact used.

## Template pivot gate

When `compare-vi-cli-action` reaches release-candidate state and the standing
queue is empty, the next move is a checked-in pivot gate rather than operator
steering.

- Policy: `tools/policy/template-pivot-gate.json`
- Evaluator: `tools/priority/template-pivot-gate.mjs`
- Output: `tests/results/_agent/promotion/template-pivot-gate-report.json`
- Target repository: `LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`

The gate only reports `ready` when all of the following are true:

- `tests/results/_agent/issue/no-standing-priority.json` exists with
  `reason = queue-empty`
- `openIssueCount = 0`
- `tests/results/_agent/handoff/release-summary.json` is valid and its version
  matches `X.Y.Z-rc.N`
- `tests/results/_agent/handoff/entrypoint-status.json` reports `status = pass`
- the policy still requires a future agent, disallows operator steering, and
  requires precise session feedback at pivot time

Run the evaluator with:

```powershell
node tools/npm/run-script.mjs priority:pivot:template
```

`ready` means a future agent may pivot into
`LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate`. `blocked` means
`compare-vi-cli-action` stays in focus until the evidence gap closes.
