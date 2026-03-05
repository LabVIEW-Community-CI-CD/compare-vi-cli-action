# Icon Editor Prepare Fixture

Composite action wrapper for `tools/icon-editor/Update-IconEditorFixtureReport.ps1`.

## Inputs
- `results-root`: target directory for fixture artifacts (`tests/results/_agent/icon-editor` by default).
- `fixture-path`: optional VIP fixture override.
- `manifest-path`: optional manifest destination.
- `resource-overlay-root`, `skip-doc-update`, `no-summary` to mirror script switches.

## Outputs
- `report-json`, `report-markdown`, `manifest-json`, `results-root` paths.

## Example
```yaml
- name: Refresh icon-editor fixture snapshot
  uses: ./.github/actions/icon-editor/prepare-fixture
  with:
    skip-doc-update: 'true'
```
