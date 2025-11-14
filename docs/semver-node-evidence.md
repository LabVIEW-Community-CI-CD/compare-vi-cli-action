# SemVer & Node Pinning Evidence

## Goal
Ensure `compare-vi-cli-action` inherits the same SemVer validation tooling used in `labview-icon-editor` and pins its runtime to Node.js 20.x to avoid regressions.

## Prepared Actions
1. **Reusable SemVer script**: `src/tools/priority/validate-semver.mjs` (plus `npm run semver:check`) is now portable; copy it verbatim into the action repo or run `pwsh -File tools/Export-SemverBundle.ps1` to grab a ready-made bundle. Use `-IncludeWorkflow` to pick up a GitHub workflow template + import checklist, `-TargetRepoRoot <path>` when you want the files copied directly into another checkout, and `-GenerateIssueTemplate` for a ready-to-paste GitHub issue comment. Every bundle includes `bundle.json` with commit metadata and SHA256 hashes so recipients can verify integrity, and you can double-check after copying via `pwsh -File tools/Verify-SemverBundle.ps1 -BundlePath <bundle>`.
2. **Build/toolchain manifest**: root `package.json` documents every Node-based helper so the action repo can mirror the scripts without guessing dependencies.
3. **Documentation hook**: `docs/quickstart-dev.md` explains the Node install + `npm run build` flow you can reference when porting instructions upstream.
4. **Issue Goal**: “Adopt the shared SemVer tooling and pin Node 20.x in compare-vi-cli-action so release checks match labview-icon-editor.”

## Evidence Snapshot
- SemVer check succeeds locally with the new manifest:
  ```bash
  npm run semver:check
  # => schema priority/semver-check@v1, version 0.1.0-rc.0, valid true
  ```
- Node toolchain pinned via `packageManager: "npm@11.6.2"` and `engines.node >=20.11.0` for reproducibility.
- TypeScript build (`tsconfig.cli.json`) + docs updates show how tooling is compiled before downstream repos consume it.

## Next Steps for the Issue
1. Copy `src/tools/priority/validate-semver.mjs` and add the `semver:check` script to `compare-vi-cli-action` (include the same `package.json` version/engines block).
2. Update the action repo’s workflows to call `actions/setup-node@v4` with `node-version: 20` (or add the equivalent matrix entry) before running npm.
3. Comment on the issue with this evidence snippet and mark the goal complete once the action repo changes are merged.
