<!-- markdownlint-disable-next-line MD041 -->
# Codex streaming failure root cause

## Summary

Codex fails to start in this repository when it walks the workspace and exceeds the
streaming payload limits. The scan loops through `vscode/comparevi-helper/node_modules`
because that dependency tree contains a symlink named `compare-vi-cli-action` that
points back to the repository root. The recursive traversal causes Codex to re-ingest
the entire workspace repeatedly until the stream cap trips.

## Evidence

- The VS Code helper extension depends on the local action via `"compare-vi-cli-action": "file:../.."` in
  `vscode/comparevi-helper/package.json`. `npm install` materialises that dependency as a symlink that
  targets the repository root.
- Inspecting the installed package shows the symlink:

  ```bash
  $ ls -l vscode/comparevi-helper/node_modules/compare-vi-cli-action
  lrwxrwxrwx 1 root root 8 Oct 18 03:08 vscode/comparevi-helper/node_modules/compare-vi-cli-action -> ../../..
  ```

  Any recursive file walker following that link re-enters the workspace root under `node_modules`, creating
  an unbounded traversal.
- Tools that honour `.openai-ignore` still recurse because the path resolves outside the ignored directory
  list once the symlink is followed. Manual scans (`grep -R`, repository indexers) report
  "recursive directory loop" warnings, matching the behaviour Codex surfaces as a streaming failure.

## Mitigation

- Extend `.openai-ignore` to cover every `node_modules` directory (via `**/node_modules/`) and explicitly skip
  the `vscode/comparevi-helper/node_modules/compare-vi-cli-action/` symlink. This prevents Codex from attempting
  to resolve the loop during workspace ingestion.
- If Codex still follows the symlink despite the ignore list, temporarily remove or rename the dependency link
  before starting Codex (`rm vscode/comparevi-helper/node_modules/compare-vi-cli-action`). Re-run
  `npm install` after the Codex session to restore the local package link.
- Longer term, replace the file-based dependency with a published tarball or workspace protocol once the helper
  extension is stable. Eliminating the symlink removes the recursion hazard entirely.
