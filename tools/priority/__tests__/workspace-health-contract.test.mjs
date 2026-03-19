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
  assert.match(content, /\$leaseResult = Invoke-AgentWriterLeaseAcquire/);
  assert.match(content, /\$postLeaseMode = if \(\$leaseResult -and \$leaseResult\.PSObject\.Properties\['lease'\] -and \$leaseResult\.lease\) \{\s*'required'\s*\} else \{\s*'optional'\s*\}/);
  assert.match(content, /Invoke-WorkspaceHealthGate -LeaseMode \$postLeaseMode -ReportName 'bootstrap-postlease-workspace-health\.json'/);
  assert.doesNotMatch(content, /Invoke-WorkspaceHealthGate -LeaseMode 'required' -ReportName 'bootstrap-postlease-workspace-health\.json'/);
});

test('PrePush-Checks invokes workspace health gate in optional lease mode', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /check-workspace-health\.mjs/);
  assert.match(content, /--lease-mode optional/);
  assert.match(content, /pre-push-workspace-health\.json/);
  assert.match(content, /if \(\$null -eq \$mount\) \{\s*continue\s*\}/);
});

test('PrePush NI image known-flag scenario consumes the checked-in active scenario contract', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /Run-NILinuxContainerCompare\.ps1/);
  assert.match(content, /Resolve-PrePushKnownFlagScenario/);
  assert.match(content, /prepush-known-flag-scenarios\.json/);
  assert.match(content, /Active known-flag scenario/);
  assert.match(content, /\$knownFlagScenarioContract\.flags/);
  assert.match(content, /name = if \(\$scenarioLabels\.Count -eq 0\) \{ 'baseline' \}/);
  assert.match(content, /& \$niCompareScript/);
  assert.match(content, /-LabVIEWPath \$containerLabVIEWPath/);
  assert.match(content, /-ContainerNameLabel \$activeScenarioName/);
  assert.match(content, /history-summary\.json/);
  assert.match(content, /logPath = if \(\$parts.Count -gt 7\)/);
  assert.match(content, /\$failureMarkers = @\(/);
  assert.match(content, /Select-String -Path \$resolvedEntryLogPath -SimpleMatch -Quiet -Pattern \$failureMarkers/);
  assert.match(content, /Write-PrePushKnownFlagScenarioReport/);
  assert.match(content, /Write-PrePushSupportLaneReport/);
  assert.match(content, /transport-smoke-report\.json/);
  assert.match(content, /vi-history-smoke-report\.json/);
  assert.match(content, /#### Active Known-Flag Scenario/);
  assert.match(content, /#### Transport Smoke/);
  assert.match(content, /#### VI History Smoke/);
  assert.match(content, /Active known-flag scenario '\{0\}' OK/);
  assert.doesNotMatch(content, /pwsh\s+-NoLogo\s+-NoProfile\s+-File\s+\$niCompareScript/);
  assert.doesNotMatch(content, /Render-VIHistoryReport\.ps1/);
  assert.doesNotMatch(content, /label = 'noattr'; flag = '-noattr'/);
  assert.doesNotMatch(content, /label = 'nofppos'; flag = '-nofppos'/);
  assert.doesNotMatch(content, /label = 'nobdcosm'; flag = '-nobdcosm'/);
});

test('single-container flag matrix bootstrap clears stale reports and writes per-scenario CLI logs', () => {
  const content = readRepoFile('tools/NILinux-FlagMatrixBootstrap.sh');
  assert.ok(content.includes('command -v LabVIEWCLI.sh'));
  assert.ok(content.includes('comparevi_flag_matrix_arg_has_value() {'));
  assert.ok(content.includes('scenario_log="\\${RESULTS_DIR}/\\${name}-cli-output.log"'));
  assert.ok(content.includes('rm -f "\\${scenario_report}"'));
  assert.ok(content.includes('rm -rf "\\${scenario_report_assets_dir}"'));
  assert.ok(content.includes('printf \'%s\\n\' "\\${cli_output}" > "\\${scenario_log}"'));
  assert.ok(content.includes('printf \'%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n\''));
  assert.ok(content.includes('<a href=\\"\\${name}-cli-output.log\\">cli-log</a>'));
  assert.ok(content.includes('if comparevi_flag_matrix_arg_has_value "\\$@"; then'));
  assert.ok(content.includes('COMMON_ARGS+=("true")'));
  assert.ok(content.includes('if [ "\\${exit_code}" = "1" ]; then'));
  assert.ok(content.includes('if [ "\\${has_diff_markers}" != "true" ]; then'));
});

test('PrePush includes local PSScriptAnalyzer gate for changed PowerShell files', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /function Invoke-PSScriptAnalyzerGate/);
  assert.match(content, /Get-ChangedPowerShellPaths/);
  assert.match(content, /if \(\$LASTEXITCODE -ne 0\) \{\s*continue\s*\}/);
  assert.match(content, /\n\s*break\n\s*\}/);
  assert.match(content, /Invoke-ScriptAnalyzer -Path \$path -Severity Error,Warning/);
  assert.match(content, /Invoke-PSScriptAnalyzerGate -repoRoot \$root/);
  assert.match(content, /PSScriptAnalyzer not installed; install the module or rerun with -SkipPSScriptAnalyzer\./);
  assert.doesNotMatch(content, /PSScriptAnalyzer not installed; skipping analyzer gate/);
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

test('Run-NonLVChecksInDocker exposes Docker Desktop NI Linux review-suite parity and a truthful markdown fallback', () => {
  const content = readRepoFile('tools/Run-NonLVChecksInDocker.ps1');
  assert.match(content, /\[switch\]\$NILinuxReviewSuite/);
  assert.match(content, /\[switch\]\$RequirementsVerification/);
  assert.match(content, /\[string\]\$NILinuxReviewSuiteHistoryTargetPath/);
  assert.match(content, /\[string\]\$NILinuxReviewSuiteHistoryBranchRef/);
  assert.match(content, /\[string\]\$NILinuxReviewSuiteHistoryBaselineRef/);
  assert.match(content, /\[int\]\$NILinuxReviewSuiteHistoryMaxCommitCount/);
  assert.match(content, /\.PARAMETER NILinuxReviewSuiteHistoryReviewReceiptPath/);
  assert.match(content, /\.PARAMETER DockerParityReviewReceiptPath/);
  assert.match(content, /tests\/results\/docker-tools-parity\/ni-linux-review-suite/);
  assert.match(content, /tests\/results\/docker-tools-parity\/requirements-verification/);
  assert.match(content, /tests\/results\/docker-tools-parity\/review-loop-receipt\.json/);
  assert.match(content, /tests\/results\/_agent\/verification\/docker-review-loop-summary\.json/);
  assert.match(content, /Invoke-NILinuxReviewSuite\.ps1/);
  assert.match(content, /Verify-RequirementsGate\.ps1/);
  assert.match(content, /schema = 'docker-tools-parity-review-loop@v1'/);
  assert.match(content, /review-suite-summary\.html/);
  assert.match(content, /history-report\.html/);
  assert.match(content, /history-summary\.json/);
  assert.match(content, /vi-history-review-loop-receipt\.json/);
  assert.match(content, /\$PSBoundParameters\.ContainsKey\('NILinuxReviewSuiteHistoryReviewReceiptPath'\)/);
  assert.match(content, /verification-summary\.json/);
  assert.match(content, /trace-matrix\.json/);
  assert.match(content, /recommendedReviewOrder/);
  assert.match(content, /command -v git >\/dev\/null 2>&1/);
  assert.match(content, /Get-Command git -ErrorAction SilentlyContinue/);
  assert.match(content, /git config --global --add safe\.directory \/work/);
  assert.match(content, /node:20'/);
  assert.doesNotMatch(content, /node:20-alpine/);
});

test('AGENTS documents the Docker Desktop local-first review loop for repeat passes', () => {
  const content = readRepoFile('AGENTS.md');
  assert.match(content, /Run-NonLVChecksInDocker\.ps1 -UseToolsImage/);
  assert.match(content, /Run-NonLVChecksInDocker\.ps1 -UseToolsImage -NILinuxReviewSuite/);
  assert.match(content, /iterate locally through Docker\s+Desktop first/i);
  assert.match(content, /DOCKER_TOOLS_PARITY\.md/);
});

test('Docker parity knowledgebase distinguishes current host-plane behavior from planned single-VI history follow-up', () => {
  const content = readRepoFile('docs/knowledgebase/DOCKER_TOOLS_PARITY.md');
  assert.match(content, /local-first: use Docker Desktop/i);
  assert.match(content, /Review-loop policy/);
  assert.match(content, /Targeted single-VI history follow-up/);
  assert.match(content, /touch-aware for deep branches such as `develop`/);
  assert.match(content, /NILinuxReviewSuiteHistoryTargetPath/);
  assert.match(content, /vi-history-review-loop-receipt\.json/);
  assert.match(content, /review-loop-receipt\.json/);
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
  assert.match(sessionIndexContract, /\$resolvedSchemaPath = Join-Path \$repoRoot \$schemaPath/);
  assert.match(sessionIndexContract, /\$schemaLiteValidatorPath = Join-Path \$PSScriptRoot 'Invoke-JsonSchemaLite\.ps1'/);
  assert.match(sessionIndexContract, /& \$schemaLiteValidatorPath -JsonPath \$v2Path -SchemaPath \$resolvedSchemaPath/);
  assert.doesNotMatch(sessionIndexContract, /tools\/schemas\/validate-json\.js/);
});
