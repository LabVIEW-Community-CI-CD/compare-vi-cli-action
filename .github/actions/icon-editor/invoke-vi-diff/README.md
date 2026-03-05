# Icon Editor Invoke VI Diff

Composite wrapper for `tools/icon-editor/Invoke-FixtureViDiffs.ps1`.

## Inputs
- `requests-path` – path to `vi-diff-requests.json`.
- `captures-root` – destination directory for captures (e.g. `tests/results/_agent/icon-editor/vi-diff-captures`).
- `summary-path` – path for `vi-comparison-summary.json`.
- `timeout-seconds` – optional timeout (default `900`).
- `dry-run` – set to `'true'` for dry-run mode.

## Outputs
- `summary_path` – resolved summary JSON path.
- `captures_root` – resolved captures directory.
- `requests_path` – resolved requests path.

## Example
```yaml
- name: Execute VI comparisons
  id: vi_diff_run
  uses: ./.github/actions/icon-editor/invoke-vi-diff
  with:
    requests-path: ${{ steps.prepare.outputs.requests-path }}
    captures-root: tests/results/_agent/icon-editor/vi-diff-captures
    summary-path: tests/results/_agent/icon-editor/vi-diff-captures/vi-comparison-summary.json
    timeout-seconds: '900'
```
