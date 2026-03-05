<!-- markdownlint-disable-next-line MD041 -->
# DOTNET CLI PowerShell Mapping

## Status

- Owner: CI/CD maintainers
- Tracking issue: [#171](https://github.com/svelderrainruiz/compare-vi-cli-action/issues/171)
- Last updated: 2026-03-03

## Purpose

This mapping defines how existing PowerShell contracts map to the host-native `.NET` CLI contract surface described in
[`REQ-DOTNET_CLI_RELEASE_ASSET`](./DOTNET_CLI_RELEASE_ASSET.md).

## Command Mapping

| Legacy PowerShell surface | CLI command | Contract notes |
| --- | --- | --- |
| `tools/Invoke-PRVIHistory.ps1` | `history run` | Range traversal and per-pair orchestration |
| `tools/Compare-VIHistory.ps1` | `compare range` | Pair discovery and compare list normalization |
| `tools/Compare-RefsToTemp.ps1` | `compare single` / `compare range` | Temporary workspace materialization |
| `tools/Run-NIWindowsContainerCompare.ps1` | `compare single` | Exit classification fields map to outcome envelope |
| `tools/Render-VIHistoryReport.ps1` | `report consolidate` | Markdown/HTML renderer contract |
| `tools/Extract-VIHistoryReportImages.ps1` | `report consolidate` | Image index metadata output |
| `tools/Write-VIHistoryWorkflowReadiness.ps1` | `contracts validate` | Readiness envelope and gate outcome |

## Input Mapping

| PowerShell input | CLI option/input | Notes |
| --- | --- | --- |
| `-RepositoryRoot` | `--repo` | Defaults to current directory when omitted |
| `-BaseRef` | `--base` | Required for compare workloads |
| `-HeadRef` | `--head` | Required for compare workloads |
| `-TargetPath` / `-TargetPaths` | `--vi` / `--vi-list` | Single or multi-target |
| `-CompareModes` | `--mode` | Value set remains additive |
| `-MaxPairs` | `--max-pairs` | Hard cap with truncation telemetry |
| `-ResultsRoot` | `--out-dir` | Parent output directory |
| `-TimeoutSeconds` | `--timeout` | Per-item or run timeout, documented per command |
| `-Headless` policy env | `--headless` | Explicit policy opt-in in CI/non-interactive flows |

## Output Mapping

| Legacy artifact/field | CLI output | Backward-compatibility rule |
| --- | --- | --- |
| `vi-history-summary.json` | summary JSON | Existing keys remain; additions are additive |
| `vi-history-summary.md` | summary Markdown | Human-readable parity preserved |
| `vi-history-report.html` | consolidated report | Returned as resolved path in JSON |
| `vi-history-image-index.json` | image index JSON | Schema-versioned metadata |
| `resultClass` / `isDiff` / `gateOutcome` | `outcome.*` envelope | Semantic parity preserved |

## Exit Classification Mapping

- `success-no-diff` maps to pass-class (`outcome.class=pass`, `outcome.kind=no_diff`).
- `success-diff` maps to pass-class (`outcome.class=pass`, `outcome.kind=diff`).
- `failure-preflight` maps to fail-class (`outcome.class=fail`, `outcome.kind=preflight_error`).
- `failure-runtime` maps to fail-class (`outcome.class=fail`, `outcome.kind=runtime_error`).
- `failure-tool` maps to fail-class (`outcome.class=fail`, `outcome.kind=tool_error`).
- `failure-timeout` maps to fail-class (`outcome.class=fail`, `outcome.kind=timeout`).

## Compatibility Requirements

- Mapping changes shall be additive within the current schema major version.
- Legacy JSON keys consumed by workflows shall not be removed without a major schema increment.
