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
});

test('runbook validation canary uses an explicit Windows container LabVIEW path', () => {
  const workflow = readRepoFile('.github/workflows/runbook-validation.yml');

  assert.match(workflow, /NI_WINDOWS_IMAGE:\s*nationalinstruments\/labview:2026q1-windows/);
  assert.match(workflow, /NI_WINDOWS_LABVIEW_PATH:\s*C:\\Program Files\\National Instruments\\LabVIEW 2026\\LabVIEW\.exe/);
  assert.match(workflow, /-WindowsImage \$env:NI_WINDOWS_IMAGE/);
  assert.match(workflow, /-WindowsLabVIEWPath \$env:NI_WINDOWS_LABVIEW_PATH/);
});
