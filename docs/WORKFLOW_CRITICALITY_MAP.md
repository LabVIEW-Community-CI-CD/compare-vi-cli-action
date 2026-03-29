<!-- markdownlint-disable-next-line MD041 -->
# Workflow Criticality Map

This document classifies `.github/workflows/**` by operational criticality so
maintainers can distinguish release-path changes from platform-only or
diagnostic edits.

Use this map with:

- [`SUPPORTED_PRODUCT_BOUNDARY.md`](./SUPPORTED_PRODUCT_BOUNDARY.md)
- [`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md)
- [`RELEASE_OPERATIONS_RUNBOOK.md`](./RELEASE_OPERATIONS_RUNBOOK.md)
- [`plans/VALIDATION_MATRIX.md`](./plans/VALIDATION_MATRIX.md)

If a workflow changes role, update this map in the same pull request.

## Tier definitions

| Tier | Meaning | Default expectation |
| --- | --- | --- |
| Tier 1 - Release critical | Publishes, promotes, certifies, or repairs supported release outputs. | Treat edits as release-path changes. |
| Tier 2 - Product validation critical | Validates supported product behavior or core CI confidence for shipped surfaces. | Carry explicit validation evidence. |
| Tier 3 - Platform internal | Governs maintainer routing, policy, queueing, onboarding, or operator workflows. | Keep edits narrow and document policy/runbook impact. |
| Tier 4 - Diagnostic and proving | Manual proofs, rehearsals, deprecated compatibility lanes, or targeted diagnostics. | Use as supporting evidence, not baseline release proof. |

Release criticality is about release impact, not trigger type. A manual workflow
can still be Tier 2 when it is part of the supported product surface.

## Tier 1 - Release critical

These workflows can create, publish, promote, or prove rollback/readiness for
supported releases.

| Workflow | Role |
| --- | --- |
| `monthly-stability-release.yml` | Scheduled/manual stability cut for the supported release stream. |
| `promotion-contract.yml` | Promotion evidence and contract gate for release progression. |
| `publish-shared-package.yml` | Publishes the `CompareVi.Shared` package used by supported surfaces. |
| `publish-tools-image.yml` | Publishes the tools image relied on by release and validation lanes. |
| `release-cadence-check.yml` | Tracks freshness of the package streams cited by release operations. |
| `release-conductor.yml` | Authoritative release orchestration and tag-trust repair path. |
| `release-rollback-drill.yml` | Proves rollback readiness for stable-stream incidents. |
| `release.yml` | Authoritative tag-driven release publication path. |

## Tier 2 - Product validation critical

These workflows validate the supported compare surface, shared runtime/build
surfaces, or the core branch confidence model.

| Workflow | Role |
| --- | --- |
| `ci-orchestrated.yml` | Deterministic CI chain for core validation. |
| `code-scanning.yml` | Baseline code-scanning gate for supported branches. |
| `dotnet-shared.yml` | Validates the shared .NET library build and package path. |
| `fixture-drift.yml` | Protects canonical fixtures and drift-sensitive evidence. |
| `pester-integration-on-label.yml` | Controlled real-CLI integration coverage for change review. |
| `pester-reusable.yml` | Shared Pester execution contract used by multiple critical lanes. |
| `pester-selfhosted.yml` | Manual self-hosted real-CLI Pester lane. |
| `smoke-on-label.yml` | PR-targeted smoke path for the compare action. |
| `smoke.yml` | Core smoke workflow for the compare action. |
| `test-pester.yml` | Baseline Pester gate for PowerShell/scripts/action changes. |
| `tools-parity.yml` | Hosted parity for non-LabVIEW validation and optional review suites. |
| `validate.yml` | Primary branch and pull-request validation gate. |
| `verification.yml` | Requirements verification and traceability gate. |
| `vi-binary-gate.yml` | Validates VI binary-handling contract assumptions. |
| `vi-compare-fork.yml` | Product-facing compare path for fork pull requests. |
| `vi-compare-pr.yml` | Product-facing compare path for repository pull requests. |
| `vi-compare-refs.yml` | Product-facing manual history compare entrypoint. |
| `vi-history-compare.yml` | Product-facing VI history compare entrypoint. |
| `vi-staging-smoke.yml` | End-to-end smoke proof for the VI staging workflow. |
| `workflows-lint.yml` | Workflow lint and workflow-contract gate. |

## Tier 3 - Platform internal

These workflows are important to platform stewardship, but they are not the
public product contract.

| Workflow | Role |
| --- | --- |
| `agent-review-policy.yml` | Governs Copilot/agent review policy on PRs. |
| `ci-composite.yml` | Manual compatibility stub retained for legacy entrypoints. |
| `command-dispatch.yml` | Dispatches comment-driven maintainer commands. |
| `commit-integrity-drift-monitor.yml` | Scheduled drift monitor for commit-integrity policy. |
| `commit-integrity.yml` | Commit-history and bypass-governance enforcement. |
| `cookiecutter-bootstrap.yml` | Maintains template/bootstrap scaffolding proofs. |
| `downstream-onboarding-feedback.yml` | Tracks downstream onboarding health and hardening gaps. |
| `downstream-promotion.yml` | Advances downstream proving/promotion flows. |
| `fork-guard.yml` | Guardrail workflow for fork-compare safety logic. |
| `human-go-no-go-feedback.yml` | Captures human decision receipts for operator lanes. |
| `issue-milestone-hygiene.yml` | Governs milestone hygiene on issue intake. |
| `issue-snapshot.yml` | Maintains standing-priority issue snapshots. |
| `markdownlint.yml` | Documentation hygiene lane. |
| `merge-history.yml` | Guards PR history policy against merge commits. |
| `policy-guard-upstream.yml` | Repository policy guard for upstream branches and PRs. |
| `policy-sync.yml` | Admin synchronization of branch/ruleset policy. |
| `pr-agent-review-routing.yml` | Routes agent-authored PR review handling. |
| `pr-automerge.yml` | Enables labeled auto-merge on PRs. |
| `queue-supervisor.yml` | Supervises queue/autopilot behavior for maintainer lanes. |
| `runbook-validation.yml` | Validates maintainer/operator integration runbooks. |
| `security-intake.yml` | Scheduled/manual security-intake and routing lane. |
| `standing-priority-hygiene.yml` | Cleans standing-priority state after issue changes. |
| `validation-approval-helper.yml` | Broker/helper for validation deployment approvals. |
| `weekly-scorecard.yml` | Weekly governance scorecard and incident routing lane. |

## Tier 4 - Diagnostic and proving

These workflows provide targeted diagnostics, rehearsals, or compatibility
proofs. They are valuable, but they should not be mistaken for the baseline
release contract.

| Workflow | Role |
| --- | --- |
| `compare-artifacts.yml` | Manual artifact-only proof for compare/report outputs. |
| `labview-cli-compare.yml` | Specialized manual proof for the LabVIEW CLI compare mode. |
| `pester-diagnostics-nightly.yml` | Synthetic nightly failure diagnostics for the Pester lane. |
| `prime-lvcompare-preflight.yml` | Stubbed preflight proof for LVCompare warmup behavior. |
| `print-to-single-file-html-proof.yml` | Proof lane for single-file HTML rendering behavior. |
| `public-linux-diagnostics-harness.yml` | Dispatch harness for public Linux diagnostics proving. |
| `runtime-harness-package-rehearsal.yml` | Manual rehearsal for runtime-harness package publication. |
| `test-mock.yml` | Deprecated mock-based compatibility lane retained for manual use. |
| `windows-hosted-parity.yml` | Manual hosted-Windows NI parity proof. |

## Change rules

1. When editing a Tier 1 workflow, treat the change as release-path work and
   update the relevant release/promotion documentation in the same PR.
2. When editing a Tier 2 workflow, carry validation evidence that matches the
   affected surface and update consumer-facing docs when the supported behavior
   changes.
3. When moving a workflow between tiers, update this document, the affected
   runbook/guide references, and the PR description together.
4. Do not cite Tier 4 workflows as baseline support evidence unless another
   checked-in contract explicitly promotes that workflow into a gate.
