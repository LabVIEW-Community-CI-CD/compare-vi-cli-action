# Icon Editor Render VI Report

Composite wrapper for `tools/icon-editor/Render-ViComparisonReport.ps1`.

## Inputs
- `summary-path` – path to `vi-comparison-summary.json`.
- `output-path` – optional path for the markdown report (defaults beside the summary).

## Outputs
- `report_path` – generated report path (blank if the summary was missing).

## Example
```yaml
- name: Render VI comparison report
  uses: ./.github/actions/icon-editor/render-vi-report
  with:
    summary-path: tests/results/_agent/icon-editor/vi-diff-captures/vi-comparison-summary.json
```
