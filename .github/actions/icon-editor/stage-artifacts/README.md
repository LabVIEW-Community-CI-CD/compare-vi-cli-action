# Icon Editor Stage Artifacts

Composite action that invokes `tools/icon-editor/Stage-BuildArtifacts.ps1` to collect build outputs into `packages`, `reports`, and `logs` buckets.

## Inputs
- `results-root` (required): source directory with icon-editor outputs.

## Outputs
- `results-root`: resolved root.
- `packages-path`, `reports-path`, `logs-path`: bucket directories.
- `summary-json`: raw JSON emitted by the PowerShell helper.

## Example
```yaml
- name: Stage icon-editor build artifacts
  uses: ./.github/actions/icon-editor/stage-artifacts
  with:
    results-root: ${{ steps.prepare.outputs.results-root }}
```
