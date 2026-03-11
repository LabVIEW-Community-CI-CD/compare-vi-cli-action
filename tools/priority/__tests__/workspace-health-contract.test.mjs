#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('bootstrap enforces workspace health gate before and after lease acquisition', () => {
  const content = readRepoFile('tools/priority/bootstrap.ps1');
  assert.match(content, /Invoke-WorkspaceHealthGate -LeaseMode 'optional' -ReportName 'bootstrap-preflight-workspace-health\.json'/);
  assert.match(content, /Invoke-WorkspaceHealthGate -LeaseMode 'required' -ReportName 'bootstrap-postlease-workspace-health\.json'/);
});

test('PrePush-Checks invokes workspace health gate in optional lease mode', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /check-workspace-health\.mjs/);
  assert.match(content, /--lease-mode optional/);
  assert.match(content, /pre-push-workspace-health\.json/);
  assert.match(content, /if \(\$null -eq \$mount\) \{\s*continue\s*\}/);
});

test('PrePush NI image known-flag scenario uses the Linux runner with explicit LabVIEWPath', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /Run-NILinuxContainerCompare\.ps1/);
  assert.match(content, /nationalinstruments\/labview:2026q1-linux/);
  assert.match(content, /NI_LINUX_LABVIEW_PATH/);
  assert.match(content, /name = if \(\$scenarioLabels\.Count -eq 0\) \{ 'baseline' \}/);
  assert.match(content, /label = 'noattr'; flag = '-noattr'/);
  assert.match(content, /label = 'nofppos'; flag = '-nofppos'/);
  assert.match(content, /label = 'nobdcosm'; flag = '-nobdcosm'/);
  assert.match(content, /& \$niCompareScript/);
  assert.match(content, /-LabVIEWPath \$containerLabVIEWPath/);
  assert.match(content, /-ContainerNameLabel \$activeScenarioName/);
  assert.match(content, /history-summary\.json/);
  assert.match(content, /logPath = if \(\$parts.Count -gt 7\)/);
  assert.match(content, /\$failureMarkers = @\(/);
  assert.match(content, /Select-String -Path \$resolvedEntryLogPath -SimpleMatch -Quiet -Pattern \$failureMarkers/);
  assert.match(content, /VI Comparison Report flag combination scenarios OK/);
  assert.doesNotMatch(content, /pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+\$niCompareScript/);
  assert.doesNotMatch(content, /Render-VIHistoryReport\.ps1/);
});

test('single-container flag matrix bootstrap clears stale reports and writes per-scenario CLI logs', () => {
  const content = readRepoFile('tools/NILinux-FlagMatrixBootstrap.sh');
  assert.ok(content.includes('command -v LabVIEWCLI.sh'));
  assert.ok(content.includes('scenario_log="\\${RESULTS_DIR}/\\${name}-cli-output.log"'));
  assert.ok(content.includes('rm -f "\\${scenario_report}"'));
  assert.ok(content.includes('rm -rf "\\${scenario_report_assets_dir}"'));
  assert.ok(content.includes('printf \'%s\\n\' "\\${cli_output}" > "\\${scenario_log}"'));
  assert.ok(content.includes('printf \'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\''));
  assert.ok(content.includes('<a href=\\"\\${name}-cli-output.log\\">cli-log</a>'));
  assert.ok(content.includes('if [ "\\${exit_code}" = "1" ]; then'));
  assert.ok(content.includes('if [ "\\${has_diff_markers}" != "true" ]; then'));
});

test('PrePush includes local PSScriptAnalyzer gate for changed PowerShell files', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Invoke-PSScriptAnalyzerGate/);
  assert.match(content, /Get-ChangedPowerShellPaths/);
  assert.match(content, /Invoke-ScriptAnalyzer -Path \$path -Severity Error,Warning/);
  assert.match(content, /Invoke-PSScriptAnalyzerGate -repoRoot \$root/);
});

test('PrePush validates watcher telemetry via the sanitized schema wrapper', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Invoke-WatcherTelemetrySchemaGate/);
  assert.match(content, /run-script\.mjs/);
  assert.match(content, /schema:watcher:validate/);
  assert.match(content, /Invoke-WatcherTelemetrySchemaGate -repoRoot \$root/);
});

test('PrePush log tail helper uses streaming tail reads for large CLI logs', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /Get-Content -LiteralPath \$Path -Tail \$TailLines -ErrorAction SilentlyContinue/);
  assert.doesNotMatch(content, /Get-Content -LiteralPath \$resolvedEntryLogPath -Raw/);
});

test('VI history branch guards harden git ref inputs before counting commits', () => {
  const compareHistory = readRepoFile('tools/Compare-VIHistory.ps1');
  assert.match(compareHistory, /\$normalizedBranchRef\.StartsWith\('-'\)/);
  assert.match(compareHistory, /Invoke-Git -Arguments @\('rev-parse', '--verify', '--end-of-options', \$branchResolveSpec\)/);

  const fastLoop = readRepoFile('tools/Test-DockerDesktopFastLoop.ps1');
  assert.match(fastLoop, /\$normalizedBranchRef\.StartsWith\('-'\)/);
  assert.match(fastLoop, /git rev-parse --verify --end-of-options \$branchResolveSpec/);
});

test('NI Linux VI history bootstrap preserves mainline lineage semantics on error paths', () => {
  const content = readRepoFile('tools/NILinux-VIHistorySuiteBootstrap.sh');
  assert.match(content, /\\"parentIndex\\": 1/);
  assert.match(content, /suite_status="failed"/);
  assert.doesNotMatch(content, /suite_status="error"/);
});

test('Run-NonLVChecksInDocker honors explicit containerized Pester requests without filters', () => {
  const content = readRepoFile('tools/Run-NonLVChecksInDocker.ps1');
  assert.match(content, /\$PSBoundParameters\.ContainsKey\('PesterIncludeIntegration'\)/);
  assert.match(content, /\$PSBoundParameters\.ContainsKey\('PesterResultsDir'\)/);
});

test('PrePush emits deterministic incident-event report for NI known-flag failures', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Write-PrePushNIKnownFlagIncidentEvent/);
  assert.match(content, /--source-type incident-event/);
  assert.match(content, /pre-push-ni-known-flag-incident-input\.json/);
  assert.match(content, /pre-push-ni-known-flag-incident-event\.json/);
  assert.match(content, /\[pre-push\] NI known-flag incident event report:/);
});

test('policy workflows enforce workspace health gate and publish health artifacts', () => {
  const guardWorkflow = readRepoFile('.github/workflows/policy-guard-upstream.yml');
  assert.match(guardWorkflow, /Workspace health gate/);
  assert.match(guardWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);
  assert.match(guardWorkflow, /Verify deployment environment gate policy/);
  assert.match(guardWorkflow, /priority:deployment:gate-policy/);
  assert.match(guardWorkflow, /tests\/results\/_agent\/deployments\/environment-gate-policy\.json/);
  assert.match(guardWorkflow, /tests\/results\/_agent\/health\/policy-guard-workspace-health\.json/);

  const syncWorkflow = readRepoFile('.github/workflows/policy-sync.yml');
  assert.match(syncWorkflow, /Workspace health gate/);
  assert.match(syncWorkflow, /check-workspace-health\.mjs --repo-root \. --lease-mode ignore --report tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
  assert.match(syncWorkflow, /tests\/results\/_agent\/health\/policy-sync-workspace-health\.json/);
});

test('session index v2 validation uses schema-lite call sites available on clean runners', () => {
  const sessionIndexPostAction = readRepoFile('.github/actions/session-index-post/action.yml');
  assert.match(sessionIndexPostAction, /Invoke-JsonSchemaLite\.ps1 -JsonPath \$idxV2 -SchemaPath docs\/schema\/generated\/session-index-v2\.schema\.json/);
  assert.doesNotMatch(sessionIndexPostAction, /tools\/schemas\/validate-json\.js/);

  const validateWorkflow = readRepoFile('.github/workflows/validate.yml');
  assert.match(validateWorkflow, /Invoke-JsonSchemaLite\.ps1 -JsonPath \$jsonV2 -SchemaPath docs\/schema\/generated\/session-index-v2\.schema\.json/);
  assert.doesNotMatch(validateWorkflow, /tools\/schemas\/validate-json\.js/);

  const sessionIndexContract = readRepoFile('tools/Test-SessionIndexV2Contract.ps1');
  assert.match(sessionIndexContract, /\$schemaLiteValidatorPath = Join-Path \$PSScriptRoot 'Invoke-JsonSchemaLite\.ps1'/);
  assert.match(sessionIndexContract, /& \$schemaLiteValidatorPath -JsonPath \$v2Path -SchemaPath \$schemaPath/);
  assert.doesNotMatch(sessionIndexContract, /tools\/schemas\/validate-json\.js/);
});
