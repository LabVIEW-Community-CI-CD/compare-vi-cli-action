# Auto Issue Branch Creator 🌿

Creates a branch for an issue when the issue has all required metadata:

- Title of 30 characters or fewer
- Milestone assigned
- At least one assignee
- Labeled with `feature`, `bug`, or `task`
- Added to a project

Branches are named `issue-<number>-<short-title>` and are only created for
`feature` or `bug` issues. The issue type also determines a semantic version
bump (`feature` ⇒ major, `bug` ⇒ minor).

## Inputs
| Name | Required | Example | Description |
|------|----------|---------|-------------|
| `base_branch` | No | `main` | Base branch to create new branches from. Defaults to repository default branch. |

## Outputs
| Name | Example | Description |
|------|---------|-------------|
| `branch` | `issue-123-add-feature` | Name of created branch. |
| `version_bump` | `major` | Semantic version bump inferred from issue type. |

## Quick-start
```yaml
- uses: ./.github/actions/auto-issue-branch
  with:
    base_branch: main
```

## Testing
This action's core logic is unit tested with Node's built-in test runner:

```bash
node --test .github/actions/auto-issue-branch/utils.test.js
```

Run the tests after making changes to ensure branch naming and version bump
logic behave as expected.

## License
This directory inherits the repository's [MIT license](../../LICENSE).
