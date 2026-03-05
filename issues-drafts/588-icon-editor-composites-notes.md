# Issue 588 – Composite Integration Notes

- Simulate path now handled via `./.github/actions/icon-editor/simulate-build` (Validate job); real build still calls `Invoke-IconEditorBuild.ps1`.
- TODO next: wrap artifact staging (`Stage-BuildArtifacts.ps1`) and VI comparison (Prepare/Invoke/Render) via composites before removing inline PowerShell.
