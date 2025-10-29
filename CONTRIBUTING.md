<!-- markdownlint-disable-next-line MD041 -->
# Contributing

Thank you for contributing to `compare-vi-cli-action`!

## Prerequisites

- Self-hosted Windows runner with LabVIEW 2025 Q3 installed and licensed
- LVCompare must be installed at the canonical path:
  `C:\Program Files\National Instruments\Shared\LabVIEW Compare\LVCompare.exe`;
  `LVCOMPARE_PATH` or `lvComparePath` may be used only if they resolve to this
  canonical location (no alternative install paths supported)

## Getting Started

- Fork and clone the repo
- Create a feature branch
- Run the staging smoke helper before pushing:
  - `pwsh -File tools/Test-PRVIStagingSmoke.ps1 -DryRun` to preview the plan
  - `npm run smoke:vi-stage` to run end-to-end using the baked-in `fixtures/vi-attr`
    attribute diff
  All staging runs post a summary comment and upload `vi-compare-manifest` /
  `vi-staging-XX.zip` artifacts; check the comment for links.

## Action Development Tips

- The action is composite with `pwsh` steps; prefer small changes and test incrementally
- Exit code mapping: 0 = no diff, 1 = diff; any other exit code should fail fast (outputs preserved)
- Full CLI flags are passed through `lvCompareArgs` (quotes supported)
- You can set `working-directory` to control relative path resolution for `base` and `head`

## Documentation

We use a multi-document strategy for comprehensive coverage:

- **README.md** - Quick start and basic usage (keep focused, ~600 lines max)
- **docs/USAGE_GUIDE.md** - Advanced configuration and recipes
- **docs/DEVELOPER_GUIDE.md** - Testing, building, and release process
- **docs/TROUBLESHOOTING.md** - Common issues and solutions
- **docs/COMPARE_LOOP_MODULE.md** - Loop mode details
- **docs/INTEGRATION_TESTS.md** - Test prerequisites and setup
- **docs/TESTING_PATTERNS.md** - Advanced test design patterns

### Documentation Guidelines

- Keep README focused on getting started quickly; move details to topic-specific guides
- Cross-link between documents for easy navigation
- When adding new features, update relevant guide documents
- Keep examples copy-paste friendly and accurate
- Document breaking changes prominently in README and CHANGELOG

## Style and Validation

- PRs run markdownlint and actionlint via `.github/workflows/validate.yml`
- Run `.github/workflows/test-mock.yml` on PRs (windows-latest); use smoke on self-hosted for real LVCompare
- Keep README examples accurate and executable

## Testing

See the [Developer Guide](./docs/DEVELOPER_GUIDE.md) for comprehensive testing information including:

- Running unit tests
- Running integration tests
- Test dispatcher architecture
- Continuous development workflow

Quick commands:

```powershell
# Unit tests only
./Invoke-PesterTests.ps1

# Integration tests (requires LVCompare)
$env:LV_BASE_VI = 'VI1.vi'
$env:LV_HEAD_VI = 'VI2.vi'
./Invoke-PesterTests.ps1 -IntegrationMode include
```

## Branch Protection (Maintainers)

1) In repository settings → Branches → Add rule for `main`
2) Require status checks to pass before merging:
   - `Validate`
   - `Test (mock)`
3) Optionally require linear history and dismiss stale approvals

## Repository Topics (Maintainers)

- Add topics for discoverability: `labview`, `lvcompare`, `vi`, `composite-action`, `windows`, `github-actions`

## Marketplace Listing (Maintainers)

- Ensure `action.yml` `name`, `description`, and `branding` are correct (icon: `git-merge`, color: `blue`)
- Publish the repository to GitHub Marketplace
- Update `README.md` with a Marketplace link after publication

## Releases

- Tag semantic versions (e.g., `v0.1.0`); the release workflow reads `CHANGELOG.md` to generate release notes
- After tagging, ensure README examples reference the latest stable tag

## Maintainers

- CODEOWNERS: `@svelderrainruiz`

## Git hooks & multi-plane validation

## Standing priority workflow

- `node tools/npm/run-script.mjs priority:bootstrap` - detect the current plane,
  run hook preflight (and parity when `--VerboseHooks` is supplied), and refresh
  the standing-priority snapshot/router.
- `node tools/npm/run-script.mjs priority:handoff` - ingest the latest handoff
  artifacts (`issue-summary.json`, `issue-router.json`, hook and watcher summaries)
  into the session, hydrating `$StandingPrioritySnapshot`,
  `$StandingPriorityRouter`, etc.
- `node tools/npm/run-script.mjs priority:handoff-tests` - run the
  priority/hooks/semver checks and persist results to
  `tests/results/_agent/handoff/test-summary.json` for downstream agents.
- `node tools/npm/run-script.mjs priority:release` - simulate the release actions
  described by the router; pass `--Execute` to run `Branch-Orchestrator.ps1 -Execute`
  instead of the default dry-run.
- `node tools/npm/run-script.mjs handoff:schema` — validate the hook handoff summary
  (`tests/results/_agent/handoff/hook-summary.json`) against `docs/schemas/handoff-hook-summary-v1.schema.json`.
- `node tools/npm/run-script.mjs handoff:release-schema` — validate the release summary
  (`tests/results/_agent/handoff/release-summary.json`) against `docs/schemas/handoff-release-v1.schema.json`.
- `node tools/npm/run-script.mjs semver:check` — assert the current `package.json` version complies with SemVer 2.0 via
  `tools/priority/validate-semver.mjs`.

These helpers make the sandbox feel pseudo-persistent: each agent self-injects the previous session’s state before
starting work and leaves updated artifacts when finishing.

- The repository pins `core.hooksPath=tools/hooks`. Hooks are implemented as a Node core (`tools/hooks/core/*.mjs`) with
  thin shell/PowerShell shims so Linux, Windows, and CI all execute the same logic.
- Hook summaries are written to `tests/results/_hooks/<hook>.json` and include exit codes, truncated stdout/stderr, and
  notes (e.g., when PowerShell is unavailable on Linux).
- Run hook logic manually before committing/pushing:

  ```bash
  node tools/npm/run-script.mjs hooks:pre-commit
  node tools/npm/run-script.mjs hooks:pre-push
  ```

  Passing `HOOKS_PWSH=/path/to/pwsh` or `HOOKS_NODE=/path/to/node` overrides discovery if needed.

- Additional helpers:

  ```bash
  node tools/npm/run-script.mjs hooks:plane     # show detected plane + enforcement mode
  node tools/npm/run-script.mjs hooks:preflight # verify dependencies for the current plane
  node tools/npm/run-script.mjs hooks:multi     # run shell + PowerShell wrappers and diff JSON
  node tools/npm/run-script.mjs hooks:schema    # validate summaries against the v1 schema
  ```

- Control behaviour via `HOOKS_ENFORCE=fail|warn|off` (default: `fail` in CI, `warn` locally). Failures become warnings
  when enforcement is `warn`, and are suppressed entirely when set to `off`.

- PowerShell-specific lint (inline-if, dot-sourcing, PSScriptAnalyzer) only runs when `pwsh` is available; otherwise the
  hook marks those steps as `skipped` and records a note in the summary.

- The CI parity job ensures Windows and Linux shims stay in sync—if hook outputs drift, the workflow fails with a diff.

## Documentation Style

Markdown lint configuration intentionally disables the MD013 (line length) rule globally. Rationale:

- Technical tables, JSON fragments, and schema / command examples often exceed 160 chars and wrapping them reduces
  readability.
- Large refactor risk: historical sections (dispatcher notes, loop mode tuning) rely on long inline code spans.

Guidelines:

- Prefer wrapping narrative paragraphs to a reasonable width (~120–160) for new content, but do not hard-wrap within
  embedded JSON, PowerShell code fences, or tables.
- Break up extremely long explanatory list items (>220 chars) unless doing so fragments a schema or command.
- Use concise language; remove redundant qualifiers (e.g., "in order to" → "to").
- Keep bullet introductions on their own line before long wrapped sub-lines for scanability.

When a single long line is clearer (e.g., a one-line JSON example), keep it—no inline disable needed since MD013 is off.

If we later re-enable MD013:

1. Reintroduce a `"MD013": { "line_length": 160 }` block in `.markdownlint.jsonc`.
2. Add per-line opt-outs using `<!-- markdownlint-disable-next-line MD013 -->` above intentional long lines.
3. Avoid splitting code spans across lines solely for lint; prefer disabling for that line.

Always ensure examples remain copy/paste friendly (avoid trailing spaces, stray prompts inside code blocks).
