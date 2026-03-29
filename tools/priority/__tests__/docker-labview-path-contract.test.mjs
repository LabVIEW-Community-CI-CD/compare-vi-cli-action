#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate workflow pins explicit LabVIEW paths for hosted Linux and Windows VI history lanes', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /docker pull \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);
  assert.match(workflow, /vi-history-scenarios-windows-plan:/);
  assert.match(workflow, /Resolve-HostedWindowsLanePlan\.ps1/);
  assert.match(workflow, /vi-history-scenarios-windows:/);
  assert.match(workflow, /runs-on:\s*windows-2022/);
  assert.match(workflow, /NI_WINDOWS_IMAGE:\s*nationalinstruments\/labview:2026q1-windows/);
  assert.match(workflow, /NI_WINDOWS_LABVIEW_PATH:\s*C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW\.exe/);
  assert.match(workflow, /Test-WindowsNI2026q1HostPreflight\.ps1/);
  assert.match(workflow, /Write-VIHistoryLaneEvidence\.ps1/);
  assert.match(workflow, /Run-NIWindowsContainerCompare\.ps1/);
  assert.match(workflow, /-ExecutionSurface 'github-hosted-windows'/);
  assert.match(workflow, /-Image \$env:NI_WINDOWS_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_WINDOWS_LABVIEW_PATH/);
  assert.match(workflow, /validate-vi-history-scenarios-windows/);
  assert.match(workflow, /vi-history-scenarios-windows-lv32-plan:/);
  assert.match(workflow, /Resolve-SelfHostedWindowsLanePlan\.ps1/);
  assert.match(workflow, /vi-history-scenarios-windows-lv32:/);
  assert.match(workflow, /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress, labview-2026, lv32\]/);
  assert.match(workflow, /Assert-RunnerLabelContract\.ps1/);
  assert.match(workflow, /Write-LabVIEW2026HostPlaneDiagnostics\.ps1/);
  assert.match(workflow, /-OutputPath \$reportPath/);
  assert.match(workflow, /Compare-VIHistory\.ps1/);
  assert.match(workflow, /Invoke-LVCompare\.ps1/);
  assert.match(workflow, /Write-VIHistoryLV32ShadowProofReceipt\.ps1/);
  assert.match(workflow, /LABVIEW_PATH:\s*\$\{\{\s*steps\.host-plane\.outputs\.labview_path\s*\}\}/);
});

test('fixture-drift hosted Linux lane passes explicit linux container LabVIEW path and stays free of the hosted windows lane', () => {
  const workflow = readRepoFile('.github/workflows/fixture-drift.yml');

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);
  assert.match(workflow, /Invoke-NILinuxReviewSuite\.ps1/);
  assert.match(workflow, /Hydrate pull request base commit for VI history/);
  assert.match(workflow, /git remote add upstream-base "https:\/\/github\.com\/\$\{\{ github\.event\.pull_request\.base\.repo\.full_name \}\}"/);
  assert.match(workflow, /git fetch --no-tags upstream-base "\+refs\/heads\/\$\{\{ github\.event\.pull_request\.base\.ref \}\}:refs\/remotes\/upstream-base\/\$\{\{ github\.event\.pull_request\.base\.ref \}\}"/);
  assert.match(workflow, /-HistoryTargetPath 'fixtures\/vi-attr\/Head\.vi'/);
  assert.match(workflow, /FIXTURE_GITHUB_SHA:\s*\$\{\{\s*github\.sha\s*\}\}/);
  assert.match(workflow, /FIXTURE_PR_HEAD_SHA:\s*\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| ''\s*\}\}/);
  assert.match(workflow, /FIXTURE_PR_BASE_SHA:\s*\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.base\.sha \|\| ''\s*\}\}/);
  assert.match(workflow, /FIXTURE_PR_BASE_REF:\s*\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.base\.ref \|\| ''\s*\}\}/);
  assert.match(workflow, /FIXTURE_HEAD_REF:\s*\$\{\{\s*github\.head_ref\s*\}\}/);
  assert.match(workflow, /\$historyBranchRef = \$env:FIXTURE_GITHUB_SHA/);
  assert.match(workflow, /\$historyMaxCommitCount = 64/);
  assert.match(workflow, /\$historyBranchRef = \$env:FIXTURE_PR_HEAD_SHA/);
  assert.match(workflow, /\$historyBaselineRef = \$env:FIXTURE_PR_BASE_SHA/);
  assert.match(
    workflow,
    /if \(\$env:FIXTURE_PR_BASE_REF -eq 'main' -and \$env:FIXTURE_HEAD_REF\.StartsWith\('release\/'\)\)/
  );
  assert.match(workflow, /\$historyBaselineRef = \('\{0\}~\{1\}' -f \$historyBranchRef, \$historyMaxCommitCount\)/);
  assert.match(workflow, /-HistoryBranchRef \$historyBranchRef/);
  assert.match(workflow, /-HistoryBaselineRef \$historyBaselineRef/);
  assert.match(workflow, /-HistoryMaxCommitCount \$historyMaxCommitCount/);
  assert.match(workflow, /path: results\/fixture-drift\/ni-linux-container\/\*\*/);

  assert.doesNotMatch(workflow, /hosted-docker-windows/);
  assert.doesNotMatch(workflow, /NI_WINDOWS_IMAGE/);
  assert.doesNotMatch(workflow, /Run-NIWindowsContainerCompare\.ps1/);
  assert.doesNotMatch(workflow, /preflight-windows:/);
  assert.doesNotMatch(workflow, /Verify Windows runner and idle LabVIEW \(surface LVCompare notice\)/);
  assert.doesNotMatch(workflow, /Verify LVCompare and idle LabVIEW state \(notice-only on hosted\)/);
  assert.doesNotMatch(workflow, /LVCompare\.exe not found at canonical path/);
});

test('vi-compare-fork workflow uses hosted linux NI container compare path', () => {
  const workflow = readRepoFile('.github/workflows/vi-compare-fork.yml');

  assert.match(workflow, /runs-on:\s*ubuntu-latest/);
  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /Run-NILinuxContainerCompare\.ps1/);
  assert.match(workflow, /-Image', \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath', \$env:NI_LINUX_LABVIEW_PATH/);

  assert.doesNotMatch(workflow, /hosted-docker-windows/);
  assert.doesNotMatch(workflow, /Run-NIWindowsContainerCompare\.ps1/);
});

test('hosted NI Linux review suite helper includes flag combinations and VI history review outputs', () => {
  const script = readRepoFile('tools/Invoke-NILinuxReviewSuite.ps1');

  assert.match(script, /label = 'noattr'; flag = '-noattr'/);
  assert.match(script, /label = 'nofppos'; flag = '-nofppos'/);
  assert.match(script, /label = 'nobdcosm'; flag = '-nobdcosm'/);
  assert.match(script, /Inspect-VIHistorySuiteArtifacts\.ps1/);
  assert.match(script, /kind = 'flag-combination'/);
  assert.match(script, /kind = 'vi-history-report'/);
  assert.match(script, /history-report\.md/);
  assert.match(script, /history-report\.html/);
  assert.match(script, /history-summary\.json/);
  assert.match(script, /vi-history-review-loop-receipt\.json/);
  assert.match(script, /history-suite-inspection\.html/);
  assert.match(script, /history-suite-inspection\.json/);
  assert.match(script, /review-suite-summary\.json/);
  assert.match(script, /Resolve-HistoryRefSelection/);
  assert.match(script, /requestedBranchRef/);
  assert.match(script, /effectiveBranchRef/);
  assert.match(script, /HistoryMaxCommitCount/);
  assert.match(script, /HistoryReviewReceiptPath/);
  assert.match(script, /touchAware = \$true/);
  assert.match(script, /recommendedReviewOrder/);
  assert.match(script, /vi_history_review_receipt_path/);
});

test('runbook validation no longer executes windows docker fast-loop canary job', () => {
  const workflow = readRepoFile('.github/workflows/runbook-validation.yml');

  assert.match(workflow, /name:\s*Integration Runbook Validation/);
  assert.doesNotMatch(workflow, /runbook-check-container:/);
  assert.doesNotMatch(workflow, /Test-DockerDesktopFastLoop\.ps1/);
  assert.doesNotMatch(workflow, /NI_WINDOWS_IMAGE/);
});

test('windows hosted parity no longer includes hosted LVCompare babysitting debt', () => {
  const workflow = readRepoFile('.github/workflows/windows-hosted-parity.yml');

  assert.match(workflow, /name:\s*Windows Hosted NI Proof \(Manual\)/);
  assert.match(workflow, /runs-on:\s*windows-2022/);
  assert.doesNotMatch(workflow, /Verify LVCompare and idle LabVIEW state \(notice-only on hosted\)/);
  assert.doesNotMatch(workflow, /LVCompare\.exe not found at canonical path/);
  assert.match(workflow, /Prepare NI Windows image and hosted runtime/);
  assert.match(workflow, /Run-NIWindowsContainerCompare\.ps1/);
});

test('docker desktop fast-loop only accepts lane-specific LabVIEW path contracts', () => {
  const script = readRepoFile('tools/Test-DockerDesktopFastLoop.ps1');

  assert.doesNotMatch(script, /\[string\]\$LabVIEWPath\s*=/);
  assert.match(script, /PreferredEnvNames @\('NI_WINDOWS_LABVIEW_PATH', 'COMPARE_WINDOWS_LABVIEW_PATH'\)/);
  assert.match(script, /PreferredEnvNames @\('NI_LINUX_LABVIEW_PATH', 'COMPARE_LINUX_LABVIEW_PATH'\)/);
  assert.doesNotMatch(script, /COMPARE_LABVIEW_PATH/);
  assert.doesNotMatch(script, /LOOP_LABVIEW_PATH/);
});
test('actionlint config no longer carries legacy Windows docker runner labels', () => {
  const config = readRepoFile('.github/actionlint.yaml');

  assert.match(config, /comparevi/);
  assert.match(config, /capability-ingress/);
  assert.match(config, /labview-2026/);
  assert.match(config, /lv32/);
  assert.match(config, /docker-lane/);
  assert.match(config, /teststand/);
  assert.match(config, /self-hosted-docker-linux/);
  assert.match(config, /hosted-docker-linux/);
  assert.doesNotMatch(config, /self-hosted-docker-windows/);
  assert.doesNotMatch(config, /hosted-docker-windows/);
});

test('labview-cli-compare routes through the explicit lv32 host plane contract', () => {
  const workflow = readRepoFile('.github/workflows/labview-cli-compare.yml');
  const action = readRepoFile('action.yml');

  assert.match(
    workflow,
    /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress, labview-2026, lv32\]/
  );
  assert.match(workflow, /Write-LabVIEW2026HostPlaneDiagnostics\.ps1 -OutputPath \$reportPath/);
  assert.match(workflow, /tests\/results\/_agent\/host-planes\/labview-2026-host-plane-report\.json/);
  assert.match(workflow, /\$report\.native\.planes\.x32\.status -ne 'ready'/);
  assert.match(workflow, /LABVIEW_CLI_PATH:\s*\$\{\{\s*steps\.host_plane\.outputs\.cli\s*\}\}/);
  assert.match(workflow, /compare-timeout-seconds:\s*'1200'/);
  assert.match(action, /compare-timeout-seconds:/);
  assert.doesNotMatch(
    workflow,
    /Program Files \(x86\)\\National Instruments\\Shared\\LabVIEW CLI\\LabVIEWCLI\.exe/
  );
});
