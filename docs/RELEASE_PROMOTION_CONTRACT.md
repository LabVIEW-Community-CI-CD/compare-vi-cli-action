<!-- markdownlint-disable-next-line MD041 -->
# Release Promotion Contract (v1)

This document defines the promotion contract for the Platform v1 standing-priority
lane (#710). It is the policy source for release/promotion channels, required check
alignment, and evidence ledger expectations.

## Contract source of truth

- Policy file: `tools/policy/promotion-contract.json`
- Ledger schema: `docs/schemas/promotion-evidence-ledger-v1.schema.json`
- Alignment assertion: `tools/Assert-PromotionContractAlignment.ps1`
- Ledger writer: `tools/Write-PromotionEvidenceLedger.ps1`
- Certification matrix policy: `tools/policy/certification-matrix.json`
- Certification matrix schema: `docs/schemas/certification-matrix-v1.schema.json`
- Certification runbook: `docs/CERTIFICATION_MATRIX.md`
- Supply-chain trust gate script: `tools/priority/supply-chain-trust-gate.mjs`
- Supply-chain trust gate schema: `docs/schemas/supply-chain-trust-gate-v1.schema.json`
- Rollback policy: `tools/policy/release-rollback-policy.json`
- Rollback command: `tools/priority/rollback-release.mjs`
- Rollback drill health gate: `tools/priority/rollback-drill-health.mjs`
- Rollback report schemas:
  - `docs/schemas/release-rollback-v1.schema.json`
  - `docs/schemas/release-rollback-drill-health-v1.schema.json`

## Channels

- `rc`
  - Version pattern: `X.Y.Z-rc.N`
  - Approval gate required: yes
  - `latest` tag allowed: no
- `stable`
  - Version pattern: `X.Y.Z`
  - Approval gate required: yes
  - `latest` tag allowed: yes
- `lts`
  - Version pattern: `X.Y.Z`
  - Approval gate required: yes
  - `latest` tag allowed: yes

## Required-check baseline alignment

Canonical required-check lists for `develop` and `release/*` must remain in sync across:

- `tools/policy/branch-required-checks.json`
  - `branches.develop`
  - `branches.release/*`
- `tools/priority/policy.json`
  - `branches.develop.required_status_checks`
  - `branches.release/*.required_status_checks`
  - `rulesets.8811898.required_status_checks` (develop)
  - `rulesets.8614172.required_status_checks` (release/*)

The workflow context `Promotion Contract / promotion-contract` remains an operational evidence check, but it is not a
branch-protection required status on `develop` or `release/*` because the workflow is intentionally path-scoped for
pull requests.

Automation enforcement:

- Workflow check: `.github/workflows/promotion-contract.yml`
- Release/promotion workflows call `tools/Assert-PromotionContractAlignment.ps1`
  before promotion actions.

## Evidence ledger contract

Each release/promotion workflow writes a JSON ledger artifact with schema:

- `promotion-evidence-ledger/v1`

Required sections:

- `workflow` run metadata (`runId`, `event`, `ref`, `sha`, `url`)
- `promotion` context (`stream`, `channel`, `version`)
- `gate` decision (`pass|fail|blocked`) and rationale
- `contract` hash and required-check snapshot

Default artifact location:

- `tests/results/promotion-contract/*.json`

## Certification matrix gate

Release tags must generate a compatibility certification matrix artifact before promotion:

- Artifact: `tests/results/_agent/certification/release-certification-matrix.json`
- Evaluator: `node tools/priority/certification-matrix.mjs`
- Enforcement: `stable` channel only
  - `rc`: publish certification evidence without blocking.
  - `stable`: block when required lanes are stale, missing, incomplete, or failed.

Lane lifecycle (add/remove/update) is documented in `docs/CERTIFICATION_MATRIX.md`.

## Supply-chain trust gate

Release tags must pass the supply-chain trust gate before GitHub Release publication:

- Gate script: `node tools/priority/supply-chain-trust-gate.mjs`
- Report artifact: `tests/results/_agent/supply-chain/release-trust-gate.json`
- Enforced checks:
  - required artifact presence (`*.zip/*.tar.gz`, `SHA256SUMS.txt`, `sbom.spdx.json`, `provenance.json`)
  - checksum integrity
  - SBOM/provenance contract validity
  - artifact attestation verification via `gh attestation verify`

If the trust gate fails, release publication is blocked (fail-closed) and the report artifact must be used for remediation.

## Rollback drill health gate

Release tags must pass rollback drill health before GitHub Release publication:

- Weekly drill workflow: `.github/workflows/release-rollback-drill.yml`
- Health gate script: `node tools/priority/rollback-drill-health.mjs`
- Health report artifact: `tests/results/_agent/release/rollback-drill-health.json`
- Drill evidence artifact: `tests/results/_agent/release/rollback-drill-report.json`

Policy thresholds are sourced from `tools/policy/release-rollback-policy.json`:

- lookback runs
- minimum success rate
- maximum hours since latest successful drill

If the health gate fails, promotion pauses (fail-closed) until drill health is restored.

## Gate outcomes

- `pass`: promotion contract asserted and workflow completed successfully.
- `fail`: assertion or promotion workflow failed.
- `blocked`: workflow cancelled or approval gate prevented completion.
