#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function extractWorkflowJobSection(workflow, jobName, nextJobName = null) {
  const escapedJobName = jobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const boundary = nextJobName
    ? `\\r?\\n\\s{2}${nextJobName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}:`
    : '$';
  const pattern = new RegExp(`${escapedJobName}:\\s*\\r?\\n([\\s\\S]*?)${boundary}`);
  const match = workflow.match(pattern);
  assert.ok(match, `Expected to locate workflow section for ${jobName}`);
  return match[1];
}

test('validate workflow centralizes VI-history dispatch planning before Linux lane execution', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const planSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-plan', 'vi-history-scenarios-linux');

  assert.match(workflow, /vi-history-scenarios-plan:/);
  assert.match(workflow, /Resolve VI history dispatch plan/);
  assert.match(workflow, /tools\/Resolve-ValidateVIHistoryDispatchPlan\.ps1/);
  assert.match(workflow, /-EnableScopedExecution:\$enableScopedExecution/);
  assert.match(workflow, /-ScopedSkipReason \$env:VALIDATE_SCOPE_VI_HISTORY_REASON/);
  assert.match(workflow, /execute_lanes:\s+\$\{\{\s*steps\.plan\.outputs\.execute_lanes\s*\}\}/);
  assert.match(workflow, /history_scenario_set:\s+\$\{\{\s*steps\.plan\.outputs\.history_scenario_set\s*\}\}/);
  assert.match(planSection, /permissions:\s*\r?\n\s+contents: read/);
  assert.doesNotMatch(planSection, /pull-requests: read/);
  assert.doesNotMatch(planSection, /uses: actions\/checkout@v5\s*\r?\n\s+with:\s*\r?\n\s+fetch-depth: 0/);
});

test('validate workflow Linux VI-history lane consumes shared dispatch-plan outputs', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const linuxSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-linux', 'vi-history-scenarios-windows-plan');

  assert.match(workflow, /vi-history-scenarios-linux:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(workflow, /Append VI history Linux lane plan/);
  assert.match(workflow, /Print VI history Linux runtime alignment/);
  assert.match(workflow, /Project VI history Linux Docker-side evidence/);
  assert.match(workflow, /tools\/Write-VIHistoryLaneEvidence\.ps1/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.execute_lanes == 'true'/);
  assert.match(workflow, /needs\.vi-history-scenarios-plan\.outputs\.history_scenario_set/);
  assert.match(linuxSection, /Show Linux live Docker evidence/);
  assert.match(linuxSection, /Show-NIContainerCaptureEvidence\.ps1/);
  assert.doesNotMatch(workflow, /Resolve VI history Linux lane execution mode/);
  assert.doesNotMatch(workflow, /vi-history-scenarios-skip-note:/);
  assert.match(linuxSection, /permissions:\s*\r?\n\s+contents: read/);
  assert.doesNotMatch(linuxSection, /pull-requests: read/);
});

test('validate workflow Windows VI-history lane is gated by shared dispatch planning and self-hosted docker execution', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const planSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-windows-plan', 'vi-history-scenarios-windows');
  const windowsSection = extractWorkflowJobSection(workflow, 'vi-history-scenarios-windows', 'vi-history-scenarios-windows-lv32-plan');

  assert.match(workflow, /vi-history-scenarios-windows-plan:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(planSection, /permissions:\s*\r?\n\s+contents: read/);
  assert.match(planSection, /Resolve self-hosted Windows Docker lane/);
  assert.match(planSection, /tools\/Resolve-SelfHostedWindowsLanePlan\.ps1/);
  assert.match(planSection, /-RequiredLabels \$requiredLabels/);
  assert.match(planSection, /docker-lane/);
  assert.match(planSection, /outputs:\s*\r?\n\s+available:\s+\$\{\{\s*steps\.plan\.outputs\.available\s*\}\}/);

  assert.match(workflow, /vi-history-scenarios-windows:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan, vi-history-scenarios-windows-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true' && needs\.vi-history-scenarios-plan\.outputs\.execute_lanes == 'true' && needs\.vi-history-scenarios-windows-plan\.outputs\.available == 'true'/);
  assert.match(windowsSection, /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress, docker-lane\]/);
  assert.match(windowsSection, /continue-on-error:\s*true/);
  assert.match(windowsSection, /Print VI history Windows runtime alignment/);
  assert.match(windowsSection, /Validate self-hosted runner label contract/);
  assert.match(windowsSection, /Assert-RunnerLabelContract\.ps1/);
  assert.match(windowsSection, /Collect self-hosted Windows runner health/);
  assert.match(windowsSection, /Collect-RunnerHealth\.ps1/);
  assert.match(windowsSection, /Project VI history Windows Docker-side evidence/);
  assert.match(windowsSection, /tools\/Write-VIHistoryLaneEvidence\.ps1/);
  assert.match(windowsSection, /Test-WindowsNI2026q1HostPreflight\.ps1/);
  assert.match(windowsSection, /-ExecutionSurface 'desktop-local'/);
  assert.match(windowsSection, /-ManageDockerEngine:\$true/);
  assert.match(windowsSection, /-AllowHostEngineMutation:\$true/);
  assert.match(windowsSection, /id:\s*windows-preflight/);
  assert.match(windowsSection, /Run-NIWindowsContainerCompare\.ps1/);
  assert.match(windowsSection, /if:\s*steps\.windows-preflight\.outputs\.windows_host_preflight_status == 'ready'/);
  assert.match(windowsSection, /Restore Docker Desktop context after Windows proof/);
  assert.match(windowsSection, /Invoke-DockerRuntimeManager\.ps1/);
  assert.match(windowsSection, /tests\/results\/local-parity\/windows\/_agent\/runner-health\.json/);
  assert.match(windowsSection, /ni-windows-container-stdout\.txt/);
  assert.match(windowsSection, /ni-windows-container-stderr\.txt/);
});

test('validate workflow self-hosted Windows LV32 VI-history lane is gated by inventory planning and headless proof receipts', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const planSection = extractWorkflowJobSection(
    workflow,
    'vi-history-scenarios-windows-lv32-plan',
    'vi-history-scenarios-windows-lv32'
  );
  const lv32Section = extractWorkflowJobSection(workflow, 'vi-history-scenarios-windows-lv32');

  assert.match(workflow, /vi-history-scenarios-windows-lv32-plan:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true'/);
  assert.match(planSection, /Resolve self-hosted Windows LV32 lane/);
  assert.match(planSection, /tools\/Resolve-SelfHostedWindowsLanePlan\.ps1/);
  assert.match(planSection, /GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN\s*\}\}/);
  assert.match(planSection, /GH_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN\s*\}\}/);
  assert.match(planSection, /required_labels:\s+\$\{\{\s*steps\.plan\.outputs\.required_labels\s*\}\}/);
  assert.match(workflow, /vi-history-scenarios-windows-lv32:\s*\r?\n\s+needs:\s*\[smoke-gate, lint, session-index, session-index-v2-contract, vi-history-scenarios-plan, vi-history-scenarios-windows-lv32-plan\]\r?\n\s+if:\s+needs\.smoke-gate\.outputs\.skip != 'true' && needs\.vi-history-scenarios-plan\.outputs\.execute_lanes == 'true' && needs\.vi-history-scenarios-windows-lv32-plan\.outputs\.available == 'true'/);
  assert.match(lv32Section, /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress, labview-2026, lv32\]/);
  assert.match(lv32Section, /Validate self-hosted runner label contract/);
  assert.match(lv32Section, /Assert-RunnerLabelContract\.ps1/);
  assert.match(lv32Section, /GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN\s*\}\}/);
  assert.match(lv32Section, /GH_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN\s*\}\}/);
  assert.match(lv32Section, /Capture LabVIEW 2026 host-plane diagnostics/);
  assert.match(lv32Section, /Write-LabVIEW2026HostPlaneDiagnostics\.ps1/);
  assert.match(lv32Section, /-OutputPath \$reportPath/);
  assert.match(lv32Section, /Run VI history shadow proof on the self-hosted LV32 runner/);
  assert.match(lv32Section, /Compare-VIHistory\.ps1/);
  assert.match(lv32Section, /Invoke-LVCompare\.ps1/);
  assert.match(lv32Section, /Write VI history LV32 shadow proof receipt/);
  assert.match(lv32Section, /Write-VIHistoryLV32ShadowProofReceipt\.ps1/);
  assert.match(lv32Section, /\$receiptArgs = @\{/);
  assert.match(lv32Section, /RunnerLabelContractPaths = \$runnerContractPaths/);
  assert.match(lv32Section, /& \$receiptScriptPath @receiptArgs/);
  assert.match(lv32Section, /LABVIEW_PATH:\s*\$\{\{\s*steps\.host-plane\.outputs\.labview_path\s*\}\}/);
  assert.doesNotMatch(lv32Section, /windows-2022/);
});
