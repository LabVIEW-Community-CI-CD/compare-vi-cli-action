# Icon Editor Simulate Build

Composite action that wraps `tools/icon-editor/Simulate-IconEditorBuild.ps1`.

## Inputs
- `results-root` (required): destination directory for artifacts.
- `fixture-path`: override VIP fixture path.
- `expected-version-json`: JSON for expected version object.
- `vip-diff-output-dir`, `vip-diff-requests-path`: customise VI diff staging.
- `resource-overlay-root`, `skip-resource-overlay`, `keep-extract`: mirror flags.

## Outputs
- `manifest-path`, `metadata-path`, `package-version`.
- `vip-diff-root`, `vip-diff-requests-path`, `results-root`.

## Example
```yaml
- name: Simulate icon-editor build
  uses: ./.github/actions/icon-editor/simulate-build
  with:
    results-root: ${{ runner.temp }}\icon-editor
    expected-version-json: ${{ steps.version.outputs.json }}
```
