# Icon Editor Prepare VI Diff

Composite wrapper for `tools/icon-editor/Prepare-FixtureViDiffs.ps1`.

## Inputs
- `report-path` – path to the generated `fixture-report.json`.
- `baseline-manifest-path` – baseline `fixture-manifest.json`.
- `output-dir` – directory where requests will be emitted (e.g. `tests/results/_agent/icon-editor/vi-diff`).

## Outputs
- `requests_path` – resolved `vi-diff-requests.json`.
- `request_count` – numeric count of requests.
- `has_requests` – `'true'` when count > 0.
- `output_dir` – resolved artifact directory.

## Example
```yaml
- name: Prepare VI diff requests
  id: vi_diff
  uses: ./.github/actions/icon-editor/prepare-vi-diff
  with:
    report-path: tests/results/_agent/icon-editor/fixture-report.json
    baseline-manifest-path: tests/fixtures/icon-editor/fixture-manifest.json
    output-dir: tests/results/_agent/icon-editor/vi-diff
```
