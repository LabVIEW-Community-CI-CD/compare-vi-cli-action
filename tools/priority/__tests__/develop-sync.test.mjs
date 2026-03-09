#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseArgs,
  resolveForkRemoteTargets,
  buildParityReportPath,
  buildPwshArgs
} from '../develop-sync.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

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

test('Sync-OriginUpstreamDevelop forwards the requested parity report path to the parity reporter', () => {
  const scriptPath = path.join(repoRoot, 'tools', 'priority', 'Sync-OriginUpstreamDevelop.ps1');
  const source = readFileSync(scriptPath, 'utf8');

  assert.match(source, /report-origin-upstream-parity\.mjs'/);
  assert.match(source, /'--output-path'/);
  assert.match(source, /\$parityReportPath/);
});
