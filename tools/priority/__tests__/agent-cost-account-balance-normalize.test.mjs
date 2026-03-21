#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  buildNormalizedAccountBalanceReceiptFromSnapshot,
  parseArgs,
  runAgentCostAccountBalanceNormalize
} from '../agent-cost-account-balance-normalize.mjs';

const repoRoot = path.resolve(process.cwd());
const fixtureRoot = path.join(repoRoot, 'tools', 'priority', '__fixtures__', 'agent-cost-rollup');
const canonicalOutputPath = path.join(
  repoRoot,
  'tests',
  'results',
  '_agent',
  'cost',
  'account-balances',
  'account-balance-2026-03-21.json'
);

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('parseArgs requires a snapshot path and accepts output overrides', () => {
  const parsed = parseArgs([
    'node',
    'tools/priority/agent-cost-account-balance-normalize.mjs',
    '--snapshot',
    'private-account-balance.json',
    '--output',
    'account-balance.json'
  ]);

  assert.equal(parsed.snapshotPath, 'private-account-balance.json');
  assert.equal(parsed.outputPath, 'account-balance.json');
});

test('buildNormalizedAccountBalanceReceiptFromSnapshot normalizes a private account balance snapshot with provenance and timestamps', () => {
  const snapshot = readJson(path.join(fixtureRoot, 'private-account-balance-sample.json'));
  const report = buildNormalizedAccountBalanceReceiptFromSnapshot(snapshot);

  assert.equal(report.schema, 'priority/agent-cost-account-balance@v1');
  assert.equal(report.effectiveAt, '2026-03-21T12:00:00.000Z');
  assert.equal(report.capturedAt, '2026-03-21T12:00:00.000Z');
  assert.equal(report.renewalCycleBoundaryAt, '2026-04-15T00:00:00.000Z');
  assert.equal(report.plan.name, 'business');
  assert.equal(report.plan.renewsAt, '2026-04-15');
  assert.equal(report.plan.daysRemaining, 25);
  assert.deepEqual(report.balances, {
    totalCredits: 27500,
    usedCredits: 15800,
    remainingCredits: 11700
  });
  assert.equal(report.sourceSchema, 'priority/agent-cost-private-account-balance@v1');
  assert.equal(report.sourceKind, 'operator-account-state');
  assert.equal(report.sourcePathEvidence, 'tools/priority/__fixtures__/agent-cost-rollup/private-account-balance-sample.json');
  assert.equal(report.confidence, 'high');
  assert.equal(report.operatorNote, 'Sanitized operator-provided account balance snapshot.');
});

test('runAgentCostAccountBalanceNormalize writes a normalized account-balance receipt to the requested path', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-account-balance-normalize-'));
  const outputPath = path.join(tmpDir, 'account-balance.json');
  const result = runAgentCostAccountBalanceNormalize({
    snapshotPath: path.join(fixtureRoot, 'private-account-balance-sample.json'),
    outputPath
  });

  assert.deepEqual(result.report.balances, {
    totalCredits: 27500,
    usedCredits: 15800,
    remainingCredits: 11700
  });
  assert.equal(fs.existsSync(outputPath), true);
});

test('runAgentCostAccountBalanceNormalize auto-discovers the canonical account-balance output path when none is provided', () => {
  if (fs.existsSync(canonicalOutputPath)) {
    fs.rmSync(canonicalOutputPath, { force: true });
  }

  try {
    const result = runAgentCostAccountBalanceNormalize({
      snapshotPath: path.join(fixtureRoot, 'private-account-balance-sample.json')
    });

    assert.equal(result.outputPath, canonicalOutputPath);
    assert.equal(fs.existsSync(canonicalOutputPath), true);
  } finally {
    fs.rmSync(canonicalOutputPath, { force: true });
  }
});

test('agent-cost-account-balance-normalize CLI writes a receipt directly', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-cost-account-balance-normalize-cli-'));
  const outputPath = path.join(tmpDir, 'account-balance.json');
  const result = spawnSync(
    process.execPath,
    [
      path.join('tools', 'priority', 'agent-cost-account-balance-normalize.mjs'),
      '--snapshot',
      path.join('tools', 'priority', '__fixtures__', 'agent-cost-rollup', 'private-account-balance-sample.json'),
      '--output',
      outputPath
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[agent-cost-account-balance-normalize\] wrote /);
  assert.equal(fs.existsSync(outputPath), true);
});
