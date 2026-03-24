# Template Docker Profile Requirement Review Prompt V5

## Review Goal

Review `docs/requirements/TEMPLATE_DOCKER_PROFILE_REQUIREMENT_V5.md` against
ISO/IEC/IEEE 29148 requirement-quality expectations.

Focus on whether V5 is baseline-ready or whether any small residual edits
remain.

## Repository Context

- Repository: `LabVIEW-Community-CI-CD/compare-vi-cli-action`
- This requirement defines a future Docker deployment profile contract for
  `LabviewGitHubCiTemplate`.
- The architectural boundary remains:
  - `compare-vi-cli-action` is the Producer
  - `LabviewGitHubCiTemplate` is the distributor
  - generated repositories are governed consumers

## Review Instructions

Please evaluate whether V5 now provides:

1. stable subject partitioning
2. unique and usable requirement identifiers
3. complete definition or reference binding for external contract terms
4. explicit assumptions and dependencies
5. atomic and testable `shall` statements
6. explicit verification of `mixed` rendering
7. explicit verification of `vi-history` coexistence
8. clean separation between requirements and notes/constraints
9. unambiguous explicit ID lists where `A`-suffix IDs exist

## Requested Output

Provide the review in this structure:

### 1. Residual Findings

For each finding, include:
- severity: `high`, `medium`, or `low`
- location: requirement ID or section
- issue
- rationale
- recommended rewrite

### 2. Approval Recommendation

State one of:
- `ready-for-baseline`
- `needs-small-edits`
- `needs-substantive-rework`

### 3. Verification Notes

Flag any requirement group whose verification method is still weak,
insufficient, or mismatched.

### 4. Cleaned V6 Requirement Set

Only if V5 is not ready for baseline.

## Review Boundary

- Treat this as a requirement-quality review, not a code review.
- Treat the V5 file as the system-of-interest for this round.
- Use other repo files only as background if needed to confirm architectural
  boundary or terminology.
