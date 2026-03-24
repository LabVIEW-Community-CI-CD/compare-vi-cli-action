# Template Docker Profile Requirement Review Prompt

## Review Goal

Review the requirement draft in
`docs/requirements/TEMPLATE_DOCKER_PROFILE_REQUIREMENT_DRAFT.md` against the
quality expectations of ISO/IEC/IEEE 29148.

Focus on requirement quality, structure, ambiguity, completeness, and
verifiability. Do not redesign the underlying product strategy unless a defect
in the requirement wording makes that necessary.

## Repository Context

- Repository: `LabVIEW-Community-CI-CD/compare-vi-cli-action`
- This draft is intended for a future template/distribution contract in
  `LabviewGitHubCiTemplate`.
- The draft describes a Docker deployment profile distributed through
  cookiecutter.
- The current architectural boundary is:
  - `compare-vi-cli-action` remains the upstream platform producer
  - `LabviewGitHubCiTemplate` remains the distributor
  - generated repositories remain governed consumers

## Review Instructions

Please evaluate the draft for:

1. correctness of requirement style
2. ambiguity or multi-interpretation risk
3. compound statements that should be split
4. unverifiable or weakly verifiable language
5. missing assumptions, constraints, or acceptance criteria
6. conflicts between mandatory statements and stated non-goals
7. whether the requirement can support downstream validation and compliance

## Requested Output

Provide the review in this structure:

### 1. Findings

For each finding, include:
- severity: `high`, `medium`, or `low`
- location: specific section heading or sentence
- issue: what is wrong
- rationale: why it matters
- recommended rewrite: concrete improved wording

### 2. Cleaned Requirement Set

Produce a revised V2 requirement set that:
- keeps the original architectural intent
- improves ISO 29148 alignment
- uses clear and testable “shall” statements
- separates requirements from notes and rationale

### 3. Verification Notes

For each major requirement group, suggest an appropriate verification method:
- inspection
- analysis
- demonstration
- test

## Review Boundary

- Treat this as a requirement-quality review, not a code review.
- Do not assume undocumented implementation details are already available.
- Prefer conservative wording that can survive future governance and audit use.
