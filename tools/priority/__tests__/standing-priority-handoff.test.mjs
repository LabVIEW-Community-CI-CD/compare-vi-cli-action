#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { handoffStandingPriority } from '../standing-priority-handoff.mjs';

test('handoffStandingPriority removes old label, adds new, and syncs cache', async () => {
  const calls = [];
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list') {
      return JSON.stringify([{ number: 528 }, { number: 529 }]);
    }
    return '';
  };
  let syncCount = 0;
  const syncFn = async () => {
    syncCount += 1;
  };

  await handoffStandingPriority(529, { ghRunner, syncFn, logger: () => {} });

  assert.deepEqual(calls, [
    ['issue', 'list', '--label', 'standing-priority', '--state', 'open', '--limit', '20', '--json', 'number'],
    ['issue', 'edit', '528', '--remove-label', 'standing-priority']
  ]);
  assert.equal(syncCount, 1);
});

test('handoffStandingPriority adds label when none present', async () => {
  const calls = [];
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list') {
      return '[]';
    }
    return '';
  };
  let syncCount = 0;
  const syncFn = async () => {
    syncCount += 1;
  };

  await handoffStandingPriority('530', { ghRunner, syncFn, logger: () => {} });

  assert.deepEqual(calls, [
    ['issue', 'list', '--label', 'standing-priority', '--state', 'open', '--limit', '20', '--json', 'number'],
    ['issue', 'edit', '530', '--add-label', 'standing-priority']
  ]);
  assert.equal(syncCount, 1);
});

test('dry-run only inspects current issues', async () => {
  const calls = [];
  const ghRunner = (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list') {
      return JSON.stringify([{ number: 531 }]);
    }
    return '';
  };

  await handoffStandingPriority(532, { ghRunner, dryRun: true, logger: () => {} });

  assert.deepEqual(calls, [
    ['issue', 'list', '--label', 'standing-priority', '--state', 'open', '--limit', '20', '--json', 'number']
  ]);
});
