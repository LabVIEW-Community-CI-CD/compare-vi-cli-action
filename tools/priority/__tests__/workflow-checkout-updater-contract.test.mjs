#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const repoRoot = process.cwd();
const updaterPath = path.join(repoRoot, 'tools', 'workflows', 'update_workflows.py');

function canRunUpdater() {
  const probe = spawnSync('python', ['-c', 'import ruamel.yaml'], { encoding: 'utf8' });
  return probe.status === 0;
}

function runUpdater(args) {
  return spawnSync('python', [updaterPath, ...args], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
}

test('workflow updater flags and rewrites bare pull_request checkout usage', (t) => {
  if (!canRunUpdater()) {
    t.skip('python + ruamel.yaml not available');
  }

  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'checkout-updater-'));
  const workflowPath = path.join(tempRoot, 'pull-request-checkout.yml');
  try {
    writeFileSync(
      workflowPath,
      [
        'name: Checkout Test',
        'on:',
        '  pull_request: {}',
        'jobs:',
        '  lint:',
        '    runs-on: ubuntu-latest',
        '    steps:',
        '      - uses: actions/checkout@v5',
        '      - run: echo ok',
        ''
      ].join('\n'),
      'utf8'
    );

    const check = runUpdater(['--check', workflowPath]);
    assert.notEqual(check.status, 0);
    assert.match(`${check.stdout}${check.stderr}`, /NEEDS UPDATE/);

    const write = runUpdater(['--write', workflowPath]);
    assert.equal(write.status, 0, write.stderr);

    const updated = readFileSync(workflowPath, 'utf8');
    assert.match(updated, /uses: \.\/\.github\/actions\/checkout-workflow-context/);
    assert.match(updated, /mode: 'pr-head'/);
    assert.doesNotMatch(updated, /actions\/checkout@v5/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});

test('workflow updater writes base-safe checkout mode for pull_request_target workflows', (t) => {
  if (!canRunUpdater()) {
    t.skip('python + ruamel.yaml not available');
  }

  const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'checkout-updater-'));
  const workflowPath = path.join(tempRoot, 'pull-request-target-checkout.yml');
  try {
    writeFileSync(
      workflowPath,
      [
        'name: Checkout Target Test',
        'on:',
        '  pull_request_target: {}',
        'jobs:',
        '  gate:',
        '    runs-on: ubuntu-latest',
        '    steps:',
        '      - uses: actions/checkout@v5',
        '      - run: echo ok',
        ''
      ].join('\n'),
      'utf8'
    );

    const write = runUpdater(['--write', workflowPath]);
    assert.equal(write.status, 0, write.stderr);

    const updated = readFileSync(workflowPath, 'utf8');
    assert.match(updated, /mode: 'base-safe'/);
    assert.doesNotMatch(updated, /actions\/checkout@v5/);
  } finally {
    rmSync(tempRoot, { recursive: true, force: true });
  }
});
