# Template Docker Profile Requirement Review Prompt V2

## Review Goal

Review `docs/requirements/TEMPLATE_DOCKER_PROFILE_REQUIREMENT_V2.md` against
ISO/IEC/IEEE 29148 requirement-quality expectations.

Focus on residual defects in:
- singularity
- ambiguity
- completeness
- verifiability
- subject stability
- definition quality
- assumptions and dependency clarity
- verification coverage

## Repository Context

- Repository: `LabVIEW-Community-CI-CD/compare-vi-cli-action`
- This requirement defines a future Docker deployment profile contract for
  `LabviewGitHubCiTemplate`.
- The architectural boundary remains:
  - `compare-vi-cli-action` is the producer
  - `LabviewGitHubCiTemplate` is the distributor
  - generated repositories are governed consumers

## Review Instructions

Please evaluate whether V2 now provides:

1. stable subject partitioning
2. unique and usable requirement identifiers
3. sufficiently defined terms
4. explicit assumptions and dependencies
5. atomic and testable `shall` statements
6. complete acceptance and verification coverage by requirement group
7. clean separation between requirements and notes/constraints

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

### 3. Cleaned V3 Requirement Set

Only if needed.

If V2 is not ready for baseline, provide a cleaned V3 requirement set that:
- preserves the current architecture
- improves ISO 29148 alignment
- keeps atomic, testable `shall` statements
- retains requirement IDs or proposes corrected IDs where necessary

### 4. Verification Notes

Flag any requirement group whose verification method is still weak,
insufficient, or mismatched.

## Review Boundary

- Treat this as a requirement-quality review, not a code review.
- Treat the V2 file as the system-of-interest for this round.
- Use other repo files only as boundary/context background if required.
