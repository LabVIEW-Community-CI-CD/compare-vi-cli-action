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
- Release signing readiness script: `tools/priority/release-signing-readiness.mjs`
- Release signing readiness schema:
  `docs/schemas/release-signing-readiness-report-v1.schema.json`
- Rollback policy: `tools/policy/release-rollback-policy.json`
- Rollback command: `tools/priority/rollback-release.mjs`
- Rollback drill health gate: `tools/priority/rollback-drill-health.mjs`
- CompareVi.Shared migration playbook: `docs/COMPAREVI_SHARED_PACKAGE_MIGRATION.md`
- Shared-source resolution schema: `docs/schemas/release-shared-source-resolution-v1.schema.json`
- Rollback report schemas:
  - `docs/schemas/release-rollback-v1.schema.json`
  - `docs/schemas/release-rollback-drill-health-v1.schema.json`
- Release scorecard builder: `tools/priority/release-scorecard.mjs`
- Release scorecard schema: `docs/schemas/release-scorecard-v1.schema.json`
- Downstream proving selection schema: `docs/schemas/downstream-proving-selection-v1.schema.json`

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
  - `rulesets.develop.required_status_checks` (develop)
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

## CompareVI.Tools bundle certification

Release tags and Validate runs also certify the extracted `CompareVI.Tools`
bundle across the public history mode bundle:

- JSON artifact:
  `tests/results/_agent/release/comparevi-history-bundle-certification/comparevi-history-bundle-certification.json`
- Markdown artifact:
  `tests/results/_agent/release/comparevi-history-bundle-certification/comparevi-history-bundle-certification.md`
- Generator: `tools/Test-CompareVIHistoryBundleCertification.ps1`
- Verifier/renderer: `node tools/npm/run-script.mjs history:bundle:verify`

The certification must run against the extracted bundle archive, not the source
checkout, and it must prove the explicit public diagnostics bundle
`attributes`, `front-panel`, and `block-diagram` without `Unspecified`
category collapse.

The same certification surface now also attests that the extracted bundle is
producer-native for downstream `vi-history` distribution:

- `comparevi-tools-release.json` is present in the extracted archive
- `consumerContract.capabilities.viHistory` is present and marked
  `upstream-producer` / `release-bundle`
- `versionContract.authoritativeConsumerPin` is resolved
- the declared bundle import path and referenced consumer contract paths resolve
  inside the extracted bundle metadata

## Supply-chain trust gate

Release tags must pass the supply-chain trust gate before GitHub Release publication:

- Gate script: `node tools/priority/supply-chain-trust-gate.mjs`
- Report artifact: `tests/results/_agent/supply-chain/release-trust-gate.json`
- Enforced checks:
  - signed annotated release tag verification (GitHub API `git/tags` verification must be `verified=true`)
  - required artifact presence (`*.zip/*.tar.gz`, `SHA256SUMS.txt`, `sbom.spdx.json`, `provenance.json`)
  - checksum integrity
  - SBOM/provenance contract validity
  - artifact attestation verification via `gh attestation verify`

If the trust gate fails, release publication is blocked (fail-closed) and the report artifact must be used for remediation.

Authoritative signed tag publication now belongs to the release conductor control
plane:

- `.github/workflows/release-conductor.yml` may load
  `RELEASE_TAG_SIGNING_PRIVATE_KEY` and optional
  `RELEASE_TAG_SIGNING_PUBLIC_KEY`
- when signing material is present, release conductor must:
  - configure workflow-owned tag signing
  - create the signed annotated tag
  - push the tag to the authoritative remote for the target repository
- `tests/results/_agent/release/release-conductor-report.json` must record:
  - signing backend/source
  - whether the tag was created
  - whether the tag was pushed authoritatively
  - any push failure blocker

## Workflow signing readiness

Authoritative release-tag publication must also expose workflow signing readiness
before the release lane is rerun:

- Report script: `node tools/npm/run-script.mjs priority:release:signing:readiness`
- Report artifact:
  `tests/results/_agent/release/release-signing-readiness.json`

That report distinguishes:

- `codePathState`
  - whether the checked-in release conductor exposes the workflow-owned signing
    contract
- `signingCapabilityState`
  - whether repository Actions secrets actually provide the signing material
- `publicationState`
  - whether authoritative signed tag publication has already succeeded

If the report emits `externalBlocker = workflow-signing-secret-missing` or
`workflow-signing-secret-unverifiable`, promotion remains blocked by external
signing readiness and release attempts must not be rerun just to rediscover the
same missing capability.

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

## Shared-source resolution evidence

Release tags also emit a CompareVi.Shared source-resolution artifact to prove package-first selection:

- Artifact: `tests/results/_agent/release/shared-source-resolution.json`
- Source: `tools/Publish-Cli.ps1` (`release/shared-source-resolution@v1`)
- Policy: `shared-source-resolution` is required evidence for `rc`, `stable`, and `lts`.

## Release scorecard evidence

Release and monthly stability workflows emit a combined scorecard artifact:

- Script: `node tools/priority/release-scorecard.mjs`
- Schema: `release/scorecard@v1`
- Release artifact: `tests/results/_agent/release/release-scorecard.json`
- Monthly artifact: `tests/results/_agent/release/monthly-release-scorecard.json`

Scorecard blockers are fail-closed when any gate regresses:

- promotion ledger gate status not `pass`
- rollback health status not `pass`
- SLO promotion readiness gate not `pass`
- trust gate regressions for release-tag flows
- signed-tag requirement not met when enabled
- downstream proving selection report missing, invalid, or not aligned to the
  selected downstream promotion scorecard when downstream proving is required

The SLO artifact now has two distinct surfaces:

- `breaches`
  - historical operational SLO debt used for issue routing and dashboards
- `promotionGate`
  - current release-readiness status derived from active unresolved incidents and stale-budget checks

When `promotionGate` is present, `release-scorecard.mjs` uses it as the SLO blocker input instead of treating every
historical breach as an active promotion blocker. This keeps operational debt visible without permanently blocking
promotion after a workflow has already recovered.

Release workflows may also pass their own workflow id as the `candidate-workflow` when collecting SLO metrics. That
suppresses the current workflow's pre-existing unresolved-incident blocker during the in-progress remediation run, so
the first healthy tag run can heal the release lane instead of deadlocking on the incident it is actively resolving.

## Gate outcomes

- `pass`: promotion contract asserted and workflow completed successfully.
- `fail`: assertion or promotion workflow failed.
- `blocked`: workflow cancelled or approval gate prevented completion.
