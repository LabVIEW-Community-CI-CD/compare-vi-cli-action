#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { parseArgs, runStandingReconciliation } from '../reconcile-standing-after-merge.mjs';

test('parseArgs accepts merge reconciliation controls', () => {
  const parsed = parseArgs([
    'node',
    'tools/priority/reconcile-standing-after-merge.mjs',
    '--issue',
    '1010',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--pr',
    '1014',
    '--merged',
    '--worker-slot-id',
    'worker-slot-2',
    '--summary-path',
    'tests/results/_agent/issue/standing-lane-reconciliation-1010.json'
  ]);

  assert.deepEqual(parsed, {
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issue: 1010,
    pr: 1014,
    merged: true,
    workerSlotId: 'worker-slot-2',
    mergeSummaryPath: null,
    summaryPath: 'tests/results/_agent/issue/standing-lane-reconciliation-1010.json',
    routerPath: null,
    cachePath: null,
    dryRun: false,
    help: false
  });
});

test('runStandingReconciliation closes the standing issue and refreshes the router cache after merge completion', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-reconcile-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const removeCalls = [];
  const closeCalls = [];
  const syncCalls = [];
  const writes = [];

  const receipt = await runStandingReconciliation({
    repoRoot,
    argv: [
      'node',
      'tools/priority/reconcile-standing-after-merge.mjs',
      '--issue',
      '1010',
      '--repo',
      'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      '--pr',
      '1014',
      '--merged',
      '--worker-slot-id',
      'worker-slot-2'
    ],
    ensureGhCliFn: () => {},
    readIssueViewFn: async () => ({
      number: 1010,
      state: 'OPEN',
      title: 'Containerize NILinuxCompare tests via tools image Docker contract',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1010',
      labels: [{ name: 'standing-priority' }]
    }),
    removeStandingLabelsFn: async (options) => {
      removeCalls.push(options);
      return { status: 0 };
    },
    closeIssueWithCommentFn: async (options) => {
      closeCalls.push(options);
      return { status: 0 };
    },
    syncStandingPriorityFn: async (options) => {
      syncCalls.push(options);
      return { status: 0 };
    },
    readJsonFn: async (filePath) => {
      if (String(filePath).endsWith('router.json')) {
        return { schema: 'agent/priority-router@v1', issue: 959, updatedAt: '2026-03-21T00:00:00Z', actions: [] };
      }
      if (String(filePath).endsWith('.agent_priority_cache.json')) {
        return { number: 959 };
      }
      return null;
    },
    writeJsonFn: async (filePath, payload) => {
      writes.push({ filePath, payload });
      return filePath;
    }
  });

  assert.equal(receipt.summary.status, 'completed');
  assert.equal(receipt.summary.nextStandingIssueNumber, 959);
  assert.equal(receipt.routerRefresh.status, 'completed');
  assert.equal(receipt.routerRefresh.nextStandingIssueNumber, 959);
  assert.equal(receipt.workerSlotRelease.status, 'released');
  assert.equal(receipt.workerSlotRelease.workerSlotId, 'worker-slot-2');
  assert.equal(receipt.standingIssue.closeStatus, 'completed');
  assert.deepEqual(removeCalls[0].labels, ['standing-priority']);
  assert.equal(closeCalls[0].comment.includes('PR #1014'), true);
  assert.equal(syncCalls.length, 1);
  assert.equal(writes.length, 1);
  assert.match(String(writes[0].filePath), /standing-lane-reconciliation-1010\.json$/);
});
