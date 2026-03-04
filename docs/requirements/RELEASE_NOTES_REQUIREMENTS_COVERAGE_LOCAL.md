<!-- markdownlint-disable-next-line MD041 -->
# Local Release Notes: Requirements Coverage Enforcement

## Scope

This local iteration implemented policy-driven requirements coverage enforcement and expanded traceability coverage for
requirement IDs in the CLI requirements catalog.

## Included commits

- `9170986` feat(#215): add policy-driven requirements coverage gate
- `1ab9ddc` test(#215): add companion requirement trace coverage
- `fcec122` test(#215): raise companion trace coverage to full catalog
- `ca72e41` docs(#215): add requirements coverage execution test plan

## Highlights

- Added policy-controlled coverage threshold support and requirement-catalog denominator handling in
  `tools/Verify-RequirementsGate.ps1`.
- Added local threshold update tooling via `tools/Set-RequirementsCoverageTarget.ps1` and npm script
  `requirements:coverage:set`.
- Enforced requirements coverage gate from local pre-commit flow in `tools/hooks/core/pre-commit.mjs`.
- Added companion trace coverage tests in `tests/RequirementsCoverageCompanion.Tests.ps1`.
- Added execution runbook in `docs/requirements/REQUIREMENTS_COVERAGE_TEST_PLAN.md`.

## Validation summary

- Requirements gate status: pass.
- Coverage metrics: 30/30 covered (100.0%), target 50.0%.
- Companion suite: pass (`tests/RequirementsCoverageCompanion.Tests.ps1`).
- Gate regression suite: pass (`tests/RequirementsVerificationGate.Tests.ps1`).
- Hook regression suite: pass (`tools/hooks/__tests__/*.mjs`).

## Notes

- All changes are local-only at this stage (no push performed).
- Transient cache/router artifacts were excluded from committed changes.
