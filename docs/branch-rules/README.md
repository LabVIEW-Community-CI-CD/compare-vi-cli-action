# Branch-Specific Rules

This folder may contain branch-specific rules to document exceptions or additional requirements for a given branch. When present, CI surfaces links to these files from the Branch Protection Gate summary.

Add files as `docs/branch-rules/<branch>.md` where `<branch>` is the literal branch name (e.g., `develop`, `release/v0.6.0`, `feature/my-feature`). If a file is not present, the default `docs/BRANCH_RULES.md` applies.

Suggested content:

- Any temporary variations to required checks
- Rationale and sunset plan for deviations
- Links to issues or PRs tracking the changes
