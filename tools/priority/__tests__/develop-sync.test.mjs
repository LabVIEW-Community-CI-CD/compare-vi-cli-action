#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseArgs,
  resolveForkRemoteTargets,
  buildParityReportPath,
  buildPwshArgs
} from '../develop-sync.mjs';

test('develop-sync parseArgs accepts fork-remote and report overrides', () => {
  const parsed = parseArgs([
    'node',
    'develop-sync.mjs',
    '--fork-remote',
    'all',
    '--report',
    'custom/report.json'
  ]);

  assert.equal(parsed.forkRemote, 'all');
  assert.equal(parsed.reportPath, 'custom/report.json');
});

test('resolveForkRemoteTargets defaults to origin and supports all lanes', () => {
  assert.deepEqual(resolveForkRemoteTargets(null, {}), ['origin']);
  assert.deepEqual(resolveForkRemoteTargets('personal', {}), ['personal']);
  assert.deepEqual(resolveForkRemoteTargets('all', {}), ['origin', 'personal']);
});

test('buildPwshArgs pins the selected remote and parity path', () => {
  const repoRoot = '/tmp/repo';
  const parityReportPath = buildParityReportPath(repoRoot, 'personal');
  const args = buildPwshArgs({
    repoRoot,
    remote: 'personal',
    parityReportPath
  });

  assert.ok(args.includes('-HeadRemote'));
  assert.ok(args.includes('personal'));
  assert.ok(args.includes(parityReportPath));
});
