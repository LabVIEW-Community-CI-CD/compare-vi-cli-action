## Summary

- diff VIP-contained VIs during simulation by unpacking the fixture VIP and generating `vi-diff-requests@v1`
- reuse `Invoke-FixtureViDiffs.ps1` + `Render-ViComparisonReport.ps1` to build a comparison summary and Markdown report
- upload `icon-editor-vip-vi-diff-captures` and `icon-editor-vip-vi-comparison-report` artifacts in simulation
- add tests (`tests/Simulate-IconEditorVipDiff.Tests.ps1`) and doc updates (`docs/ICON_EDITOR_PACKAGE.md`)

## Implementation

- tools/icon-editor/Prepare-VipViDiffRequests.ps1
- tools/icon-editor/Simulate-IconEditorBuild.ps1 (+ VipDiff params and manifest node)
- .github/workflows/validate.yml (simulation branch: request gen + dry-run compare + report upload)
- tools/icon-editor/Render-ViComparisonReport.ps1 hardened for missing artifact props

## Testing

- Local: `Invoke-PesterTests.ps1 -TestsPath tests/Simulate-IconEditorVipDiff.Tests.ps1`
- Validate: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/19020706233 (success)

Notes:
- Comparisons run in dry-run during simulation to avoid launching LabVIEW; enable full LVCompare if needed later.

Resolves #576.
