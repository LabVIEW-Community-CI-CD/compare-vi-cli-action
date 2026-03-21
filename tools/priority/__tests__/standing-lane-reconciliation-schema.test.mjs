#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildStandingLaneReconciliationReceipt } from '../reconcile-standing-after-merge.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

async function loadSchema(relativePath) {
  return JSON.parse(await readFile(path.join(repoRoot, relativePath), 'utf8'));
}

function makeAjv() {
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  return ajv;
}

test('standing lane reconciliation schema validates the checked-in receipt shape', async () => {
  const schema = await loadSchema('docs/schemas/standing-lane-reconciliation-v1.schema.json');
  const receipt = buildStandingLaneReconciliationReceipt({
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    issue: 1010,
    pr: 1014,
    merged: true,
    dryRun: false,
    mergeSummaryPath: 'tests/results/_agent/queue/merge-sync-1014.json',
    standingIssue: {
      number: 1010,
      state: 'OPEN',
      labelsBefore: ['standing-priority'],
      labelsRemoved: ['standing-priority'],
      closeStatus: 'completed',
      closeComment: 'Completed by PR #1014. Standing priority has advanced from #1010 to #959.'
    },
    routerRefresh: {
      attempted: true,
      status: 'completed',
      routerPath: 'tests/results/_agent/issue/router.json',
      cachePath: '.agent_priority_cache.json',
      nextStandingIssueNumber: 959,
      helperCallsExecuted: ['node tools/priority/sync-standing-priority.mjs --fail-on-missing --fail-on-multiple --auto-select-next --materialize-cache']
    },
    workerSlotRelease: {
      attempted: true,
      status: 'released',
      workerSlotId: 'worker-slot-2',
      laneId: 'origin-1010',
      laneLifecycle: 'complete',
      helperCallsExecuted: ['worker-slot released']
    },
    summary: {
      status: 'completed',
      reason: 'standing lane reconciled after merge completion',
      nextStandingIssueNumber: 959
    }
  });
  const ajv = makeAjv();
  const validate = ajv.compile(schema);
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));
});
