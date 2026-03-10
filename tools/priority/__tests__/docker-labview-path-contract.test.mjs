#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('validate workflow passes explicit docker-specific LabVIEW paths for Windows and Linux lanes', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');

  assert.match(workflow, /NI_WINDOWS_IMAGE:\s*nationalinstruments\/labview:2026q1-windows/);
  assert.match(workflow, /NI_WINDOWS_LABVIEW_PATH:\s*C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW\.exe/);
  assert.match(workflow, /-WindowsImage \$env:NI_WINDOWS_IMAGE/);
  assert.match(workflow, /-WindowsLabVIEWPath \$env:NI_WINDOWS_LABVIEW_PATH/);

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /docker pull \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);
});

test('fixture-drift hosted Linux lane passes an explicit linux container LabVIEW path', () => {
  const workflow = readRepoFile('.github/workflows/fixture-drift.yml');

  assert.match(workflow, /NI_LINUX_IMAGE:\s*nationalinstruments\/labview:2026q1-linux/);
  assert.match(workflow, /NI_LINUX_LABVIEW_PATH:\s*\/usr\/local\/natinst\/LabVIEW-2026-64\/labview/);
  assert.match(workflow, /-Image \$env:NI_LINUX_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_LINUX_LABVIEW_PATH/);
  assert.match(workflow, /Invoke-NILinuxReviewSuite\.ps1/);
  assert.match(workflow, /-HistoryTargetPath 'fixtures\/vi-attr\/Head\.vi'/);
  assert.match(workflow, /path: results\/fixture-drift\/ni-linux-container\/\*\*/);
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
  assert.match(script, /history-suite-inspection\.html/);
  assert.match(script, /history-suite-inspection\.json/);
  assert.match(script, /review-suite-summary\.json/);
});

test('fixture-drift windows docker lane uses an explicit in-container LabVIEW path without host executable env fallback', () => {
  const workflow = readRepoFile('.github/workflows/fixture-drift.yml');

  assert.match(workflow, /NI_WINDOWS_IMAGE:\s*nationalinstruments\/labview:2026q1-windows/);
  assert.match(workflow, /NI_WINDOWS_LABVIEW_PATH:\s*C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW\.exe/);
  assert.match(workflow, /-Image \$env:NI_WINDOWS_IMAGE/);
  assert.match(workflow, /-LabVIEWPath \$env:NI_WINDOWS_LABVIEW_PATH/);
  assert.doesNotMatch(workflow, /LABVIEW_EXE:/);
});

test('runbook validation canary uses an explicit Windows container LabVIEW path', () => {
  const workflow = readRepoFile('.github/workflows/runbook-validation.yml');

  assert.match(workflow, /NI_WINDOWS_IMAGE:\s*nationalinstruments\/labview:2026q1-windows/);
  assert.match(workflow, /NI_WINDOWS_LABVIEW_PATH:\s*C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW\.exe/);
  assert.match(workflow, /-WindowsImage \$env:NI_WINDOWS_IMAGE/);
  assert.match(workflow, /-WindowsLabVIEWPath \$env:NI_WINDOWS_LABVIEW_PATH/);
});

test('docker desktop fast-loop only accepts lane-specific LabVIEW path contracts', () => {
  const script = readRepoFile('tools/Test-DockerDesktopFastLoop.ps1');

  assert.doesNotMatch(script, /\[string\]\$LabVIEWPath\s*=/);
  assert.match(script, /PreferredEnvNames @\('NI_WINDOWS_LABVIEW_PATH', 'COMPARE_WINDOWS_LABVIEW_PATH'\)/);
  assert.match(script, /PreferredEnvNames @\('NI_LINUX_LABVIEW_PATH', 'COMPARE_LINUX_LABVIEW_PATH'\)/);
  assert.doesNotMatch(script, /COMPARE_LABVIEW_PATH/);
  assert.doesNotMatch(script, /LOOP_LABVIEW_PATH/);
});
