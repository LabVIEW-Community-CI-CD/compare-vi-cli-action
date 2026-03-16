#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate workflow passes explicit linux container LabVIEW paths for VI history lane', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /docker pull \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);

  assert.doesNotMatch(workflow, /vi-history-scenarios-windows:/);
});

test('fixture-drift hosted Linux lane passes explicit linux container LabVIEW path and has no windows docker lane', () => {
  const workflow = readRepoFile('.github/workflows/fixture-drift.yml');

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);
  assert.match(workflow, /Invoke-NILinuxReviewSuite\.ps1/);
  assert.match(workflow, /-HistoryTargetPath 'fixtures\/vi-attr\/Head\.vi'/);
  assert.match(workflow, /\$historyBranchRef = '\$\{\{ github\.sha \}\}'/);
  assert.match(workflow, /\$\{\{ github\.event\.pull_request\.head\.sha \}\}/);
  assert.match(workflow, /\$\{\{ github\.event\.pull_request\.base\.sha \}\}/);
  assert.match(workflow, /-HistoryBranchRef \$historyBranchRef/);
  assert.match(workflow, /-HistoryBaselineRef \$historyBaselineRef/);
  assert.match(workflow, /path: results\/fixture-drift\/ni-linux-container\/\*\*/);

  assert.doesNotMatch(workflow, /self-hosted-docker-windows/);
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

  assert.doesNotMatch(workflow, /self-hosted-docker-windows/);
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
  assert.match(script, /vi-history-slice\.json/);
  assert.match(script, /schema:validate/);
  assert.match(script, /vi-history-review-loop-receipt\.json/);
  assert.match(script, /history-suite-inspection\.html/);
  assert.match(script, /history-suite-inspection\.json/);
  assert.match(script, /review-suite-summary\.json/);
  assert.match(script, /review-suite-summary\.md/);
  assert.match(script, /review-suite-summary\.html/);
  assert.match(script, /Resolve-HistoryRefSelection/);
  assert.match(script, /requestedBranchRef/);
  assert.match(script, /effectiveBranchRef/);
  assert.match(script, /HistoryMaxCommitCount/);
  assert.match(script, /HistoryReviewReceiptPath/);
  assert.match(script, /touchAware = \$true/);
  assert.match(script, /recommendedReviewOrder/);
  assert.match(script, /vi_history_slice_path/);
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

  assert.doesNotMatch(workflow, /Verify LVCompare and idle LabVIEW state \(notice-only on hosted\)/);
  assert.doesNotMatch(workflow, /LVCompare\.exe not found at canonical path/);
  assert.match(workflow, /name:\s*Hooks preflight parity/);
});

test('docker desktop fast-loop only accepts lane-specific LabVIEW path contracts', () => {
  const script = readRepoFile('tools/Test-DockerDesktopFastLoop.ps1');

  assert.doesNotMatch(script, /\[string\]\$LabVIEWPath\s*=/);
  assert.match(script, /PreferredEnvNames @\('NI_WINDOWS_LABVIEW_PATH', 'COMPARE_WINDOWS_LABVIEW_PATH'\)/);
  assert.match(script, /PreferredEnvNames @\('NI_LINUX_LABVIEW_PATH', 'COMPARE_LINUX_LABVIEW_PATH'\)/);
  assert.doesNotMatch(script, /COMPARE_LABVIEW_PATH/);
  assert.doesNotMatch(script, /LOOP_LABVIEW_PATH/);
});
